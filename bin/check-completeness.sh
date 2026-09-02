#!/usr/bin/env bash
# check-completeness.sh — closure-fidelity gate B: closure must certify FIDELITY, not just "tests green".
#
# The recurring post-/deliver symptom is a review that keeps finding undone tasks and unimplemented spec
# parts: closure today certifies mechanics (code_delta + gates green), never that the batch's declared
# work is actually done, nor that every acceptance criterion is exercised by a test. B closes that gap.
#
# Two modes:
#   PER-BATCH (default) — every task_id in the in-flight ledger entry must be checked [x] in
#     specs/<slug>/tasks.md (slug from the marker `feature`). Any [ ] (or a task_id absent from tasks.md)
#     ⇒ fail. Catches "closed but its own task left undone" (AC-3). B READS tasks.md — never writes it.
#   --final — run by /deliver at milestone end: (1) NO [ ] may remain in tasks.md, and (2) every `AC-N`
#     token in spec.md must appear in ≥1 is_test_path file (`AcPattern:` overrides the AC-[0-9]+ default).
#     An unchecked task or an AC with no test reference ⇒ fail (AC-4). The AC→test half is the
#     machine-grounded check; the [x] half catches the forgotten box (honesty of [x] is the orchestrator's).
#
# Graceful skips (exit 0): no active marker / not intends_code (AC-6); no tasks.md or spec.md to check
# (WARN — unenforceable, never a false block, mirrors the peer gates).
#
# Usage: bin/check-completeness.sh [project-dir]        # per-batch
#        bin/check-completeness.sh --final [project-dir] # milestone finalization
#        bin/check-completeness.sh --self-test
# Exit:  0 pass / skip · 1 incomplete (unchecked task or unreferenced AC) · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

_doc() { local f; for f in AGENTS.md CLAUDE.md; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done; }
_val() { grep -iE "^[[:space:]]*[-*]?[[:space:]]*$1:" "$2" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | tr -d '`' | xargs 2>/dev/null || true; }

# _feature_declared MK → rc 0 if the marker DECLARES a real spec path (non-empty and not the
# no-spec sentinel `unknown`/`none`/`n/a`). A direct pipeline run (`/team-bootstrap single-thread …`)
# records `feature:"unknown"` — genuinely no spec to check, a graceful skip, NOT a fail.
_feature_declared() {
  local feat; feat="$(field_str "$1" feature)"
  case "$feat" in ''|unknown|Unknown|UNKNOWN|none|None|NONE|n/a|N/A|N/a) return 1 ;; *) return 0 ;; esac
}

# _spec_from_marker → echo the spec.md path from the marker `feature`, NORMALIZED. A /deliver arg is
# often a bare directory/slug (`specs/<slug>`), not the spec.md file — recording that verbatim made the
# tasks.md/spec.md lookup miss and the whole gate silently skip (the exec-role-integrity green-by-skip).
# Rule: a value already ending in `.md` is used as-is; anything else (dir or slug, with/without a
# trailing slash) gets `/spec.md` appended, so both forms resolve to the same file.
_spec_from_marker() {
  local mk="$1" feat
  feat="$(field_str "$mk" feature)"
  [ -n "$feat" ] || return 0
  case "$feat" in
    *.md) : ;;                        # already a file path (spec.md or an explicit .md) — use as-is
    *)    feat="${feat%/}/spec.md" ;; # dir or slug (± trailing slash) → the spec.md inside it
  esac
  printf '%s' "$feat"
}
# _task_ids LINE → space-separated task_ids from a ledger entry's "task_ids":[…]. Isolate the bracket
# body FIRST (via \[[^]]*\]) so the "task_ids" key itself is not scooped up as a token.
_task_ids() {
  printf '%s' "$1" | grep -oE '"task_ids":[[:space:]]*\[[^]]*\]' | head -1 \
    | grep -oE '\[[^]]*\]' | head -1 \
    | grep -oE '"[A-Za-z0-9_.-]+"' | tr -d '"' | tr '\n' ' '
}
# _test_path_files DIR → list files under DIR that is_test_path accepts (find-based; no git dependency,
# so it works identically in the repo and in the self-test tmp). Prunes VCS/build/vendor dirs.
_test_path_files() {
  local tglobs; tglobs="$(read_test_globs)"
  local f
  while IFS= read -r f; do
    f="${f#./}"
    is_test_path "$f" "$tglobs" && printf '%s\n' "$f"
  done < <(find "${1:-.}" \
    \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name dist \
       -o -name build -o -name .next -o -name __pycache__ -o -name .runs \) -prune \
    -o -type f -print 2>/dev/null)
}

# _spec_test_files SPEC [DIR] → the test-path files ASSOCIATED with SPEC (issue #94). The AC→test half
# used to grep EVERY test file in the repo, but `AC-N` numbering is shared across all specs, so a same-
# numbered token in an UNRELATED spec's test satisfied this spec's AC by coincidental collision — the
# gate read green without proving THIS spec's ACs are tested. Scope the search to the spec's own tests:
# a test file counts as this spec's when it lives under the spec's directory, or NAMES the spec's slug
# (the spec dir's basename) in its path or its content. An AC in spec X is then satisfiable only by a
# test tied to spec X. (Association widening — declared test dirs, batch-touched paths — can be layered
# on this later; the slug is the discriminator that removes the cross-spec false positive.)
_spec_test_files() {
  local spec="$1" specdir slug num numre f
  specdir="$(dirname "$spec")"; slug="$(basename "$specdir")"
  # #94 (widen the association): the FULL multi-word slug (`108-cited-table-cell-false-degrade`) is
  # stricter than needed — a test named by the spec NUMBER (`_108.py`) or carrying a declared
  # `Spec:`/`SpecId:` tag is plainly this spec's, yet embeds no full slug. So also associate by the spec
  # NUMBER prefix and by a Spec tag. The number is matched as a BOUNDED token so the per-spec scoping that
  # closes the cross-spec collision holds: 108 ≠ 107, and ≠ a partial like 1080 / 2108.
  num="$(printf '%s' "$slug" | grep -oE '^[0-9]+' || true)"
  numre=""; [ -n "$num" ] && numre="(^|[^0-9])${num}([^0-9]|\$)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      "$specdir"/*) printf '%s\n' "$f"; continue ;;   # under the spec's own directory
      *"$slug"*)    printf '%s\n' "$f"; continue ;;    # names the slug in its path (tests/*_<slug>*, …)
    esac
    # spec NUMBER as a bounded token in the PATH (tests/*_108.py, 108-*, …) — never 107 / 1080 / 2108.
    if [ -n "$numre" ] && printf '%s' "$f" | grep -qE "$numre"; then printf '%s\n' "$f"; continue; fi
    # names the full slug in its content (a header comment / tag tying the suite to this spec). Fixed-string
    # (grep -F): the slug is a unique spec-dir name, so containment is a strong, metachar-safe signal.
    grep -Fq -- "$slug" "$f" 2>/dev/null && { printf '%s\n' "$f"; continue; }
    # a declared `Spec:`/`SpecId:`/`Spec-Id:` tag whose value carries THIS spec's number (bounded). The
    # tag scopes the number to a deliberate association, so a bare `== 108` in a test body is not enough.
    if [ -n "$numre" ] && grep -iE '(^|[^a-z])spec[-_]?(id)?:' "$f" 2>/dev/null | grep -qE "$numre"; then
      printf '%s\n' "$f"; continue
    fi
  done < <(_test_path_files "${2:-.}")
}

# _ac_deferred_live AC  (test-file list on stdin) → rc 0 if AC is carried by a sanctioned deferred-live
# marker (`DeferredLiveAC:` / `deferred_live` / `deferred-live`) in some associated test file (issue
# #100). A live/P5-gated AC deferred to a live run cannot host a running assertion, so its DEFERRAL
# marker IS its reference — but ONLY when the run carries a governed deferred_live_waiver (checked by the
# caller); an ungoverned marker is a bare comment and does not count (B6).
_ac_deferred_live() {
  local ac="$1" f acre
  acre="(^|[^0-9A-Za-z])${ac}([^0-9A-Za-z]|\$)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -iE 'DeferredLiveAC|deferred[_-]live' "$f" 2>/dev/null | grep -qE "$acre" && return 0
  done
  return 1
}

# Default test/assertion construct pattern (ERE). An AC token counts as *asserted* only when it sits
# within a few lines of one of these — so a bare `# AC-1 AC-2` comment far from any test no longer
# satisfies the AC→test check (a reference-only pass). Override/extend via AGENTS.md `AcTestPattern:`.
# Honest limit: this raises the reference floor to "co-located with a real test construct"; whether the
# test actually asserts the AC's behaviour is still F3 (mutation), not this gate.
DEFAULT_AC_TEST_PAT='assert|expect\(|def[[:space:]]+test|func[[:space:]]+Test|[^A-Za-z]it\(|describe\(|[^A-Za-z]test\(|@Test|#\[test\]|t\.Run|Scenario|EXPECT_|ASSERT_|_chk|_expect|should\('

# _ac_in_tests AC PAT W  (test-file list on stdin) → rc 0 if the AC token (word-boundary) appears in
# some test-path file within W lines of a line matching the construct pattern PAT.
_ac_in_tests() {
  local ac="$1" pat="$2" w="${3:-3}" f acre
  acre="(^|[^0-9A-Za-z])${ac}([^0-9A-Za-z]|$)"
  # Pass regexes via ENVIRON, NOT awk -v: -v runs backslash-escape processing that strips the `\(`/`\[`
  # in the construct pattern, corrupting the regex ("illegal primary"). ENVIRON values are used verbatim.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    AC_RE="$acre" AC_PAT="$pat" AC_W="$w" awk '
      BEGIN { acre = ENVIRON["AC_RE"]; pat = ENVIRON["AC_PAT"]; w = ENVIRON["AC_W"] + 0 }
      $0 ~ acre { a[NR] = 1 }
      $0 ~ pat  { c[NR] = 1 }
      END { for (i in a) for (j in c) { d = (i > j) ? i - j : j - i; if (d <= w) exit 0 } exit 1 }
    ' "$f" && return 0
  done
  return 1
}

# --- per-batch ----------------------------------------------------------------
_per_batch() {
  local marker mk spec tasks ledger line ids tid viol=0 entry
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-completeness: no active delivery run — skipping (governs armed runs)."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-completeness: marker not intends_code — skipping."; return 0; }
  # A run that declares NO spec (direct pipeline: feature unknown/empty) has nothing to check — skip.
  _feature_declared "$mk" || { echo "check-completeness: marker declares no spec (feature unknown/empty) — direct/non-spec run, nothing to check per-batch."; return 0; }
  spec="$(_spec_from_marker "$mk")"
  tasks="$(dirname "$spec")/tasks.md"
  # An armed run that DECLARES a feature whose tasks.md cannot be resolved is a green-by-skip hole, not a
  # graceful no-op — FAIL LOUD (fix the marker feature path or add tasks.md), never silently pass.
  [ -f "$tasks" ] || { echo "  FAIL-CLOSED: armed run declares feature '$(field_str "$mk" feature)' but no tasks.md at '$tasks' — per-batch completeness is unenforceable on a declared-spec run; this would be a green-by-skip. Point the marker feature at specs/<slug>/spec.md (or the dir) and ensure tasks.md exists." >&2; return 1; }

  ledger="$(resolve_ledger)"
  [ -n "$ledger" ] && [ -f "$ledger" ] || { echo "check-completeness: no ledger — nothing to check per-batch."; return 0; }
  line="$(grep '"status":[[:space:]]*"announced"' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || line="$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)"
  [ -n "$line" ] || { echo "check-completeness: no in-flight batch — nothing to check."; return 0; }

  ids="$(_task_ids "$line")"
  [ -n "$ids" ] || { echo "check-completeness: in-flight batch declares no task_ids — nothing to check."; return 0; }

  for tid in $ids; do
    if grep -qE "\[[xX]\][^]]*[^0-9A-Za-z]${tid}([^0-9A-Za-z]|\$)" "$tasks" 2>/dev/null; then
      continue
    elif grep -qE "(^|[^0-9A-Za-z])${tid}([^0-9A-Za-z]|\$)" "$tasks" 2>/dev/null; then
      echo "  FAIL: task $tid is in $tasks but NOT checked [x] — a closing batch may not leave its own declared task undone (AC-3)." >&2
      viol=$((viol + 1))
    else
      echo "  FAIL: task $tid (declared by the in-flight batch) is absent from $tasks — cannot certify it done (AC-3)." >&2
      viol=$((viol + 1))
    fi
  done
  [ "$viol" -eq 0 ] || return 1
  echo "check-completeness: all in-flight batch task_ids [$ids] are [x] in $tasks — per-batch complete."
  return 0
}

# _spec_has_untokenized_acs SPEC → rc 0 if SPEC DECLARES acceptance criteria in a form the AC→test half
# cannot parse (issue #111): checkbox bullets (`- [ ] …`, the specs 179/180 form), or an "Acceptance"
# heading/label section that contains at least one list item. Used only when NO recognized AC token was
# found, to tell "genuinely no ACs" (graceful pass) from "has ACs the gate can't map" (fail-closed).
# `tolower` (not gawk IGNORECASE, which BSD/darwin awk lacks) keeps the detection portable.
_spec_has_untokenized_acs() {
  local spec="$1"
  # checkbox bullets anywhere are the unmarked-AC form — a strong, unambiguous signal.
  grep -qE '^[[:space:]]*[-*+][[:space:]]*\[[ xX]\]' "$spec" 2>/dev/null && return 0
  # an Acceptance heading/label opening a section that then lists at least one bullet/numbered item.
  awk '
    { line = tolower($0)
      is_heading = (line ~ /^[[:space:]]*#{1,6}[[:space:]]/)
      if ((is_heading && line ~ /acceptance/) \
          || line ~ /^[[:space:]]*\*{0,2}_?acceptance( criteria)?_?\*{0,2}[[:space:]]*:?[[:space:]]*$/) { insec = 1; next }
      if (is_heading) { insec = 0; next }
      if (insec && line ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$spec" 2>/dev/null && return 0
  return 1
}

# --- --final ------------------------------------------------------------------
_final() {
  local marker mk spec tasks doc acpat acs ac viol=0 files hit
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "check-completeness --final: no active delivery run — skipping."; return 0; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ "$(field_bool "$mk" intends_code)" = "true" ] || { echo "check-completeness --final: marker not intends_code — skipping."; return 0; }
  # No spec declared (direct/non-spec run) → nothing to finalize-check (graceful skip).
  _feature_declared "$mk" || { echo "check-completeness --final: marker declares no spec (feature unknown/empty) — nothing to finalize-check."; return 0; }
  spec="$(_spec_from_marker "$mk")"
  tasks="$(dirname "$spec")/tasks.md"
  # Declared feature but spec.md / tasks.md missing → FAIL LOUD (green-by-skip guard), never skip.
  [ -f "$spec" ] || { echo "  FAIL-CLOSED: armed run declares feature '$(field_str "$mk" feature)' but no spec.md at '$spec' — milestone completeness is unenforceable on a declared-spec run (green-by-skip). Point the marker feature at specs/<slug>/spec.md." >&2; return 1; }
  [ -f "$tasks" ] || { echo "  FAIL-CLOSED: armed run declares feature but no tasks.md at '$tasks' — cannot verify task completion at finalization (green-by-skip guard)." >&2; return 1; }

  # (1) no [ ] remaining in tasks.md
  if [ -f "$tasks" ] && grep -qE '^[[:space:]]*-[[:space:]]*\[ \]' "$tasks" 2>/dev/null; then
    echo "  FAIL: unchecked task(s) remain in $tasks at finalization — the milestone is not done (AC-4):" >&2
    grep -nE '^[[:space:]]*-[[:space:]]*\[ \]' "$tasks" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi

  # (2) every AC-N in spec.md ASSERTED by a test: the AC token must sit within a few lines of a test/
  # assertion construct in a test-path file — a bare comment mention no longer counts (B6).
  doc="$(_doc)"; acpat="AC-[0-9]+"; local testpat="$DEFAULT_AC_TEST_PAT"
  if [ -n "$doc" ]; then
    local p; p="$(_val AcPattern "$doc")"; [ -n "$p" ] && acpat="$p"
    local tp; tp="$(_val AcTestPattern "$doc")"; [ -n "$tp" ] && testpat="$tp"
  fi
  acs="$(grep -oE "$acpat" "$spec" 2>/dev/null | sort -u)"
  if [ -z "$acs" ]; then
    # #111: NO recognized AC token found. Distinguish "genuinely no ACs" (graceful pass) from "declares
    # ACs the gate can't parse" (a coverage hole → FAIL-CLOSED). A spec that states its acceptance
    # criteria only as unmarked/checkbox bullets has nothing token-shaped to map, so passing here would be
    # a vacuous green-by-skip on the AC→test guarantee — the same class the fidelity gates refuse.
    if _spec_has_untokenized_acs "$spec"; then
      echo "  FAIL-CLOSED: $spec DECLARES acceptance criteria but none are in the recognized '$acpat' form (they are unmarked/checkbox bullets), so the AC→test half can map none of them to a test — passing would be a vacuous green-by-skip on the coverage guarantee. Mark each acceptance criterion as 'AC-N' (or set AcPattern: to the token form this spec uses) so AC→test coverage is enforceable (#111)." >&2
      viol=$((viol + 1))
    else
      echo "check-completeness --final: no '$acpat' tokens in $spec and no acceptance criteria declared in another form — genuinely nothing to map (graceful skip) (#111)."
    fi
  else
    # #94: scope the AC→test search to THIS spec's own tests, not a repo-wide grep (see _spec_test_files).
    files="$(_spec_test_files "$spec" .)"
    # #100: a governed, expiring deferred_live_waiver in the run marker sanctions deferring a live/P5-gated
    # AC to a live run — its DeferredLiveAC marker then counts as the AC's reference. Same governed shape as
    # the other waivers (ack+by+reason+expires, validated by governed_waiver_ok); without it a deferral is a
    # bare comment and does not count. Procedure: references/deferred-live-ac.md.
    local deferred_live_ok=0
    if governed_waiver_ok \
         "$(field_in_obj "$mk" deferred_live_waiver ack)" \
         "$(field_in_obj "$mk" deferred_live_waiver by)" \
         "$(field_in_obj "$mk" deferred_live_waiver reason)" \
         "$(field_in_obj "$mk" deferred_live_waiver expires)"; then
      deferred_live_ok=1
    fi
    for ac in $acs; do
      # WS-3 (harness-robustness): feed the file list via herestring, NOT `printf … | _ac_in_tests`.
      # `_ac_in_tests` returns 0 on the FIRST matching file without draining stdin; under `set -o pipefail`
      # the producer `printf` then SIGPIPEs (141) on a large $files (many test files), so the pipeline is
      # non-zero → the `if` reads it as "not asserted" → an AC that IS asserted is falsely FAILed. A
      # herestring has no live producer to signal, so early-return is safe. (Root-caused by arch-review.)
      if _ac_in_tests "$ac" "$testpat" 3 <<< "$files"; then continue; fi
      # A governed deferred-live AC: its deferral marker in a spec-associated test IS its reference (#100).
      if [ "$deferred_live_ok" -eq 1 ] && _ac_deferred_live "$ac" <<< "$files"; then
        echo "check-completeness --final: $ac is DEFERRED-LIVE — counted as referenced by its governed, expiring deferral (deferred_live_waiver), not by a running assertion (#100)."
        continue
      fi
      echo "  FAIL: $ac is in $spec but NOT asserted by any test associated with this spec — it appears in no spec-scoped test-path file within 3 lines of a test/assertion construct, and no governed deferred-live deferral covers it (a bare or cross-spec mention does not count) (AC-4, B6, #94, #100)." >&2
      viol=$((viol + 1))
    done
  fi

  [ "$viol" -eq 0 ] || return 1
  echo "check-completeness --final: no unchecked tasks in $tasks and every AC referenced by a test-path file — milestone fidelity verified."
  return 0
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0; T="$(mktemp -d)"; mkdir -p "$T/.runs/r" "$T/specs/demo" "$T/tests"
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md"}\n' > "$T/.runs/r/RUN"
  _batch() { printf '%s\n' "$1" > "$T/.runs/r/batches.jsonl"; }
  _runpb() { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-completeness.sh" . >/dev/null 2>&1 ); echo $?; }
  _runf()  { ( cd "$T" && TEAM_BOOTSTRAP_RUN=r "$here/check-completeness.sh" --final . >/dev/null 2>&1 ); echo $?; }
  _chk() { if [ "$2" = "$3" ]; then echo "  PASS (exit $2) $1"; else echo "  FAIL (exit $2 want $3) $1" >&2; fail=$((fail + 1)); fi; }

  # AC-3 — per-batch: all declared task_ids [x] → pass
  _batch '{"id":"B1","kind":"code","task_ids":["T001","T002"],"status":"announced"}'
  printf '# Tasks\n\n- [x] **T001** done\n- [x] **T002** done\n' > "$T/specs/demo/tasks.md"
  _chk "AC-3 per-batch all [x] → pass" "$(_runpb)" 0
  # AC-3 — one task unchecked → fail
  printf '# Tasks\n\n- [x] **T001** done\n- [ ] **T002** undone\n' > "$T/specs/demo/tasks.md"
  _chk "AC-3 per-batch one [ ] → fail" "$(_runpb)" 1
  # AC-3 — a declared task_id absent from tasks.md → fail
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  _chk "AC-3 per-batch declared task_id absent → fail" "$(_runpb)" 1
  # id-boundary: T001 must not be satisfied by a checked T0010
  _batch '{"id":"B1","kind":"code","task_ids":["T001"],"status":"announced"}'
  printf '# Tasks\n\n- [x] **T0010** other\n- [ ] **T001** undone\n' > "$T/specs/demo/tasks.md"
  _chk "AC-3 boundary: [x] T0010 does not satisfy T001 → fail" "$(_runpb)" 1

  # AC-4 — --final: complete tasks + every AC ASSERTED near a test construct → pass
  printf '# Spec\n\n- AC-1 foo\n- AC-2 bar\n' > "$T/specs/demo/spec.md"
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  printf '# AC-1\nassert ac1\n# AC-2\nassert ac2\n' > "$T/tests/demo_x.test.sh"
  _chk "AC-4 --final every AC near a test construct → pass" "$(_runf)" 0
  # B6 — ACs mentioned ONLY in a bare comment (no test construct nearby) → fail (reference-only no longer counts)
  printf '# refs AC-1 AC-2 (bare comment, no test construct nearby)\n' > "$T/tests/demo_x.test.sh"
  _chk "B6 --final ACs only in a bare comment → fail" "$(_runf)" 1
  # AC-4 — an AC asserted by NO test → fail
  printf '# AC-1\nassert ac1\n' > "$T/tests/demo_x.test.sh"
  _chk "AC-4 --final AC-2 not asserted → fail" "$(_runf)" 1
  # AC-4 — a remaining [ ] in tasks.md → fail
  printf '# AC-1\nassert ac1\n# AC-2\nassert ac2\n' > "$T/tests/demo_x.test.sh"
  printf '# Tasks\n\n- [x] **T001** done\n- [ ] **T002** undone\n' > "$T/specs/demo/tasks.md"
  _chk "AC-4 --final unchecked task remains → fail" "$(_runf)" 1
  # AcPattern override: ISSUE-\d tokens, asserted near a construct
  printf '# Spec\n\n- ISSUE-9 foo\n' > "$T/specs/demo/spec.md"
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  printf '# AGENTS\n\n- AcPattern: `ISSUE-[0-9]+`\n' > "$T/AGENTS.md"
  printf '# ISSUE-9\nassert i9\n' > "$T/tests/demo_x.test.sh"
  _chk "AC-4 --final AcPattern override (ISSUE-9 asserted) → pass" "$(_runf)" 0
  rm -f "$T/AGENTS.md"

  # dir-feature (regression: exec-role-integrity green-by-skip) — the marker records `feature` as the
  # DIRECTORY (specs/demo), not spec.md. It must normalize to specs/demo/spec.md and ENFORCE, never skip.
  rm -f "$T/AGENTS.md"
  printf '# Spec\n\n- AC-1 foo\n' > "$T/specs/demo/spec.md"
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo"}\n' > "$T/.runs/r/RUN"
  _batch '{"id":"B1","kind":"code","task_ids":["T001","T002"],"status":"announced"}'
  printf '# Tasks\n\n- [x] **T001** done\n- [x] **T002** done\n' > "$T/specs/demo/tasks.md"
  _chk "dir-feature per-batch resolves + enforces (all [x]) → pass" "$(_runpb)" 0
  printf '# Tasks\n\n- [x] **T001** done\n- [ ] **T002** undone\n' > "$T/specs/demo/tasks.md"
  _chk "dir-feature per-batch resolves + enforces (one [ ]) → fail" "$(_runpb)" 1
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  printf '# AC-1\nassert ac1\n' > "$T/tests/demo_x.test.sh"
  _chk "dir-feature --final resolves spec.md + enforces → pass" "$(_runf)" 0
  # feature WITH a trailing slash also normalizes
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/"}\n' > "$T/.runs/r/RUN"
  _batch '{"id":"B1","kind":"code","task_ids":["T001"],"status":"announced"}'
  _chk "dir-feature (trailing slash) per-batch → pass" "$(_runpb)" 0

  # declared-but-unresolvable — an armed run that DECLARES a feature whose spec/tasks do NOT exist must
  # FAIL-LOUD (green-by-skip guard), not skip. (feature=unknown / empty is the genuine no-spec case → skip.)
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/ghost"}\n' > "$T/.runs/r/RUN"
  _chk "declared feature, no tasks.md → per-batch FAIL (not skip)" "$(_runpb)" 1
  _chk "declared feature, no spec.md → --final FAIL (not skip)" "$(_runf)" 1
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"unknown"}\n' > "$T/.runs/r/RUN"
  _chk "feature=unknown (direct/non-spec run) per-batch → skip" "$(_runpb)" 0
  _chk "feature=unknown (direct/non-spec run) --final → skip" "$(_runf)" 0

  # #94 — the AC→test search is SCOPED to the spec under delivery, not a repo-wide grep. A same-numbered
  # AC token in a FOREIGN spec's test must NOT satisfy this spec's AC (shared AC-N namespace → collisions).
  rm -f "$T/AGENTS.md"
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md"}\n' > "$T/.runs/r/RUN"
  printf '# Spec\n\n- AC-1 foo\n' > "$T/specs/demo/spec.md"
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  rm -f "$T/tests/demo_x.test.sh"
  # only a foreign (non-demo) test asserts AC-1 → not associated with `demo` → FAIL
  printf '# foreign spec other\n# AC-1\nassert other_behaviour\n' > "$T/tests/other_core.test.sh"
  _chk "#94 AC asserted only by a FOREIGN spec's test → --final FAIL (cross-spec collision closed)" "$(_runf)" 1
  # a test associated with `demo` (slug in path) asserts AC-1 → PASS
  printf '# AC-1\nassert demo_behaviour\n' > "$T/tests/demo_core.test.sh"
  _chk "#94 AC asserted by a test associated with the spec (slug in path) → --final PASS" "$(_runf)" 0
  rm -f "$T/tests/other_core.test.sh" "$T/tests/demo_core.test.sh"

  # #100 — a governed, expiring deferred_live_waiver lets a live/P5-gated AC be DEFERRED: its
  # DeferredLiveAC marker in an associated test counts as the AC's reference (no running assertion needed).
  printf '# Spec\n\n- AC-1 live only\n' > "$T/specs/demo/spec.md"
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  # deferred test: DeferredLiveAC marker + skip, associated with `demo` by path, NO assertion construct.
  printf '# DeferredLiveAC: AC-1 — live/P5-gated, deferred to a live run\npytest.skip("AC-1 deferred")\n' > "$T/tests/demo_live_test.py"
  DLW='"deferred_live_waiver":{"ack":true,"by":"tester","reason":"AC-1 live/P5-gated","expires":"2999-01-01"}'
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md",%s}\n' "$DLW" > "$T/.runs/r/RUN"
  _chk "#100 governed deferred_live_waiver → --final counts the deferred AC as referenced" "$(_runf)" 0
  # without the governed waiver, a deferral with no assertion construct is NOT counted → FAIL
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md"}\n' > "$T/.runs/r/RUN"
  _chk "#100 no governed waiver → deferred AC not counted (no assertion) → --final FAIL" "$(_runf)" 1
  rm -f "$T/tests/demo_live_test.py"

  # #111 — a spec that DECLARES acceptance criteria but NOT as recognized tokens must not pass vacuously.
  rm -f "$T/tests"/*.test.sh "$T/tests"/*.py 2>/dev/null
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/demo/spec.md"}\n' > "$T/.runs/r/RUN"
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/demo/tasks.md"
  printf '# Spec\n\n## Acceptance Criteria\n\n- [ ] renders on load\n- [ ] degrades on error\n' > "$T/specs/demo/spec.md"
  _chk "#111 ACs as checkbox bullets (no token) → --final FAIL-CLOSED (no vacuous pass)" "$(_runf)" 1
  printf '# Spec\n\n## Acceptance\n\n- the export is idempotent\n' > "$T/specs/demo/spec.md"
  _chk "#111 ACs as plain bullets under an Acceptance heading (no token) → --final FAIL-CLOSED" "$(_runf)" 1
  printf '# Spec\n\nRollout notes only. There are no acceptance criteria here.\n' > "$T/specs/demo/spec.md"
  _chk "#111 genuinely no ACs (prose only) → --final PASS (graceful)" "$(_runf)" 0

  # #94 (widen) — a test named by the spec NUMBER, or carrying a Spec:/SpecId: tag, associates with the
  # spec without embedding the full multi-word slug; the number stays per-spec scoped (108 ≠ 107 ≠ 1080).
  rm -f "$T/tests"/*.test.sh "$T/tests"/*.py 2>/dev/null
  mkdir -p "$T/specs/108-cited-table-cell"
  printf '{"run":"r","intends_code":true,"source":"harness","feature":"specs/108-cited-table-cell/spec.md"}\n' > "$T/.runs/r/RUN"
  printf '# Spec 108\n\n- AC-0 the degrade path\n' > "$T/specs/108-cited-table-cell/spec.md"
  printf '# Tasks\n\n- [x] **T001** done\n' > "$T/specs/108-cited-table-cell/tasks.md"
  printf '# 108 suite\n# AC-0\nassert degrade\n' > "$T/tests/cell_108.py"
  _chk "#94 test named by the spec number (_108.py, no full slug) → --final PASS" "$(_runf)" 0
  rm -f "$T/tests/cell_108.py"
  printf '# 107 suite\n# AC-0\nassert other\n' > "$T/tests/cell_107.py"
  _chk "#94 foreign _107.py does not satisfy spec-108's AC-0 → --final FAIL (per-spec number scope)" "$(_runf)" 1
  rm -f "$T/tests/cell_107.py"
  printf '# unrelated 1080 2108\n# AC-0\nassert x\n' > "$T/tests/thing_1080.py"
  _chk "#94 partial-number filenames (1080/2108) do not associate → --final FAIL" "$(_runf)" 1
  rm -f "$T/tests/thing_1080.py"
  printf '# Spec: 108\n# AC-0\nassert via_tag\n' > "$T/tests/core.py"
  _chk "#94 declared 'Spec: 108' tag associates → --final PASS" "$(_runf)" 0
  rm -f "$T/tests/core.py" "$T/tests"/*.py 2>/dev/null
  rm -rf "$T/specs/108-cited-table-cell"

  # AC-6 — no active marker → skip (both modes)
  rm -f "$T/.runs/r/RUN"
  _chk "AC-6 per-batch no marker → skip" "$(_runpb)" 0
  _chk "AC-6 --final no marker → skip" "$(_runf)" 0
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "check-completeness --self-test: OK"; exit 0; fi
  echo "check-completeness --self-test: $fail case(s) FAILED" >&2; exit 1
fi

# --- dispatch -----------------------------------------------------------------
mode="per-batch"
if [ "${1:-}" = "--final" ]; then mode="final"; shift; fi
root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-completeness: bad dir '$root'" >&2; exit 64; }
if [ "$mode" = "final" ]; then
  if _final; then exit 0; else exit 1; fi
else
  if _per_batch; then exit 0; else exit 1; fi
fi
