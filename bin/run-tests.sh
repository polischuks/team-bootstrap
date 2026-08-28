#!/usr/bin/env bash
# run-tests.sh — team-bootstrap's `Test:` command (milestone closed-loop-fidelity, batch A1).
#
# Runs every `bin/*.sh --self-test` and every `tests/*.test.sh` under ROOT (default: repo root)
# and exits non-zero if any fails. This is the runnable suite AGENTS.md declares as `Test:`, so the
# harness red-first gate (check-tdd.sh --record-red → check-tdd.sh) has something real to observe red→green against
# on team-bootstrap's own delivery runs — closing the `red-first` enforcement gap the repo carried.
#
# It deliberately does NOT back a `Coverage:`/`Mutation:` contract: there is no bash coverage/mutation
# tool on the host, and a declared-but-toolless command is exactly the vacuous gate this milestone
# forbids. Those two dimensions stay honestly gapped and are covered by a governed, expiring
# enforcement waiver (see references/enforcement.md) — never a faked runner.
#
# Members are independent — each builds its own mktemp fixture and none writes into the repo — so
# they may run concurrently. Wall-clock is then bounded by the slowest member rather than by their
# sum. Concurrency does not reorder the report: a failure is recorded as a file named after its
# member and the report is emitted by sorted glob, so the same red suite prints the same lines in
# the same order on every run, whatever order the members happen to finish in.
#
# SELECTION (#76) and CACHE (#77) are two ways to run LESS than the whole suite on an edit-heavy
# session, without ever hiding a failure in what they DO run:
#   * bin/run-tests.sh                → full run (default; the honest pre-push / CI gate)
#   * bin/run-tests.sh --changed [--base REF]
#                                     → only the members a working-tree change could have affected
#   * bin/run-tests.sh <glob> [<glob>…]
#                                     → only members whose name/stem matches (e.g. 'check-*')
#   * bin/run-tests.sh --cache        → opt-in: skip any member whose INPUT fingerprint matches its
#                                       last green result; --no-cache forces every member to run
# Selection and the cache are pure FILTERS over the one member set discover_members() computes, and
# every selected member runs through the SAME run_member path a full run uses — so a --changed / glob
# run and a full run AGREE on the verdict of any member they share. Under-selection (missing a member
# a change affected) and a stale cached green are the false-PASS risks; both are asserted against in
# --self-test here and in tests/run-tests-selection.test.sh (a swept member, so the full gate checks
# them on every run).
#
# Usage: bin/run-tests.sh [root] [glob…] [--changed] [--base REF] [--cache|--no-cache] [--jobs N]
#        bin/run-tests.sh --self-test
#        N defaults to the host CPU count capped at 8; --jobs 1 forces the serial path.
#        TB_TEST_JOBS sets the default without touching the command line.
#        The first positional that is an existing directory is ROOT; any other positional is a glob.
# Exit:  0 all green (or nothing selected) · 1 one or more suites failed · 64 bad usage
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# auto_jobs → a sane default concurrency for this host: CPU count, capped at 8, floor 1.
#
# The cap is measured, not guessed. Full suite on a 12-core host, seconds:
#   jobs=1  322 · jobs=2  177 · jobs=4  96 · jobs=8  82 · jobs=12  86 · jobs=16  91
# Scaling is near-linear to 4, plateaus at 8, and degrades monotonically past it — 12 workers on
# 12 cores is SLOWER than 8. Beyond the plateau the extra workers are not finding new work to
# overlap; they are contending around a floor set by the slowest single member, which no amount of
# concurrency can go under. So 8 sits at the top of the curve rather than short of it.
#
# The cap bounds only this DEFAULT. An explicit --jobs is honoured as given, above the core count
# included (tests/run-tests-parallel.test.sh pins that) — the operator may know something about
# their host that this function does not.
auto_jobs() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)"
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -gt 8 ] && n=8
  [ "$n" -lt 1 ] && n=1
  echo "$n"
}

# _sha — hash stdin, portable across macOS (shasum) and Linux CI (sha1sum).
_sha() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }

# discover_members ROOT — the ONE member set. Prints one `kind|abspath` spec per line:
#   self|…/bin/X.sh   → run `bash X.sh --self-test`
#   test|…/tests/Y.test.sh → run `bash Y.test.sh`
# Skips the runner itself and its own test to avoid re-entry. Selection and the full run both consume
# exactly this set, so a selected member is always a member a full run would also have run.
discover_members() {
  local root="$1" f base
  for f in "$root"/bin/*.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "run-tests.sh" ] && continue
    # A script HANDLES --self-test only if it dispatches on the flag. Matching the bare string anywhere
    # made any mention — a comment, or a call to ANOTHER script's self-test — look like a self-test mode,
    # and the runner then invoked a flag the script does not accept and reported it as a failing suite.
    grep -qE -- '(--self-test\)|= "--self-test" \]|=--self-test)' "$f" 2>/dev/null || continue
    printf 'self|%s\n' "$f"
  done
  for f in "$root"/tests/*.test.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "run-tests.test.sh" ] && continue
    printf 'test|%s\n' "$f"
  done
}

# _stem BASENAME → basename with a trailing .test.sh or .sh removed (member "name" for glob/grep).
_stem() { local b="$1"; b="${b%.test.sh}"; b="${b%.sh}"; printf '%s\n' "$b"; }

# ---------------------------------------------------------------------------------------------
# INPUT FINGERPRINT (#77): a member is cached green only against a hash of the files it reads. Under-
# including an input is the one way a cache goes stale-green, so the closure is conservative: the
# member file, the transitive `source` closure of the bin scripts in play, and any references/ or
# profiles/ file named by literal path. Over-including only costs a cache miss; it never hides a
# change.
# ---------------------------------------------------------------------------------------------

# _extract_deps ROOT FILE — direct input files FILE names: sourced libs, invoked bin/ scripts, and
# referenced references//profiles/ paths. Emits absolute paths that exist under ROOT.
_extract_deps() {
  local root="$1" f="$2" b
  # `. "$here/foo.sh"` / `source "$dir/foo.sh"` — the sourced library basename.
  grep -oE '(^|[[:space:]])(\.|source)[[:space:]]+["'\'']?[^"'\'' ]*/[A-Za-z0-9_.-]+\.sh' "$f" 2>/dev/null \
    | grep -oE '[A-Za-z0-9_.-]+\.sh$' | while IFS= read -r b; do
        [ -f "$root/bin/$b" ] && printf '%s\n' "$root/bin/$b"
      done
  # `bin/<name>.sh` literal tokens — a test invoking a gate under bin/.
  grep -oE 'bin/[A-Za-z0-9_.-]+\.sh' "$f" 2>/dev/null | while IFS= read -r b; do
        b="${b#bin/}"; [ -f "$root/bin/$b" ] && printf '%s\n' "$root/bin/$b"
      done
  # references/ and profiles/ literal paths a gate reads.
  grep -oE '(references|profiles)/[A-Za-z0-9_./-]+' "$f" 2>/dev/null | while IFS= read -r b; do
        [ -f "$root/$b" ] && printf '%s\n' "$root/$b"
      done
}

# _input_files ROOT START — START plus its transitive input closure (following .sh sources only).
_input_files() {
  local root="$1" start="$2" seen dep cur
  seen="$(mktemp)"
  local queue=("$start")
  while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    grep -Fxq "$cur" "$seen" 2>/dev/null && continue
    printf '%s\n' "$cur" >> "$seen"
    [ -f "$cur" ] || continue
    printf '%s\n' "$cur"
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        *.sh) queue[${#queue[@]}]="$dep" ;;   # follow source closure
        *)    printf '%s\n' "$dep" ;;          # reference/profile: an input, not followed
      esac
    done < <(_extract_deps "$root" "$cur")
  done
  rm -f "$seen"
}

# fingerprint ROOT SPEC — a hash that changes iff any input of the member changes.
fingerprint() {
  local root="$1" spec="$2" path="${2#*|}" f
  _input_files "$root" "$path" | sort -u | while IFS= read -r f; do
    if [ -f "$f" ]; then printf '%s ' "${f#"$root"/}"; _sha < "$f" | awk '{print $1}';
    else printf '%s MISSING\n' "${f#"$root"/}"; fi
  done | _sha | awk '{print $1}'
}

# _cache_name ROOT SPEC — stable per-member cache filename.
_cache_name() {
  local root="$1" spec="$2" kind="${2%%|*}" path="${2#*|}" rel
  rel="${path#"$root"/}"
  printf '%s__%s.green\n' "$kind" "$(printf '%s' "$rel" | tr '/.' '__')"
}

# ---------------------------------------------------------------------------------------------
# EXECUTION — one member; the verdict travels as a FILE, not a variable, because a counter
# incremented inside a `&` subshell is lost to the parent, which is how a parallel runner comes to
# report a red suite as green.
# ---------------------------------------------------------------------------------------------

# run_member SPEC DIR [CACHE ROOT FP] — run one member; on failure drop a file named after it into
# DIR. When CACHE=cache: on pass write FP to the member's cache file; on fail REMOVE any cache file
# so a prior green can never be served for a now-red member.
run_member() {
  local spec="$1" dir="$2" cache="${3:-}" root="${4:-}" fp="${5:-}" kind path base ok=1 cf
  kind="${spec%%|*}"; path="${spec#*|}"; base="$(basename "$path")"
  if [ "$kind" = "self" ]; then
    bash "$path" --self-test >/dev/null 2>&1 || ok=0
    [ "$ok" -eq 0 ] && printf 'run-tests: FAIL self-test — %s\n' "$base" > "$dir/$base.self.fail"
  else
    bash "$path" >/dev/null 2>&1 || ok=0
    [ "$ok" -eq 0 ] && printf 'run-tests: FAIL test — %s\n' "$base" > "$dir/$base.test.fail"
  fi
  if [ "$cache" = "cache" ]; then
    cf="$root/.runs/.test-cache/$(_cache_name "$root" "$spec")"
    if [ "$ok" -eq 1 ]; then printf '%s\n' "$fp" > "$cf"; else rm -f "$cf"; fi
  fi
}

# run_members ROOT JOBS CACHE — run the specs read from stdin (a subset of discover_members). 0 iff
# every member run passes. When CACHE=cache, a member whose fingerprint matches its cached green is
# SKIPPED; every other member runs (and a red member, being uncached, always runs).
run_members() {
  local root="$1" jobs="$2" cache="$3" fails=0 spec fp cf ff dir
  local specs=()
  while IFS= read -r spec; do [ -n "$spec" ] && specs[${#specs[@]}]="$spec"; done
  [ "${#specs[@]}" -eq 0 ] && return 0
  dir="$(mktemp -d)"
  [ "$cache" = "cache" ] && mkdir -p "$root/.runs/.test-cache"
  for spec in "${specs[@]}"; do
    fp=""
    if [ "$cache" = "cache" ]; then
      fp="$(fingerprint "$root" "$spec")"
      cf="$root/.runs/.test-cache/$(_cache_name "$root" "$spec")"
      if [ -f "$cf" ] && [ "$(cat "$cf" 2>/dev/null)" = "$fp" ]; then
        continue   # inputs unchanged since the last green result → skip
      fi
    fi
    if [ "$jobs" -gt 1 ]; then
      # Sliding window rather than fixed chunks: a chunk barrier would idle every finished slot
      # until the chunk's slowest member returned, which is the same wasted wall-clock the whole
      # change is here to remove. `jobs -pr` counts only this shell's running background members.
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$jobs" ]; do sleep 0.05; done
      run_member "$spec" "$dir" "$cache" "$root" "$fp" &
    else
      run_member "$spec" "$dir" "$cache" "$root" "$fp"
    fi
  done
  wait

  # Sorted glob, so the report is byte-identical across runs no matter who finished first.
  for ff in "$dir"/*.fail; do
    [ -e "$ff" ] || continue
    cat "$ff" >&2; fails=$((fails + 1))
  done
  rm -rf "$dir"
  [ "$fails" -eq 0 ]
}

# run_suite ROOT [JOBS] — the full run: every discovered member, no cache. Kept as a thin wrapper so
# the --self-test aggregation cases below read the same way they always have.
run_suite() { discover_members "$1" | run_members "$1" "${2:-1}" ""; }

# ---------------------------------------------------------------------------------------------
# SELECTION (#76)
# ---------------------------------------------------------------------------------------------

# select_glob ROOT PATTERN — members whose basename OR stem matches the glob PATTERN.
select_glob() {
  local root="$1" pat="$2" spec base stem
  discover_members "$root" | while IFS= read -r spec; do
    base="$(basename "${spec#*|}")"; stem="$(_stem "$base")"
    case "$base" in $pat) printf '%s\n' "$spec"; continue ;; esac
    case "$stem" in $pat) printf '%s\n' "$spec" ;; esac
  done
}

# _tests_referencing ROOT UNIVERSE TOKEN — test-members whose file mentions TOKEN (grep, fixed).
_tests_referencing() {
  local universe="$2" token="$3" spec
  printf '%s\n' "$universe" | while IFS= read -r spec; do
    case "$spec" in test\|*)
      grep -Fq "$token" "${spec#*|}" 2>/dev/null && printf '%s\n' "$spec" ;;
    esac
  done
}

# changed_files ROOT BASE — working-tree changes vs BASE (default HEAD), plus untracked new files so a
# brand-new bin/ or tests/ file is picked up. TB_CHANGED_FILES overrides for tests (never used in the
# production git path). Paths are repo-relative, as git prints them.
changed_files() {
  local root="$1" base="${2:-HEAD}"
  if [ -n "${TB_CHANGED_FILES+x}" ]; then printf '%s\n' $TB_CHANGED_FILES; return 0; fi
  git -C "$root" diff --name-only "$base" 2>/dev/null
  git -C "$root" ls-files --others --exclude-standard 2>/dev/null
}

# select_changed ROOT BASE — the members a working-tree change could have affected:
#   bin/X.sh      → X's self-test member + every test that references X (grep on the stem)
#   tests/Y.test  → Y itself
#   references/…  → every gate/test whose file names that file (by basename); its readers re-run
#   profiles/…    → same, by basename
# Output is a subset of discover_members; a changed file that maps to no member (e.g. a doc) selects
# nothing. Over-selection is safe (a member that did not need to run still reaches the right verdict);
# UNDER-selection is the false-PASS, so each rule maps to a conservative superset of readers.
select_changed() {
  local root="$1" base="$2" universe changed c b stem sel spec
  universe="$(discover_members "$root")"
  changed="$(changed_files "$root" "$base")"
  sel=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    c="${c#./}"
    case "$c" in
      bin/run-tests.sh)
        # the runner itself — its coverage lives in the swept tests that name it (parallel test etc.)
        sel="$sel
$(_tests_referencing "$root" "$universe" "run-tests")"
        ;;
      bin/*.sh)
        b="$(basename "$c")"; stem="$(_stem "$b")"
        sel="$sel
$(printf '%s\n' "$universe" | grep -Fx "self|$root/$c")"
        sel="$sel
$(_tests_referencing "$root" "$universe" "$stem")"
        ;;
      tests/*.test.sh)
        sel="$sel
$(printf '%s\n' "$universe" | grep -Fx "test|$root/$c")"
        ;;
      *)
        # references/, profiles/, or anything else: its readers, matched by basename.
        b="$(basename "$c")"
        while IFS= read -r spec; do
          case "$spec" in self\|*)
            grep -Fq "$b" "${spec#*|}" 2>/dev/null && sel="$sel
$spec" ;;
          esac
        done <<EOF
$universe
EOF
        sel="$sel
$(_tests_referencing "$root" "$universe" "$b")"
        ;;
    esac
  done <<EOF
$changed
EOF
  printf '%s\n' "$sel" | grep -v '^$' | sort -u
}

# --- self-test: aggregation, selection, and cache invariants over temp fixtures -------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/bin" "$T/tests"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --self-test) exit 0;; esac\n' > "$T/bin/ok.sh"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --self-test) exit 1;; esac\n' > "$T/bin/bad.sh"
  if run_suite "$T"; then echo "  FAIL: red suite (bad self-test) reported green" >&2; fail=$((fail + 1)); else echo "  PASS red suite (bad self-test) → non-zero"; fi
  rm -f "$T/bin/bad.sh"
  if run_suite "$T"; then echo "  PASS green suite → zero"; else echo "  FAIL: green suite reported red" >&2; fail=$((fail + 1)); fi
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/tests/x.test.sh"
  if run_suite "$T"; then echo "  FAIL: failing tests/ member not caught" >&2; fail=$((fail + 1)); else echo "  PASS failing tests/ member → non-zero"; fi
  # The parallel path must reach the SAME verdict — a red suite stays red when the members run
  # in subshells, which is where a lost failure count would show.
  if run_suite "$T" 4; then echo "  FAIL: red suite reported green under jobs=4" >&2; fail=$((fail + 1)); else echo "  PASS red suite under jobs=4 → non-zero"; fi
  rm -f "$T/tests/x.test.sh"
  if run_suite "$T" 4; then echo "  PASS green suite under jobs=4 → zero"; else echo "  FAIL: green suite reported red under jobs=4" >&2; fail=$((fail + 1)); fi

  # selection: a glob selects only matching members; --changed selects a changed member's readers.
  sg="$(select_glob "$T" 'ok')"
  if [ "$sg" = "self|$T/bin/ok.sh" ]; then echo "  PASS glob 'ok' selects only ok.sh"; else echo "  FAIL: glob 'ok' selected [$sg]" >&2; fail=$((fail + 1)); fi
  sc="$(TB_CHANGED_FILES='bin/ok.sh' select_changed "$T" HEAD)"
  if [ "$sc" = "self|$T/bin/ok.sh" ]; then echo "  PASS --changed bin/ok.sh selects ok's self-test"; else echo "  FAIL: --changed bin/ok.sh selected [$sc]" >&2; fail=$((fail + 1)); fi

  # cache: fingerprint changes iff an input changes; a green member is skipped, an edited one re-runs.
  fp1="$(fingerprint "$T" "self|$T/bin/ok.sh")"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --self-test) exit 0;; esac\n# edit\n' > "$T/bin/ok.sh"
  fp2="$(fingerprint "$T" "self|$T/bin/ok.sh")"
  if [ "$fp1" != "$fp2" ]; then echo "  PASS fingerprint changes when the member file changes"; else echo "  FAIL: fingerprint unchanged after an edit" >&2; fail=$((fail + 1)); fi

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "run-tests --self-test: OK"; exit 0; fi
  echo "run-tests --self-test: $fail case(s) FAILED" >&2; exit 1
fi

usage() { echo "usage: run-tests.sh [root] [glob…] [--changed] [--base REF] [--cache|--no-cache] [--jobs N] | --self-test"; }

root=""; jobs="${TB_TEST_JOBS:-}"; mode="full"; base="HEAD"; cache=""; nocache=0
patterns=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --jobs|-j)  shift; jobs="${1:-}" ;;
    --jobs=*)   jobs="${1#*=}" ;;
    --changed)  mode="changed" ;;
    --base)     shift; base="${1:-HEAD}" ;;
    --base=*)   base="${1#*=}" ;;
    --cache)    cache="cache" ;;
    --no-cache) nocache=1 ;;
    -*) echo "run-tests: unknown option '$1'" >&2; usage >&2; exit 64 ;;
    *)  # first positional that is a directory is ROOT; every other positional is a glob pattern.
        if [ -z "$root" ] && [ "${#patterns[@]}" -eq 0 ] && [ -d "$1" ]; then root="$1"
        else patterns[${#patterns[@]}]="$1"; fi ;;
  esac
  shift
done
[ "$nocache" -eq 1 ] && cache=""   # --no-cache always wins: the gate stays honest

# A job count that cannot be honoured is a usage error, never a silent fall back to serial: the
# operator who asked for concurrency would otherwise be told nothing and wait out the serial time.
if [ -n "$jobs" ]; then
  case "$jobs" in ''|*[!0-9]*) echo "run-tests: --jobs takes a positive integer, got '$jobs'" >&2; exit 64 ;; esac
  [ "$jobs" -ge 1 ] || { echo "run-tests: --jobs takes a positive integer, got '$jobs'" >&2; exit 64; }
else
  jobs="$(auto_jobs)"
fi

[ -n "$root" ] || root="$(cd "$here/.." && pwd)"
[ -d "$root" ] || { echo "run-tests: bad root '$root'" >&2; exit 64; }

# --changed and a glob are two different ways to narrow; asking for both is ambiguous.
if [ "$mode" = "changed" ] && [ "${#patterns[@]}" -gt 0 ]; then
  echo "run-tests: --changed and a glob pattern are mutually exclusive" >&2; exit 64
fi

# Resolve the member set for the chosen mode (always a subset of discover_members).
case "$mode" in
  changed) specs="$(select_changed "$root" "$base")" ;;
  full)
    if [ "${#patterns[@]}" -gt 0 ]; then
      specs="$(for p in "${patterns[@]}"; do select_glob "$root" "$p"; done | grep -v '^$' | sort -u)"
      mode="glob"
    else
      specs="$(discover_members "$root")"
    fi ;;
esac

if [ -z "$specs" ]; then
  echo "run-tests: no members selected (mode=$mode) — nothing to run"; exit 0
fi

nsel="$(printf '%s\n' "$specs" | grep -c '.')"
if printf '%s\n' "$specs" | run_members "$root" "$jobs" "$cache"; then
  echo "run-tests: all green ($root, mode=$mode, members=$nsel, jobs=$jobs${cache:+, cache})"; exit 0
fi
echo "run-tests: one or more suites failed" >&2; exit 1
