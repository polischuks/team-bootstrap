#!/usr/bin/env bash
# tier-token-parse.test.sh — the tier is the FIRST ARGUMENT TOKEN, not any occurrence of a tier word.
#
# commands/deliver.md has always specified "First whitespace-delimited token = PIPELINE". The hook did
# not implement that: it grepped the whole payload for `single-thread`/`full`/`mvp`, so any prompt
# CONTAINING one of those words selected that pipeline. v2.33.0 patched one symptom (a specs/ slug
# containing a tier word) by excising the path before the grep; the cause — position is never
# considered — survived, and prose like "give the user full control" still bought the 20-role pipeline.
#
# This suite pins the contract itself: only the token immediately after the command counts.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
FAILF="$(mktemp)"; printf '0' > "$FAILF"
_chk() { if [ "$1" = "$2" ]; then printf '  PASS %s\n' "$3"
  else printf '  FAIL %s (got [%s] want [%s])\n' "$3" "$1" "$2"
       printf '%s' "$(( $(cat "$FAILF") + 1 ))" > "$FAILF"; fi; }

# _tier PROMPT → the pipeline the hook records, or <none> when it declines to arm.
_tier() {
  rm -rf "$T/.runs"
  ( cd "$T"; printf '%s' "$1" | "$here/bin/delivery-marker-init.sh" >/dev/null 2>&1 ) || true
  local r p
  r="$(cat "$T/.runs/current" 2>/dev/null || true)"
  [ -n "$r" ] && [ -f "$T/.runs/$r/RUN" ] || { printf '<none>'; return 0; }
  p="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('pipeline','<absent>'))" "$T/.runs/$r/RUN" 2>/dev/null || echo '<err>')"
  printf '%s' "$p"
}
_src() {
  local r; r="$(cat "$T/.runs/current" 2>/dev/null || true)"
  [ -n "$r" ] && [ -f "$T/.runs/$r/RUN" ] || { printf '<none>'; return 0; }
  python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('tier_source','<absent>'))" "$T/.runs/$r/RUN" 2>/dev/null || echo '<err>'
}

T="$(mktemp -d)"
mkdir -p "$T/specs/full-text-search" "$T/specs/m"
for d in full-text-search m; do
  printf '# S\n' > "$T/specs/$d/spec.md"; printf '# P\n' > "$T/specs/$d/plan.md"
  printf '# Tasks\n\n- [ ] T1 a\n  - file: bin/a.sh · (feat)\n' > "$T/specs/$d/tasks.md"
done

echo "a tier word in the DESCRIPTION must not select a pipeline:"
for c in 'give the user full control over billing:full' \
         'make the mvp checkout flow work:mvp' \
         'add a full-text search index:full' \
         'document the single-thread rollout:single-thread'; do
  txt="${c%:*}"; word="${c##*:}"
  got="$(_tier "/deliver \"$txt\"")"
  _chk "$([ "$got" = "$word" ] && echo "took-$word" || echo ok)" "ok" "\"$txt\" → not $word (got $got)"
done

echo
echo "…and a tier word inside the SPEC SLUG must not either (the v2.33.0 symptom):"
got="$(_tier '/deliver specs/full-text-search/spec.md')"
_chk "$([ "$got" = "full" ] && echo took-full || echo ok)" "ok" "specs/full-text-search → not full (got $got)"

echo
echo "an EXPLICIT first token still pins the tier (P1 — the operator decides):"
_chk "$(_tier '/deliver full "add OAuth login"')"        "full"          "/deliver full …"
_chk "$(_src)"                                          "operator"      "…recorded as operator-chosen"
_chk "$(_tier '/deliver mvp specs/m/spec.md')"          "mvp"           "/deliver mvp <spec path>"
# Plugin commands are namespaced with a colon; `/team-bootstrap <pipeline>` in SKILL.md is shorthand
# for the docs, not a literal invocation, and has never armed.
_chk "$(_tier '/team-bootstrap:team-bootstrap single-thread "do it"')" "single-thread" "/team-bootstrap:team-bootstrap single-thread …"
_chk "$(_tier '/team-bootstrap:deliver full "x"')"      "full"          "/team-bootstrap:deliver full …"

echo
echo "no explicit token ⇒ the harness sizes it:"
_chk "$(_tier '/deliver specs/m/spec.md')"      "single-thread" "spec path alone → computed from the spec"
_chk "$(_src)"                                  "harness"       "…recorded as harness-chosen"
_chk "$(_tier '/deliver "add a retry wrapper"')" "auto"         "description alone → auto (resolved at the A→B boundary)"

echo
echo "analysis pipelines still do not arm a code run:"
_chk "$(_tier '/team-bootstrap audit specs/m')" "<none>" "/team-bootstrap audit … ships no code — no marker"
_chk "$(_tier 'what does the full pipeline do?')" "<none>" "an ordinary question is not a delivery"

echo
echo "the real harness payload is a JSON envelope, not a bare string:"
_chk "$(_tier '{"session_id":"abc","cwd":"/Users/x/full-stack-app","prompt":"/deliver \"give the user full control\""}')" \
     "auto" "tier word in the prompt AND in cwd → still auto"
_chk "$(_tier '{"session_id":"abc","cwd":"/Users/x/proj","prompt":"/deliver full \"add OAuth\""}')" \
     "full" "…and a real first token is still read out of the envelope"

rm -rf "$T"
fail="$(cat "$FAILF")"; rm -f "$FAILF"
[ "$fail" -eq 0 ] && { echo "tier-token-parse.test.sh: OK"; exit 0; }
echo "tier-token-parse.test.sh: $fail failure(s)"; exit 1
