#!/usr/bin/env bash
# select-pipeline.sh — advisory pipeline selector (right-sizing check).
#
# Pipeline choice (single-thread | mvp | full) is the one high-leverage decision the
# delivery gate leaves entirely to the operator — and the pressure that makes people
# skip review ("just ship it") is the same pressure that picks the LIGHTER pipeline to
# skip the Phase-A ceremony. Nothing else in the flow catches an under-sized choice.
# This does: it reads the change's diff and recommends a pipeline, so "you chose
# single-thread but this touches auth across three layers" becomes VISIBLE.
#
# It is ADVISORY, never a block: the operator still decides (constitution P1). A visible
# recommendation is the point; a hard gate here would just relocate the same soft call.
#
# Signals (from the diff):
#   - file count, non-doc lines changed, distinct top-level layers touched (size)
#   - risk touches (path/name match): security/auth, data/schema/migrations,
#     infra/deploy, public API/contract, dependency manifests
# Any single risk touch lifts the recommendation to `full` (multi-role + audit trail,
# the sanctioned use for security/regulated/production work — P1).
#
# Usage:
#   bin/select-pipeline.sh [--chosen single-thread|mvp|full] [<git-range>]
#       default diff: uncommitted working tree (vs HEAD); if clean, <base>..HEAD.
#   bin/select-pipeline.sh --from-stdin [--chosen ...]   # read numstat on stdin
#   bin/select-pipeline.sh --self-test
# Exit: 0 right-sized (chosen >= recommended, or no --chosen)
#       2 under-sized (chosen LIGHTER than recommended — advisory)
#       64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

# rank: single-thread < mvp < full
_rank() { case "$1" in single-thread) printf 1 ;; mvp) printf 2 ;; full) printf 3 ;; *) printf '' ;; esac; }
_name() { case "$1" in 1) printf single-thread ;; 2) printf mvp ;; 3) printf full ;; esac; }

_is_doc() { case "$1" in *.md|*.mdx|*.txt|docs/*|references/*|LICENSE|CHANGELOG*) return 0 ;; *) return 1 ;; esac; }

# _is_nonrisk_layer PATH → rc 0 when PATH is NOT a load-bearing CODE layer for tier escalation (#108).
# The `layers>=N` triggers used to count directory DIVERSITY: docs/, specs/, config and a pure-test dir
# each registered as a "layer", so a doc-heavy milestone with a thin code surface tripped layers>=3 →
# full and paid a four-role panel to confirm a version bump. Doc, spec, config and pure-test paths carry
# no architectural blast-radius, so they are excluded from the LAYER count only — file count, non-doc
# line count and every RISK category are untouched, so nothing that actually carries risk is discounted
# (a schema/auth/api/deps/infra touch still escalates regardless of how many layers were dropped).
_is_nonrisk_layer() {
  _is_doc "$1" && return 0
  is_test_path "$1" && return 0
  case "$1" in
    specs/*|*/specs/*) return 0 ;;                               # a spec is not a code layer
    config/*|*/config/*) return 0 ;;                             # a config directory
    *.yml|*.yaml|*.toml|*.ini|*.cfg|*.conf|*.json|*.lock) return 0 ;;   # config/data/lockfile formats
    .*) return 0 ;;                                              # dotfiles (.gitignore, .editorconfig, …)
  esac
  return 1
}

# --- #125: `deps` fires on a real DEPENDENCY-SECTION change, not the manifest filename ---------------
# The category exists for a sound reason — a new/changed dependency is an IP + supply-chain event — but
# keying it on the package.json FILENAME misclassified a `scripts`/`name`/`version`-only edit as a
# dependency event, pulling security + overengineering + ip-contracts reviewers for "no new dependency".
# When the real diff is available (any git-sourced mode), a package.json only trips `deps` if its
# dependency SECTIONS actually differ. A LOCKFILE change is always a real dependency event and still
# trips it unconditionally. Spec-sourced sizing (--from-stdin, no diff) keeps the conservative filename
# match: a spec that merely names a manifest cannot prove the change is scripts-only.

# _show_blob REF PATH → the file content at REF (a git ref), or the WORKING-TREE file when REF is "".
_show_blob() { if [ -z "$1" ]; then cat "$2" 2>/dev/null; else git show "$1:$2" 2>/dev/null; fi; }

# _dep_fingerprint  (stdin: a package.json) → a stable, order-independent line per entry of the four
# dependency sections (dependencies/devDependencies/peerDependencies/optionalDependencies). Comparing
# the fingerprint of the old and new file answers "did the dependency sections change" directly, without
# fragile hunk parsing: a scripts/name/version edit leaves the fingerprint identical, any add / remove /
# version bump changes it. Dep values are JSON strings (never nested objects), so a single level of
# brace tracking is exact for the standard pretty-printed manifest.
_dep_fingerprint() {
  awk '
    function nb(s,  n,i,c){n=0;for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="{")n++;else if(c=="}")n--}return n}
    BEGIN{depth=0; insec=0; secname=""; secdepth=0}
    {
      line=$0
      if (insec) {
        tmp=line
        while (match(tmp,/"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
          print secname "\t" substr(tmp,RSTART,RLENGTH)
          tmp=substr(tmp,RSTART+RLENGTH)
        }
        depth += nb(line)
        if (depth <= secdepth) insec=0
        next
      }
      if (match(line,/"(dependencies|devDependencies|peerDependencies|optionalDependencies)"[[:space:]]*:[[:space:]]*\{/)) {
        sn=line; sub(/^[^"]*"/,"",sn); sub(/".*/,"",sn)
        d=nb(line)
        if (d>0) { insec=1; secname=sn; secdepth=depth; depth+=d }
        else     { depth+=d }
        next
      }
      depth += nb(line)
    }
  ' | LC_ALL=C sort
}

# _dep_sections_differ OLDREF NEWREF PATH → rc 0 when the dependency sections differ between the two
# sides. A ref of "" means the working tree.
_dep_sections_differ() {
  [ "$(_show_blob "$1" "$3" | _dep_fingerprint)" != "$(_show_blob "$2" "$3" | _dep_fingerprint)" ]
}

# _pkgjson_dep_changed PATH → rc 0 when this package.json's dependency sections changed, using the diff
# window the acquisition block set via globals: $_DEPS_SHAS (a batch's commits, checked one at a time),
# else $_DEPS_OLDREF/$_DEPS_NEWREF. Consulted only when $_DEPS_INSPECT=1.
_pkgjson_dep_changed() {
  local path="$1" c
  if [ -n "${_DEPS_SHAS:-}" ]; then
    for c in $_DEPS_SHAS; do _dep_sections_differ "$c^" "$c" "$path" && return 0; done
    return 1
  fi
  _dep_sections_differ "${_DEPS_OLDREF:-}" "${_DEPS_NEWREF:-}" "$path"
}

# _untracked_numstat — emit numstat lines ("<lines>\t0\t<path>") for untracked files,
# which `git diff` omits. Each untracked file counts as all-additions.
_untracked_numstat() {
  local f n
  git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(wc -l <"$f" 2>/dev/null | tr -d ' ')"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\t0\t%s\n' "$n" "$f"
  done
}

# recommend — read numstat ("<add>\t<del>\t<path>") on stdin, emit one line:
#   <rec_rank>\t<files>\t<nondoc_lines>\t<layers>\t<reasons>
recommend() {
  local add del path files=0 nondoc=0 layers="" lc docpaths=""
  local sec=0 data=0 infra=0 api=0 deps=0 ui=0 perf=0 lic=0 hastest=0
  # NOTE (ADR-0018): every directory pattern must carry BOTH the root form and the nested form.
  # `*/api/*` does not match `api/routes.ts` at the repo root — there is no parent segment to match
  # `*/`. That silently under-escalated root-level api/, models/ and .github/workflows/ changes, in
  # DIFF-sourced sizing too (git diff --numstat emits the root form). The deps line already had the
  # both-forms idiom (`*/package.json|package.json`); the other three did not.
  while IFS="$(printf '\t')" read -r add del path || [ -n "${path:-}" ]; do
    [ -n "${path:-}" ] || continue
    files=$((files + 1))
    # #108 — only load-bearing CODE paths contribute an architectural layer. Doc/spec/config/pure-test
    # paths are counted as files but not as risk-bearing layers, so path diversity alone cannot buy a
    # heavier tier. A risk category still escalates regardless (handled below).
    if ! _is_nonrisk_layer "$path"; then
      case "$path" in */*) layers="$layers ${path%%/*}" ;; *) layers="$layers ." ;; esac
    fi
    if _is_doc "$path"; then docpaths="$docpaths $path"; fi
    if ! _is_doc "$path"; then
      case "$add" in ''|*[!0-9]*) add=0 ;; esac
      case "$del" in ''|*[!0-9]*) del=0 ;; esac
      nondoc=$((nondoc + add + del))
    fi
    lc="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in *auth*|*login*|*password*|*passwd*|*secret*|*token*|*credential*|*crypto*|*oauth*|*jwt*|*session*|*payment*|*billing*|*checkout*) sec=1 ;; esac
    case "$lc" in *migrat*|*schema*|*.sql|models/*|model/*|entities/*|*/models/*|*/model/*|*/entities/*|*prisma*|*alembic*) data=1 ;; esac
    case "$lc" in *dockerfile*|*.tf|*.tfvars|*k8s*|*kubernetes*|*helm*|.github/workflows/*|*/.github/workflows/*|*railway*|*render.yaml|*fly.toml|*vercel.json|*netlify.toml|*procfile|*deploy*) infra=1 ;; esac
    case "$lc" in *openapi*|*swagger*|*.proto|api/*|routes/*|route/*|*/api/*|*/routes/*|*/route/*|*graphql*|*.graphql|*contract*) api=1 ;; esac
    # #125 — split the manifest set: a LOCKFILE change is always a real dependency event; a package.json
    # trips `deps` only when its dependency sections actually changed (when a diff is available); the
    # other manifest formats keep the filename match (no JSON dep-section parser for them).
    case "$lc" in
      *package-lock*|*pnpm-lock*|*yarn.lock|*go.sum) deps=1 ;;                 # lockfile → always
      */package.json|package.json)
        if [ "${_DEPS_INSPECT:-0}" = 1 ]; then
          _pkgjson_dep_changed "$path" && deps=1                              # real dep-section change
        else
          deps=1                                                             # spec-sourced ⇒ conservative
        fi ;;
      *go.mod|*requirements*.txt|*pipfile*|*pyproject.toml|*cargo.toml|*gemfile|*composer.json) deps=1 ;;
    esac
    # roles-alive phase 1 (second wave) — a USER-FACING surface. Extension-driven, because that is the
    # one part of "is this UI" a path can actually answer; the both-forms idiom applies here too.
    case "$lc" in *.tsx|*.jsx|*.vue|*.svelte|*.html|*.css|*.scss|*.sass|components/*|*/components/*|ui/*|*/ui/*|views/*|*/views/*|pages/*|*/pages/*) ui=1 ;; esac
    # A DECLARED performance surface, deliberately narrow. This is not a hot-path detector: no path
    # pattern answers "is this hot", and a guess would route the role at noise while looking exactly as
    # load-bearing to eval-role --liveness. Paths the repo itself calls performance work, nothing more.
    case "$lc" in bench/*|*/bench/*|benchmark*|*/benchmark*|*.bench.*|perf/*|*/perf/*|*loadtest*|*load-test*|*.jmx|*k6*) perf=1 ;; esac
    # milestone 020, Д2 §1.2 — LICENCE surface. Distinct from `deps`: a manifest change is an IP event
    # (a new transitive dependency can carry a copyleft obligation), while an edit to the licence text
    # itself is a compliance event. They route to different roles for that reason.
    case "$lc" in license|licence|license.*|licence.*|copying|copying.*|notice|notice.*|*/license|*/licence|*/license.*|*/licence.*|*/copying|*/notice) lic=1 ;; esac
    # milestone 020, Д2 §1.2 — "test-designer при отсутствии тестов в диффе". Recorded per file here;
    # the CATEGORY is derived after the loop, because "no test file" is a property of the whole diff and
    # cannot be decided from any single path.
    if is_test_path "$path"; then hastest=1; fi
  done
  local nlayers
  nlayers="$(printf '%s' "$layers" | tr ' ' '\n' | grep -ve '^$' | sort -u | grep -c . || true)"
  case "$nlayers" in ''|*[!0-9]*) nlayers=0 ;; esac

  # ADR-0018 — an ALL-DOC change earns no review fan-out, whatever its shape. `_is_doc` used to govern
  # only the line count, so two documentation files in two directories tripped `layers>=2` and bought
  # mvp, and three tripped `layers>=3` and bought full — pure over-provisioning, the exact cost this
  # milestone exists to remove. Deliberately a short-circuit on the all-doc case only: a MIXED change
  # keeps every one of its code signals, so nothing that touches code is sized down by adding a README.
  local ndoc=0
  ndoc="$(printf '%s' "$docpaths" | tr ' ' '\n' | grep -c . || true)"
  case "$ndoc" in ''|*[!0-9]*) ndoc=0 ;; esac
  if [ "$files" -gt 0 ] && [ "$ndoc" -eq "$files" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' 1 "$files" "$nondoc" "$nlayers" "docs-only"
    return 0
  fi

  # RISK CATEGORY VOCABULARY. `reasons` carries two different kinds of token: SIZE reasons
  # (files>=3, lines>=150, layers>=2, docs-only) and RISK CATEGORIES (the seven below). Only the
  # second kind is a routing input — profiles/default.map keys on it, and the harness states it to the
  # model as "risk categories detected". `--categories` publishes the vocabulary from HERE, beside the
  # lines that emit it, so no caller has to keep a second copy in sync (the _roles_for lesson).
  local rec=1 reasons=""
  if [ "$files" -ge 3 ] || [ "$nondoc" -ge 150 ] || [ "$nlayers" -ge 2 ] || [ "$deps" -eq 1 ]; then
    rec=2
    [ "$files" -ge 3 ] && reasons="$reasons files>=3"
    [ "$nondoc" -ge 150 ] && reasons="$reasons lines>=150"
    [ "$nlayers" -ge 2 ] && reasons="$reasons layers>=2"
    [ "$deps" -eq 1 ] && reasons="$reasons deps"
  fi
  local full=0
  [ "$files" -ge 10 ] && { full=1; reasons="$reasons files>=10"; }
  [ "$nondoc" -ge 600 ] && { full=1; reasons="$reasons lines>=600"; }
  [ "$nlayers" -ge 3 ] && { full=1; reasons="$reasons layers>=3"; }
  [ "$sec" -eq 1 ] && { full=1; reasons="$reasons security/auth"; }
  [ "$data" -eq 1 ] && { full=1; reasons="$reasons data/schema"; }
  [ "$infra" -eq 1 ] && { full=1; reasons="$reasons infra/deploy"; }
  [ "$api" -eq 1 ] && { full=1; reasons="$reasons api/contract"; }
  # `ui` is a COMPOSITION signal, not a depth one: an accessibility defect is not more likely on a
  # bigger change, so it routes a role (profiles/default.map) without lifting the tier. Recording it in
  # `reasons` is what makes it routable at all — the categories are the routing input.
  [ "$ui" -eq 1 ] && reasons="$reasons ui"
  # Composition signals, like `ui`: they summon a role without lifting the tier.
  [ "$perf" -eq 1 ] && reasons="$reasons perf"
  [ "$lic" -eq 1 ] && reasons="$reasons licence"
  # `no-tests` is a property of the DIFF, not of any one path: non-doc work changed and no test file
  # came with it. It cannot lift the tier — shipping untested code is not a bigger change, it is an
  # unreviewed one — so like `ui` and `perf` it summons a role and leaves the depth alone. A doc-only
  # diff never reaches here (the all-doc short-circuit returns above), so this cannot fire on prose.
  [ "$hastest" -eq 0 ] && [ "$nondoc" -gt 0 ] && reasons="$reasons no-tests"
  [ "$full" -eq 1 ] && rec=3

  printf '%s\t%s\t%s\t%s\t%s\n' "$rec" "$files" "$nondoc" "$nlayers" "${reasons# }"
}

# report REC_LINE CHOSEN — print human-readable verdict, return the exit code.
report() {
  local line="$1" chosen="$2" rec files nondoc nlayers reasons
  rec="$(printf '%s' "$line" | cut -f1)"
  files="$(printf '%s' "$line" | cut -f2)"
  nondoc="$(printf '%s' "$line" | cut -f3)"
  nlayers="$(printf '%s' "$line" | cut -f4)"
  reasons="$(printf '%s' "$line" | cut -f5)"
  echo "select-pipeline: change scope — ${files} file(s), ${nondoc} non-doc line(s), ${nlayers} layer(s)."
  [ -n "$reasons" ] && echo "select-pipeline: signals — ${reasons}."
  echo "select-pipeline: RECOMMENDED pipeline: $(_name "$rec")${reasons:+  (reasons: ${reasons})}"
  if [ -n "$chosen" ]; then
    local cr; cr="$(_rank "$chosen")"
    if [ -z "$cr" ]; then echo "select-pipeline: bad --chosen '$chosen'" >&2; return 64; fi
    if [ "$cr" -lt "$rec" ]; then
      echo "select-pipeline: ADVISORY — chosen '${chosen}' is LIGHTER than recommended '$(_name "$rec")'. Consider '/team-bootstrap:deliver $(_name "$rec") …'. Operator decides (P1); this is a visible recommendation, not a block." >&2
      return 2
    fi
    if [ "$cr" -gt "$rec" ]; then
      # The missing direction (#27). The tool already computed everything needed to say this; staying
      # silent made the advisory one-directional — it could only ever push cost UP. Each extra review
      # role is an independent subagent (measured 3.6-11.8 min), and Anthropic measures multi-agent at
      # ~15x the tokens of a chat, so this is the single largest cost lever in the pipeline.
      # NOT a failure: exit stays 0. Blocking over-provisioning would push the orchestrator to review
      # INLINE — the spec-169 collapse (see the milestone spec's enforceability boundary).
      echo >&2 "select-pipeline: OVER-PROVISIONED — chosen '${chosen}' is HEAVIER than recommended '$(_name "$rec")'. Each extra review role is a separate subagent (~3.6-11.8 min each). Consider '$(_name "$rec")' for this scope. Operator decides (P1); advice, not a block."
      return 0
    fi
    echo "select-pipeline: chosen '${chosen}' >= recommended '$(_name "$rec")' — right-sized."
  fi
  return 0
}

# _batch_line BATCH_ID LEDGER → that batch's ledger line, or empty. The id is validated to a plain
# charset before it reaches grep: an unvalidated id is a regex, and `--batch 'B.'` silently sized `B1`
# and reported the verdict under the wrong name (review MEDIUM).
_batch_line() {
  local bid="$1" ledger="$2" line
  # The id must never reach a regex. Round-1 escaped the charset but left `.` legal — and `.` is a BRE
  # metacharacter, so `--batch 'B.'` still matched B1 and silently sized ANOTHER batch's window and
  # risk_rank (round-2 review). Match the id EXACTLY, through the plugin's own space-tolerant reader,
  # so no character is special and a spaced-JSON ledger line still resolves.
  case "$bid" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(field_str "$line" id)" = "$bid" ] && printf '%s' "$line"
  done < "$ledger" | tail -1
}

# _batch_numstat BATCH_ID → emit numstat for THAT batch's own window (#27: cost accrues per batch,
# not per run). Uses the batch's commit_shas when it has them; an announced batch with none yet is
# still in flight, so its window is baseline..HEAD. Empty output ⇒ caller falls back to the run range.
_batch_numstat() {
  local bid="$1" ledger line shas base c
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(_batch_line "$bid" "$ledger")"
  [ -n "$line" ] || return 0
  shas="$(shas_of_line "$line")"
  if [ -n "$shas" ]; then
    # files/layers are SET cardinalities, so a path touched by BOTH the red and the green commit must
    # count once — otherwise every batch inflates upward and suppresses the OVER-PROVISIONED verdict
    # this milestone adds. Sum the line counts per path, keep one row per path.
    for c in $shas; do git diff --numstat "$c^" "$c" 2>/dev/null; done \
      | awk 'BEGIN{FS=OFS="\t"} {a[$3]+=$1; d[$3]+=$2} END{for(p in a) print a[p], d[p], p}'
  else
    # In-flight batch (no commit_shas yet): the window is the ONE definition the stamp and F2 already
    # use — current_batch_base() (last closed batch's newest commit → baseline → base ref → HEAD~1).
    # The run's baseline_sha is WRONG here: it drags every previously CLOSED batch's commits into this
    # batch's window (review CRITICAL), which is exactly the per-run-vs-per-batch defect #27 is about.
    base="$(current_batch_base)"
    [ -n "$base" ] && git diff --numstat "$base" HEAD 2>/dev/null
  fi
}

# _batch_risk_floor BATCH_ID → the minimum tier this batch's DECLARED risk_rank demands (empty = none).
# risk_rank is self-declared and forgeable (ADR-0006), so it only ever LIFTS the recommendation — it can
# never lower one the diff earned. A doc batch floors at the lightest tier.
_batch_risk_floor() {
  local bid="$1" ledger line rr
  ledger="$(resolve_ledger)"; [ -n "$ledger" ] && [ -f "$ledger" ] || return 0
  line="$(_batch_line "$bid" "$ledger")"
  [ -n "$line" ] || return 0
  rr="$(field_str "$line" risk_rank)"
  case "$rr" in irreversible|run-rate) printf '3' ;; *) : ;; esac
}

# --- arg parse ---------------------------------------------------------------
chosen=""; from_stdin=0; range=""; batch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chosen) chosen="${2:-}"; shift 2 ;;
    --batch)  batch="${2:-}";  shift 2 ;;
    --from-stdin) from_stdin=1; shift ;;
    --categories) printf 'security/auth data/schema infra/deploy api/contract deps ui perf licence no-tests\n'; exit 0 ;;
    --self-test) selftest=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "select-pipeline: unknown flag '$1'" >&2; exit 64 ;;
    *) range="$1"; shift ;;
  esac
done

# --- self-test ---------------------------------------------------------------
if [ "${selftest:-0}" -eq 1 ]; then
  fail=0
  _expect() { # desc expected_rank  (numstat on stdin)
    local desc="$1" exp="$2" got
    got="$(recommend | cut -f1)"
    if [ "$got" = "$exp" ]; then echo "  PASS (rec=$(_name "$got")) $desc"
    else echo "  FAIL (rec=$got, want $exp) $desc" >&2; fail=$((fail + 1)); fi
  }
  printf '5\t0\tREADME.md\n'                                   | _expect "docs-only → single-thread" 1
  printf '20\t5\tsrc/util.ts\n'                                | _expect "one small code file → single-thread" 1
  printf 'a\tb\tsrc/x\n30\t0\tsrc/y\n5\t0\tlib/z\n2\t0\tlib/w\n'| _expect "4 files / 2 layers → mvp" 2
  printf '10\t0\tdb/migrations/001.sql\n'                      | _expect "migration/sql → full" 3
  printf '5\t0\tsrc/auth/login.ts\n'                           | _expect "auth touch → full" 3
  printf '3\t0\tinfra/Dockerfile\n'                            | _expect "Dockerfile → full" 3
  printf '4\t0\tsvc/api/routes.ts\n'                           | _expect "api/routes → full" 3
  printf '1\t0\tpackage.json\n'                                | _expect "dependency manifest → mvp" 2
  # exit-code mapping via --chosen
  ec() { printf '%s' "$2" | "$0" --from-stdin --chosen "$1" >/dev/null 2>&1; echo $?; }
  r="$(ec single-thread "$(printf '5\t0\tsrc/auth/login.ts\n')")"; [ "$r" = 2 ] && echo "  PASS under-sized (single-thread vs full) → exit 2" || { echo "  FAIL under-sized exit=$r want 2" >&2; fail=$((fail+1)); }
  r="$(ec full "$(printf '5\t0\tsrc/auth/login.ts\n')")";        [ "$r" = 0 ] && echo "  PASS right-sized (full vs full) → exit 0" || { echo "  FAIL right-sized exit=$r want 0" >&2; fail=$((fail+1)); }
  r="$(ec mvp "$(printf '20\t0\tsrc/util.ts\n')")";              [ "$r" = 0 ] && echo "  PASS over-sized (mvp vs single-thread) → exit 0" || { echo "  FAIL over-sized exit=$r want 0" >&2; fail=$((fail+1)); }
  if [ "$fail" -eq 0 ]; then echo "select-pipeline --self-test: OK"; exit 0; fi
  echo "select-pipeline --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- acquire the diff --------------------------------------------------------
if [ "$from_stdin" -eq 1 ]; then
  line="$(recommend)"
else
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "select-pipeline: not a git repository." >&2; exit 64; }
  numstat=""
  # #125 — a real diff exists in every git-sourced mode, so recommend inspects package.json dependency
  # sections instead of matching the filename. Each branch below points the inspector at ITS OWN window.
  _DEPS_INSPECT=1; _DEPS_OLDREF="HEAD"; _DEPS_NEWREF=""; _DEPS_SHAS=""
  if [ -n "$batch" ]; then
    # Declared-but-unresolvable fails LOUD (review HIGH): a typo'd or mis-plumbed id used to read as
    # "no changes detected" with exit 0, silently voiding the --chosen contract — the same
    # declared-but-unresolvable class check-completeness already fixed once.
    _bl="$(resolve_ledger)"
    _batchline="$(_batch_line "$batch" "$_bl" 2>/dev/null || true)"
    if [ -z "$_bl" ] || [ ! -f "$_bl" ] || [ -z "$_batchline" ]; then
      echo "select-pipeline: --batch '$batch' does not resolve to a ledger entry (no active ledger, or no such batch id). Refusing to size the wrong window." >&2
      exit 64
    fi
    numstat="$(_batch_numstat "$batch")"
    # Same window _batch_numstat uses: the batch's own commits when it has them (each dep-inspected as
    # c^..c), else the in-flight window current_batch_base..HEAD.
    _DEPS_SHAS="$(shas_of_line "$_batchline")"
    if [ -z "$_DEPS_SHAS" ]; then _DEPS_OLDREF="$(current_batch_base)"; _DEPS_NEWREF="HEAD"; fi
  elif [ -n "$range" ]; then
    numstat="$(git diff --numstat "$range" 2>/dev/null || true)"
    case "$range" in
      *..*) _DEPS_OLDREF="${range%%..*}"; _DEPS_NEWREF="${range##*..}" ;;   # A..B / A...B → A vs B
      *)    _DEPS_OLDREF="$range"; _DEPS_NEWREF="" ;;                        # single rev vs working tree
    esac
  else
    # one stream, captured once (accumulating per-line via $() would strip newlines):
    # tracked uncommitted diff + untracked files counted as additions (git diff omits them).
    numstat="$( { git diff --numstat HEAD 2>/dev/null || true; _untracked_numstat; } )"
    # default window: HEAD vs working tree (already the _DEPS default above)
    if [ -z "$(printf '%s' "$numstat" | tr -d '[:space:]')" ]; then   # clean tree → branch vs base
      base=""
      for b in origin/main main origin/master master; do
        git rev-parse --verify -q "$b" >/dev/null 2>&1 && { base="$b"; break; }
      done
      if [ -n "$base" ]; then
        numstat="$(git diff --numstat "$base..HEAD" 2>/dev/null || true)"
        _DEPS_OLDREF="$base"; _DEPS_NEWREF="HEAD"
      fi
    fi
  fi
  if [ -z "$numstat" ]; then
    if [ -n "$batch" ] && [ -n "$(_batch_risk_floor "$batch")" ]; then
      line="$(printf '1\t0\t0\t0\t')"   # empty window, but a declared risk floor still applies
    else
      echo "select-pipeline: no changes detected — nothing to size."
      exit 0
    fi
  else
    line="$(printf '%s\n' "$numstat" | recommend)"
  fi
fi

# --batch (#27): the recommendation is for THAT batch, lifted by its declared risk_rank. The lift is
# one-directional on purpose — risk_rank is self-declared and forgeable (ADR-0006), so it may raise a
# recommendation the diff did not earn, never lower one it did.
if [ -n "$batch" ]; then
  _floor="$(_batch_risk_floor "$batch")"
  if [ -n "$_floor" ]; then
    _rec_now="$(printf '%s' "$line" | cut -f1)"
    if [ "$_floor" -gt "${_rec_now:-1}" ]; then
      line="$(printf '%s' "$line" | awk -v f="$_floor" 'BEGIN{FS=OFS="\t"} {$1=f; $5=($5=="" ? "declared risk_rank" : $5 " + declared risk_rank")} 1')"
    fi
  fi
fi

report "$line" "$chosen"
exit $?
