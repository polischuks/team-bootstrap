#!/usr/bin/env bash
# marker.sh — the single sanctioned CLI for editing the machine-owned .runs/<run>/RUN marker (issue #72).
#
# Recording an ack or a waiver used to mean hand-editing the run marker's JSON by hand, against a shape
# contract nothing stated: a trailing comma, a wrong field name, or a non-date `expires` produced a
# marker that fails silently or clears nothing at the gate. This command is the ONE owner of that
# contract. It writes the correct shape through delivery-lib's atomic marker writers, refuses any input
# the reading gate would reject, and then RE-VALIDATES the marker it wrote — the operator never edits the
# machine JSON, and a malformed edit is impossible to record.
#
# Every sub-edit targets the SINGLE active run (resolved from TEAM_BOOTSTRAP_RUN / the lone .runs/*/RUN),
# and must be run from the project root (the marker path is `.runs/<run>/RUN`, resolved relative to CWD).
#
# Commands:
#   marker.sh set precond.ack <true|false>
#       Acknowledge (or un-acknowledge) the Phase-A deliverability advisory (precond.exit==2), so
#       check-delivery lets Phase B proceed. Needs an existing precond verdict in the marker.
#
#   marker.sh set pipeline <full|mvp|single-thread>
#       Record the batch pipeline mode the review gates read (check-review-ack dispatch corroboration).
#       GUARDED: refuses `auto` or any string outside the vocabulary — an unguarded pipeline write is a
#       provenance-forgery surface (issue #98).
#
#   marker.sh review-ack --batch <id> --reviewer <who> --context <clean|dirty> --verdict <go|blocked> --commit <sha> [--replace]
#       Append a validated review_acks entry — the independent, clean-context adversarial review
#       check-review-ack reads. `reviewer` must differ from the marker `builder` (default "orchestrator";
#       no self-review, OQ-4). Refuses a missing/malformed field, naming it (issue #98). With --replace,
#       any prior review_acks entry for the same batch is removed first, so a re-anchor after a commit
#       rebuild REPLACES the stale entry instead of appending a duplicate (issue #121).
#
#   marker.sh red-supersede <batch>
#       Drop a batch's stale red/lock record(s) from .runs/<run>/tdd.jsonl after a legitimate commit
#       rebuild (split/reorder), so `check-tdd.sh --record-red --batch <id>` can re-anchor cleanly — a
#       validated op, not hand-deletion of the append-only ledger (issue #121).
#
#   marker.sh seam-ack --seam <name> --commit <sha> --note "<file:line + why>"
#       Append a validated seam_acks entry — the read-in-the-shipped-code ack check-seam-ack reads. The
#       emitted shape is seam THEN commit (adjacency is load-bearing for the gate's parse). Refuses a
#       missing/malformed field, naming it (issue #98).
#
#   marker.sh restore
#       HARNESS recovery of a lost run marker (issue #117). Restores `.runs/<run>/RUN` atomically from its
#       sibling `RUN.bak` (written by the marker writer on every machine update) when an external `.runs`
#       cleanup deleted RUN mid-session. Recovery is a harness op — the orchestrator never hand-authors the
#       machine fields. Refuses if RUN is already present or no RUN.bak exists (never fabricates a marker).
#
#   marker.sh waive preflight       <by> <reason> <expires>
#       Governed Phase-0 setup-readiness waiver — clears a failing check-preflight (preflight.exit!=0).
#   marker.sh waive gate-integrity  <by> <reason> <expires>
#       Governed gate-integrity waiver — clears pre-existing green-by-skip / can't-fail findings.
#   marker.sh waive role-verdict    <by> <reason> <expires>
#       Governed role-verdict waiver — clears a batch whose reviewer verdict could not be captured.
#   marker.sh waive enforcement     <by> <reason> <expires> <host_structural|deferred>
#       Governed test-quality enforcement waiver — clears a red-first/coverage/mutation gap.
#
#   <expires> is YYYY-MM-DD and must be in the future (a bare, undated ack is not a governed waiver).
#   The finding a waiver clears is still PRINTED by its gate — a waiver dates and attributes the escape,
#   it does not hide it. Standard for a good <reason>: references/enforcement.md.
#
# Exit: 0 recorded (and re-validated) · 1 refused by the writer (bad/expired waiver, no active run,
#       nothing to ack) · 64 usage error (unknown command/target, wrong arity, non-bool value).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

prog="$(basename "$0")"

usage() {
  sed -n '2,61p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# _revalidate KIND KEY → confirm the just-written marker still parses AND the field the gate reads is
# present in the accepted shape. This is belt-and-suspenders over the writers' own pre-write validation:
# the CLI is the contract owner, so it proves the contract held rather than trusting it. A failure here
# is a writer bug, reported loudly (never a silent success).
_revalidate() {
  local kind="$1" key="$2" marker mk
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || { echo "$prog: recorded, but the run marker could not be re-read to validate." >&2; return 1; }
  mk="$(cat "$marker" 2>/dev/null || true)"
  _marker_json_ok "$mk" || { echo "$prog: BUG — the write produced a marker that does not parse; refusing to claim success." >&2; return 1; }
  case "$kind" in
    precond-ack)
      [ -n "$(field_in_obj "$mk" precond ack)" ] || { echo "$prog: BUG — precond.ack not readable after write." >&2; return 1; } ;;
    obj-waiver)   # governed waiver nested in "$key":{ack,by,reason,expires}
      governed_waiver_ok "$(field_in_obj "$mk" "$key" ack)" "$(field_in_obj "$mk" "$key" by)" \
                         "$(field_in_obj "$mk" "$key" reason)" "$(field_in_obj "$mk" "$key" expires)" \
        || { echo "$prog: BUG — $key does not read back as a valid governed waiver." >&2; return 1; } ;;
    enforcement)
      [ "$(field_bool "$mk" enforcement_ack)" = "true" ] \
        || { echo "$prog: BUG — enforcement_ack not readable after write." >&2; return 1; } ;;
    pipeline)     # KEY is the expected value
      [ "$(field_str "$mk" pipeline)" = "$key" ] \
        || { echo "$prog: BUG — pipeline not readable as '$key' after write." >&2; return 1; } ;;
    list)         # KEY is the appended-to array's top-level name (review_acks / seam_acks)
      case "$mk" in *"\"$key\":["*) : ;; *) echo "$prog: BUG — $key array not present after write." >&2; return 1 ;; esac ;;
  esac
  return 0
}

# _has_bad_punct VALUE → rc 0 if VALUE carries JSON/parse-hostile punctuation ( [ ] { } " \ ). These land
# inside JSON string values this file has no encoder for, and the jq-free array parsers (marker_list /
# _array_objects / _ack_commits) key on the FIRST ']' — a ']' in a value would truncate the array. So the
# writers REJECT rather than mangle (mirrors record_governed_waiver's `case … *[\\\"]*`), the safe direction.
_has_bad_punct() { printf '%s' "$1" | grep -q '[][{}"\]'; }

# _append_marker_obj KEY OBJ → append flat JSON object OBJ to the active run marker's top-level array
# "KEY" (creating it when absent), atomically. Reuses delivery-lib's marker_list (read) + record_marker_list
# (write, which strips+re-appends the key and re-validates the {…} wrapper), so the array shape stays owned
# by the lib. Callers MUST confirm an active run first — record_marker_list is a silent no-op with none.
_append_marker_obj() {
  local key="$1" obj="$2" cur body newarr
  cur="$(marker_list "$key")"
  if [ -z "$cur" ] || [ "$cur" = "[]" ]; then
    newarr="[$obj]"
  else
    body="${cur#\[}"; body="${body%\]}"
    newarr="[$body,$obj]"
  fi
  record_marker_list "$key" "$newarr"
}

# _replace_review_acks_batch BATCH → rewrite the active run marker's review_acks array with every object
# whose "batch" == BATCH removed (issue #121). review_acks entries are FLAT objects (no nested arrays), so
# splitting on `},{` is exact. Absent/empty array ⇒ no-op success. Used by `review-ack --replace` so a
# legitimate re-anchor after a commit rebuild REPLACES the stale entry instead of appending a duplicate —
# no hand-removal of the stale review_acks from RUN.
_replace_review_acks_batch() {
  local batch="$1" cur body obj kept="" nl rep split
  cur="$(marker_list review_acks)"
  [ -n "$cur" ] && [ "$cur" != "[]" ] || return 0
  body="${cur#\[}"; body="${body%\]}"
  [ -n "$body" ] || return 0
  # Split the flat array of objects on the literal `},{` in pure bash — BSD sed does NOT interpret `\n`
  # in a replacement (it would emit `}n{` and collapse every object onto one line), and the codebase's
  # marker rewrites are deliberately sed-free. The replacement carries no backslash, so it also avoids
  # the bash-5.2 backslash-in-replacement pitfall _marker_strip_flat_key documents.
  nl=$'\n'; rep="}${nl}{"; split="${body//'},{'/$rep}"
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    case "$obj" in \{*) : ;; *) obj="{$obj" ;; esac
    case "$obj" in *\}) : ;; *) obj="$obj}" ;; esac
    [ "$(field_str "$obj" batch)" = "$batch" ] && continue   # drop the stale entry for this batch
    if [ -z "$kept" ]; then kept="$obj"; else kept="$kept,$obj"; fi
  done <<EOF
$split
EOF
  record_marker_list review_acks "[$kept]"
}

# _supersede_red_records BATCH → drop every red/lock record bearing "batch":BATCH from the active run's
# .runs/<run>/tdd.jsonl, atomically (issue #121). Echoes the count removed. rc 1 if there is no active run
# or no tdd.jsonl. A validated replacement for hand-deleting a stale red line before re-recording.
_supersede_red_records() {
  local batch="$1" marker tdd tmp line b n=0
  marker="$(resolve_marker 2>/dev/null || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 1
  tdd="$(dirname "$marker")/tdd.jsonl"
  [ -f "$tdd" ] || return 1
  tmp="$tdd.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    b="$(field_str "$line" batch)"
    if [ "$b" = "$batch" ]; then n=$((n + 1)); continue; fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$tdd"
  mv "$tmp" "$tdd" || { rm -f "$tmp"; return 1; }
  printf '%s' "$n"
  return 0
}

# _set_pipeline VALUE → set the top-level "pipeline":"VALUE" scalar in the active run marker (insert or
# replace), validate the candidate parses, write atomically. rc 1 on no/ambiguous run or a non-parsing
# candidate. The vocabulary guard lives in the caller (set pipeline) so the refusal message can be specific.
_set_pipeline() {
  local val="$1" marker mk newmk
  marker="$(resolve_marker)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 1
  mk="$(cat "$marker" 2>/dev/null || true)"
  [ -n "$mk" ] || return 1
  case "$mk" in \{*\}) : ;; *) return 1 ;; esac
  newmk="$(_json_scalar_set "$mk" pipeline "\"$val\"")" || return 1
  _marker_json_ok "$newmk" || return 1
  _marker_write "$marker" "$newmk"
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift

case "$cmd" in
  set)
    key="${1:-}"; val="${2:-}"
    if [ "$#" -ne 2 ]; then echo "usage: $prog set <precond.ack <true|false> | pipeline <full|mvp|single-thread>>" >&2; exit 64; fi
    case "$key" in
      precond.ack)
        case "$val" in true|false) : ;; *) echo "$prog: precond.ack takes true or false, not '$val'." >&2; exit 64 ;; esac
        record_precond_ack "$val" || { echo "$prog: REFUSED to set precond.ack — no unambiguous active run, or no precond advisory recorded in the marker to acknowledge." >&2; exit 1; }
        _revalidate precond-ack precond || exit 1
        echo "$prog: precond.ack=$val recorded and validated." ;;
      pipeline)
        case "$val" in full|mvp|single-thread) : ;; *) echo "$prog: pipeline takes full|mvp|single-thread, not '$val' (auto/arbitrary refused — an unguarded pipeline is a forgery surface, #98)." >&2; exit 64 ;; esac
        _set_pipeline "$val" || { echo "$prog: REFUSED to set pipeline — no unambiguous active run, or the write did not validate." >&2; exit 1; }
        _revalidate pipeline "$val" || exit 1
        echo "$prog: pipeline=$val recorded and validated." ;;
      *) echo "$prog: unknown field '$key' (settable: precond.ack, pipeline; waivers use '$prog waive …')." >&2; exit 64 ;;
    esac
    ;;
  waive)
    target="${1:-}"; [ "$#" -gt 0 ] && shift
    case "$target" in
      preflight|gate-integrity|role-verdict)
        if [ "$#" -ne 3 ]; then echo "usage: $prog waive $target <by> <reason> <expires:YYYY-MM-DD>" >&2; exit 64; fi
        by="$1"; reason="$2"; expires="$3"
        case "$target" in
          preflight)      record_preflight_waiver "$by" "$reason" "$expires" && _revalidate obj-waiver preflight ;;
          gate-integrity) record_governed_waiver gate_integrity_waiver "$by" "$reason" "$expires" && _revalidate obj-waiver gate_integrity_waiver ;;
          role-verdict)   record_governed_waiver role_verdict_waiver "$by" "$reason" "$expires" && _revalidate obj-waiver role_verdict_waiver ;;
        esac || { echo "$prog: REFUSED to record the $target waiver — needs a non-empty by and reason, a future YYYY-MM-DD expires, and an unambiguous active run." >&2; exit 1; }
        echo "$prog: $target waiver recorded and validated (by=$by, expires=$expires)." ;;
      enforcement)
        if [ "$#" -ne 4 ]; then echo "usage: $prog waive enforcement <by> <reason> <expires:YYYY-MM-DD> <host_structural|deferred>" >&2; exit 64; fi
        by="$1"; reason="$2"; expires="$3"; category="$4"
        record_enforcement_waiver "$by" "$reason" "$expires" "$category" || { echo "$prog: REFUSED to record the enforcement waiver — needs a non-empty by and reason, a future YYYY-MM-DD expires, a category of host_structural|deferred, and an unambiguous active run." >&2; exit 1; }
        _revalidate enforcement enforcement_ack || exit 1
        echo "$prog: enforcement waiver recorded and validated (by=$by, expires=$expires, category=$category)." ;;
      ""|-h|--help) usage; exit 64 ;;
      *) echo "$prog: unknown waive target '$target' (preflight|gate-integrity|role-verdict|enforcement)." >&2; exit 64 ;;
    esac
    ;;
  review-ack)
    # Append a validated review_acks entry check-review-ack reads. Flag-parsed so a missing field is named.
    # --replace (issue #121): first REMOVE any existing review_acks entry for the same batch, so a legit
    # re-anchor after a commit rebuild replaces the stale entry instead of appending a duplicate.
    batch=""; reviewer=""; context=""; verdict=""; commit=""; replace=0
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--replace" ]; then replace=1; shift; continue; fi
      case "$1" in
        --batch)    batch="${2:-}" ;;
        --reviewer) reviewer="${2:-}" ;;
        --context)  context="${2:-}" ;;
        --verdict)  verdict="${2:-}" ;;
        --commit)   commit="${2:-}" ;;
        *) echo "$prog: review-ack: unknown option '$1' (need --batch --reviewer --context --verdict --commit [--replace])." >&2; exit 64 ;;
      esac
      shift; [ "$#" -gt 0 ] && shift    # consume the flag, then its value if present (no shift-2 underflow loop)
    done
    missing=""
    [ -n "$batch" ]    || missing="$missing batch"
    [ -n "$reviewer" ] || missing="$missing reviewer"
    [ -n "$context" ]  || missing="$missing context"
    [ -n "$verdict" ]  || missing="$missing verdict"
    [ -n "$commit" ]   || missing="$missing commit"
    [ -z "$missing" ] || { echo "$prog: review-ack: missing required field(s):$missing (need --batch --reviewer --context --verdict --commit)." >&2; exit 64; }
    case "$context" in clean|dirty) : ;; *) echo "$prog: review-ack: --context must be clean|dirty, not '$context'." >&2; exit 64 ;; esac
    case "$verdict" in go|blocked) : ;; *) echo "$prog: review-ack: --verdict must be go|blocked, not '$verdict'." >&2; exit 64 ;; esac
    for _v in "$batch" "$reviewer" "$context" "$verdict" "$commit"; do
      _has_bad_punct "$_v" && { echo "$prog: review-ack: value '$_v' carries JSON/parse-hostile punctuation ( [ ] { } \" \\ ) — refused (keep ids/slugs/shas clean)." >&2; exit 64; }
    done
    marker="$(resolve_marker 2>/dev/null || true)"
    [ -n "$marker" ] && [ -f "$marker" ] || { echo "$prog: review-ack: no unambiguous active run to record into." >&2; exit 1; }
    mk="$(cat "$marker" 2>/dev/null || true)"
    builder="$(field_str "$mk" builder)"; [ -n "$builder" ] || builder="orchestrator"
    [ "$reviewer" = "$builder" ] && { echo "$prog: review-ack: reviewer '$reviewer' == builder '$builder' — a self-review cannot close a batch (OQ-4); refused." >&2; exit 1; }
    # --replace (#121): drop any stale review_acks entry for this batch BEFORE appending, so a re-anchor
    # after a commit rebuild is a validated op, not a hand-removal of the old entry from RUN.
    if [ "$replace" -eq 1 ]; then
      _replace_review_acks_batch "$batch" || { echo "$prog: review-ack: REFUSED — could not strip the prior entry for '$batch'; left unchanged." >&2; exit 1; }
    fi
    # Shape check-review-ack reads: flat {batch, reviewer, context, commit, verdict}.
    _append_marker_obj review_acks "{\"batch\":\"$batch\",\"reviewer\":\"$reviewer\",\"context\":\"$context\",\"commit\":\"$commit\",\"verdict\":\"$verdict\"}" \
      || { echo "$prog: review-ack: REFUSED — the marker write did not validate; left unchanged." >&2; exit 1; }
    _revalidate list review_acks || exit 1
    echo "$prog: review-ack recorded (batch=$batch, reviewer=$reviewer, verdict=$verdict$([ "$replace" -eq 1 ] && printf ', replaced prior')) and validated." ;;
  red-supersede)
    # Supersede (drop) a batch's stale red/lock record(s) in .runs/<run>/tdd.jsonl after a legitimate
    # commit rebuild, so the operator can re-run `check-tdd.sh --record-red --batch <id>` to re-anchor —
    # a validated harness op, not hand-deletion of the append-only ledger (issue #121).
    sbatch="${1:-}"
    [ -n "$sbatch" ] || { echo "usage: $prog red-supersede <batch>" >&2; exit 64; }
    _has_bad_punct "$sbatch" && { echo "$prog: red-supersede: batch '$sbatch' carries JSON/parse-hostile punctuation — refused." >&2; exit 64; }
    n="$(_supersede_red_records "$sbatch")" || { echo "$prog: red-supersede: no unambiguous active run, or no .runs/<run>/tdd.jsonl to supersede in." >&2; exit 1; }
    if [ "${n:-0}" -eq 0 ]; then
      echo "$prog: red-supersede: no red/lock record for batch '$sbatch' found — nothing to supersede." >&2; exit 1
    fi
    echo "$prog: red-supersede removed $n red/lock record(s) for batch '$sbatch' — commit the failing test, then re-run bin/check-tdd.sh --record-red --batch $sbatch to re-anchor." ;;
  seam-ack)
    # Append a validated seam_acks entry check-seam-ack reads. seam THEN commit is load-bearing.
    seam=""; commit=""; note=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --seam)   seam="${2:-}" ;;
        --commit) commit="${2:-}" ;;
        --note)   note="${2:-}" ;;
        *) echo "$prog: seam-ack: unknown option '$1' (need --seam --commit --note)." >&2; exit 64 ;;
      esac
      shift; [ "$#" -gt 0 ] && shift
    done
    missing=""
    [ -n "$seam" ]   || missing="$missing seam"
    [ -n "$commit" ] || missing="$missing commit"
    [ -n "$note" ]   || missing="$missing note"
    [ -z "$missing" ] || { echo "$prog: seam-ack: missing required field(s):$missing (need --seam --commit --note)." >&2; exit 64; }
    for _v in "$seam" "$commit" "$note"; do
      _has_bad_punct "$_v" && { echo "$prog: seam-ack: value '$_v' carries JSON/parse-hostile punctuation ( [ ] { } \" \\ ) — refused (keep the note bracket/brace-free)." >&2; exit 64; }
    done
    marker="$(resolve_marker 2>/dev/null || true)"
    [ -n "$marker" ] && [ -f "$marker" ] || { echo "$prog: seam-ack: no unambiguous active run to record into." >&2; exit 1; }
    _append_marker_obj seam_acks "{\"seam\":\"$seam\",\"commit\":\"$commit\",\"note\":\"$note\"}" \
      || { echo "$prog: seam-ack: REFUSED — the marker write did not validate; left unchanged." >&2; exit 1; }
    _revalidate list seam_acks || exit 1
    echo "$prog: seam-ack recorded (seam=$seam, commit=$commit) and validated." ;;
  restore)
    # issue #117 — HARNESS recovery of a lost run marker. An external/parallel `.runs` cleanup can delete
    # `.runs/<run>/RUN` mid-session; the gates then fail-closed on the missing machine fact, and the old
    # sanctioned recovery was "re-author the marker yourself" — the orchestrator hand-writing a
    # harness-owned fact, the exact authorship the design exists to prevent. This restores RUN atomically
    # from the sibling RUN.bak (written by _marker_write on every machine update), so recovery is a
    # HARNESS op, not a model-authored marker. Refuses (rc 1) when RUN is already present or no backup
    # exists — it never FABRICATES a marker, so a genuinely absent run stays absent and gates stay closed.
    if [ "$#" -ne 0 ]; then echo "usage: $prog restore   (recovers a lost .runs/<run>/RUN from its RUN.bak)" >&2; exit 64; fi
    if marker_restore .; then
      m="$(resolve_marker 2>/dev/null || true)"
      echo "$prog: run marker restored from RUN.bak${m:+ ($m)}."
      exit 0
    else
      echo "$prog: nothing to restore — the run marker is present, or no RUN.bak backup exists to restore from (a harness op cannot fabricate a marker; if truly lost, re-arm the run via /deliver)." >&2
      exit 1
    fi ;;
  ""|-h|--help|help) usage; [ "$cmd" = "" ] && exit 64 || exit 0 ;;
  *) echo "$prog: unknown command '$cmd' (set|waive|review-ack|seam-ack|red-supersede|restore)." >&2; exit 64 ;;
esac
