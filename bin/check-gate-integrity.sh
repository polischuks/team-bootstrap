#!/usr/bin/env bash
# check-gate-integrity.sh — meta-check that gates actually run (fail-closed).
#
# A gate is only worth its non-disableability. This flags two ways a gate stops
# gating while still reading green:
#   1. green-by-skip — a gate/invariant/constitutional/contract test that passes
#      only because it is skipped (@pytest.mark.skip, .skip(, t.Skip, @Disabled…);
#   2. silent degradation — a `bin/check-*.sh` that exits 0 on an unmet precondition without
#      stating a reason, so "skipped" and "passed" are the same result to every reader (AC-48);
#   3. a gate that can't fail — `continue-on-error: true` on a CI gate job.
# See references/regression-and-invariants.md (section 3).
#
# NOT flagged (a conditional skip still RUNS under the right condition, and an
# explicitly-justified deferral is a decision, not a silent hole):
#   - CONDITIONAL skips, judged per CALL by the shape of the call rather than by a list of
#     frameworks (_unconditional_skips, below): a callback argument (`() => …`, `function …`,
#     `x -> …`), a genuine expression as the first argument of a runner whose skip signature is
#     (condition, description), or a conditional name (skipif / skipIf / skipUnless / skipWhen /
#     assumeTrue). A LABEL is not a condition — `test.skip(SKIP_REASON)` is flagged — and neither is
#     a hard-coded constant: `test.skip(true, "…")` is the usual way to make a conditional-form skip
#     permanent, and it is flagged.
#   - sanctioned skips: any skip line carrying an inline `gate-integrity:
#     sanctioned` marker (add `# gate-integrity: sanctioned — <reason>` on the
#     skip line to record WHY the deferral does not hide a gate).
#   - DOCUMENTATION that merely quotes a skip (`*.md`, `*.txt`, …) — but never a real test file, even
#     under `docs/`: the two shared predicates are composed, `_is_doc_path && ! is_test_path`.
#
# KNOWN PLATFORM DIVERGENCE (pre-existing, not introduced here): the file scan uses `grep -r --include`,
# which matches the BASENAME on GNU grep and the WHOLE PATH on BSD/darwin. The set of files scanned
# therefore differs between a darwin dev machine and ubuntu CI. Worth knowing before tuning the scan.
#
# Usage: bin/check-gate-integrity.sh [project-dir]   # default: current dir
# Exit:  0 clean / not machine-checkable · 1 integrity violation · 64 bad usage
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/delivery-lib.sh
. "$here/delivery-lib.sh"

root="${1:-.}"
cd "$root" 2>/dev/null || { echo "check-gate-integrity: bad dir '$root'" >&2; exit 64; }

KEY='invariant|constitution|constitutional|gate|contract|security|guard'
SKIP='@pytest\.mark\.skip|@unittest\.skip|pytest\.skip\(|\.skip\(|\bxit\(|\bxdescribe\(|it\.skip|describe\.skip|test\.skip|t\.Skip\(|@Disabled|@Ignore'

# _unconditional_skips FILE [MAX] -> `LINENO:text` for each line carrying at least one UNCONDITIONAL
# skip. A CONDITIONAL skip RUNS under its condition and is not a hole, so it is not a finding.
#
# This was `grep -vE '<exclusions>'`, and a regex cannot answer the question. Three independent reviews
# of that version found seven real green-by-skips it excused: Go's `t.Skip(reason, "why")` (Go has no
# conditional skip form at all, but case-insensitive matching folded a JavaScript signature onto it),
# `test.skip(true, "...")` (the standard way to make a conditional-form skip permanent -- a constant is
# not a predicate), a nested call in the first argument, a conditional NAME merely mentioned in a
# trailing comment, `it.skip(asyncCaseLabel)` (matched `async` as a PREFIX), a parenthesised label, and
# a second skip sharing a line with a conditional one (the filter dropped whole LINES, not calls).
#
# So each skip CALL is classified on its own:
#   conditional   - a callback first argument (`() => ...`, `function ...`, `x -> ...`); a genuine
#                   EXPRESSION first argument in a runner whose skip takes a condition first
#                   (test/it/describe/suite/context/this); or a conditional NAME (skipif / skipIf /
#                   skipUnless / skipWhen / assumeTrue).
#   unconditional - everything else: no argument, a string or backtick label, a boolean/numeric
#                   constant, or a bare identifier used as a label.
# Comments are stripped before classification, and anything unparseable is REPORTED, not excused (P10).
_unconditional_skips() {
  python3 -c '
import re, sys
path, mx = sys.argv[1], int(sys.argv[2])
COND_NAMES = ("skipif", "skipunless", "skipwhen", "assumetrue")
# The one place a framework name is load-bearing: these runners spell skip as (condition, description).
# Everywhere else the rule is the SHAPE of the argument, so an unnamed framework behaves correctly.
COND_FIRST = ("test", "it", "describe", "suite", "context", "this")
Q = "\"" + "\x27" + "`"

def strip_comments(t):
    out, q, i = [], None, 0
    while i < len(t):
        c = t[i]
        if q:
            out.append(c)
            if c == "\\\\" and i + 1 < len(t): out.append(t[i+1]); i += 2; continue
            if c == q: q = None
        elif c in Q: q = c; out.append(c)
        elif c == "#" or t[i:i+2] in ("//", "--"): break
        else: out.append(c)
        i += 1
    return "".join(out)

def split_args(t, k):
    # t[k] is the opening paren. -> (top-level args, parsed_ok)
    depth, q, cur, args, i = 0, None, "", [], k
    while i < len(t):
        c = t[i]
        if q:
            cur += c
            if c == "\\\\" and i + 1 < len(t): cur += t[i+1]; i += 2; continue
            if c == q: q = None
        elif c in Q: q = c; cur += c
        elif c in "([{":
            depth += 1
            if depth > 1: cur += c
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(cur); return [a.strip() for a in args], True
            cur += c
        elif c == "," and depth == 1: args.append(cur); cur = ""
        else: cur += c
        i += 1
    return [], False

LIT  = re.compile(r"^(\"|\x27|`|true$|false$|none$|nil$|null$|-?\d+(\.\d+)?$)", re.I)
CB   = re.compile(r"^(\(.*\)|[A-Za-z_$][\w$]*)\s*(=>|->)|^(async|function)\b")
EXPR = re.compile(r"[=!<>&|?+*/%.\[(]")
# The receiver may be a CHAIN (`test.describe.skip(`): match the whole chain and take its LAST
# segment as the receiver, or a chained call is not recognised as a skip at all.
CALL = re.compile(r"(?:^|[^\w$.])((?:[A-Za-z_$][\w$]*\s*\.\s*)*)([A-Za-z_$][\w$]*)\s*\(")
NAMES = ("skip", "skipif", "skipunless", "skipwhen", "assumetrue", "xit", "xdescribe")
DECOR = re.compile(r"@(Disabled|Ignore)\b|@pytest\.mark\.skip(?!if)\b|@unittest\.skip(?!If|Unless)\b")

def conditional(recv, name, args, ok):
    if not ok: return False
    if name.lower() in COND_NAMES: return True
    if not args or args[0] == "": return False
    a0 = args[0]
    while a0.startswith("(") and a0.endswith(")"): a0 = a0[1:-1].strip()
    if CB.search(a0): return True
    if LIT.match(a0): return False
    if len(args) >= 2 and (recv or "").lower() in COND_FIRST and EXPR.search(a0): return True
    return False

out = []
try: lines = open(path, errors="replace").read().splitlines()
except Exception: sys.exit(0)
for n, raw in enumerate(lines, 1):
    if re.search(r"gate-integrity:\s*sanctioned", raw, re.I): continue
    code = strip_comments(raw)
    hit = False
    for m in CALL.finditer(code):
        chain, name = m.group(1), m.group(2)
        recv = [x for x in re.split(r"\s*\.\s*", chain) if x]
        recv = recv[-1] if recv else None
        if name.lower() not in NAMES: continue
        args, ok = split_args(code, m.end() - 1)
        if not conditional(recv, name, args, ok): hit = True; break
    if not hit and DECOR.search(code): hit = True
    if hit:
        out.append("%d:%s" % (n, raw))
        if len(out) >= mx: break
print("\n".join(out))
' "$1" "${2:-20}" 2>/dev/null || true
}

viol=0

# 1) green-by-skip on a gate/invariant/constitutional/contract test -------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # PROSE is not a skipped test: `spec.md` matches the scan glob `--include=*spec*`, so a document that
  # merely QUOTES a skip was scanned as a suite (measured: this milestone spec.md turned run-tests red).
  # The two shared definitions are COMPOSED rather than either being re-stated: `_is_doc_path` alone
  # would exempt the whole `docs/` and `references/` TREES, leaving a real suite at
  # `docs/tests/gate_test.go` unscanned -- a hole, not a fix.
  { _is_doc_path "${f#./}" && ! is_test_path "${f#./}"; } && continue   # AC-13
  if printf '%s' "$f" | grep -qiE "$KEY" || grep -qiE "$KEY" "$f" 2>/dev/null; then
    # Candidate skip lines: the UNCONDITIONAL ones (_unconditional_skips classifies each CALL),
    # A sanction marker is also honoured on the line IMMEDIATELY ABOVE the skip, so a
    # long skip line need not carry an over-length trailing comment.
    sk=""
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      prev="$(sed -n "$((ln - 1))p" "$f" 2>/dev/null)"
      printf '%s' "$prev" | grep -qiE 'gate-integrity:[[:space:]]*sanctioned' && continue
      sk="${sk}${ln}:${text}
"
    done < <(_unconditional_skips "$f" 20)
    sk="$(printf '%s' "$sk" | grep -vE '^$' | head -5)"
    [ -n "$sk" ] || continue
    echo "check-gate-integrity: GREEN-BY-SKIP in gate/invariant test '$f':" >&2
    printf '%s\n' "$sk" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
done < <(grep -rlE "$SKIP" . --include='*test*' --include='*spec*' --include='*_test.go' \
  --exclude='*.pyc' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.claude \
  --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=venv \
  --exclude-dir=dist --exclude-dir=build --exclude-dir=.next \
  --exclude-dir=.mypy_cache --exclude-dir=.ruff_cache --exclude-dir=.pytest_cache \
  2>/dev/null | head -100)

# 2) SILENT DEGRADATION — a gate that returns emptiness instead of a decision (AC-48) ------------
#
# The third way a gate stops gating, and the one no check looked for. `exit 0` on an unmet
# precondition is correct and necessary — check-tdd skips without a Test: command, check-version-sync
# skips without a version location — but a skip that says NOTHING is indistinguishable, in a log and
# in a batch result, from a gate that ran and passed. AC-47 removed exactly this shape from
# size-from-spec.sh (`--per-batch` returned empty where it now returns `degraded=1 reason=…`), and
# AC-48 asks for the audit: every path that declines to decide states why.
#
# Flagged: a `bin/check-*.sh` line that exits 0 inside a conditional with no output on any stream.
# Not flagged: an exit 0 that prints first (the reason IS the output), the unconditional final exit 0
# of a passing gate, and the `--self-test` block (its exits are the test's own results).
SILENT=0
for f in bin/check-*.sh; do
  [ -f "$f" ] || continue
  # `|| exit 0`, `&& exit 0`, `{ exit 0; }` and `then exit 0` with nothing echoed on the same line.
  # The shape is a PRECONDITION guard: `<test> || exit 0` / `<test> && exit 0`, optionally braced.
  # Deliberately NOT the terminal dispatch `if _evaluate; then exit 0; else exit 1; fi` — the function
  # has already printed its verdict there, so the exit carries no information of its own — and not
  # `--help`. A pattern that flagged those would report every gate in the tree, and a check that cries
  # wolf on correct code gets disabled, which is the outcome this whole file exists to prevent.
  q="$(grep -nE '^[[:space:]]*[^#]*(\|\||&&)[[:space:]]*(\{[[:space:]]*)?exit 0' "$f" 2>/dev/null \
       | grep -vE 'echo|printf|>&2|self-test|--help|then[[:space:]]+exit[[:space:]]+0|gate-integrity:[[:space:]]*sanctioned' \
       | head -5)"
  [ -n "$q" ] || continue
  echo "check-gate-integrity: SILENT DEGRADATION in '$f' — exits 0 without stating a reason:" >&2
  printf '%s\n' "$q" | sed 's/^/    /' >&2
  SILENT=$((SILENT + 1))
done
[ "$SILENT" -eq 0 ] || viol=$((viol + SILENT))

# 3) a gate that can't fail: continue-on-error on a CI job -----------------------
if [ -d .github/workflows ]; then
  ce="$(grep -rnE 'continue-on-error:[[:space:]]*true' .github/workflows 2>/dev/null | head -20)"
  if [ -n "$ce" ]; then
    echo "check-gate-integrity: gate cannot fail (continue-on-error) in CI:" >&2
    printf '%s\n' "$ce" | sed 's/^/    /' >&2
    viol=$((viol + 1))
  fi
fi

if [ "$viol" -gt 0 ]; then
  echo "check-gate-integrity: $viol integrity issue(s) — a gate that doesn't run is a failure, not a pass." >&2
  # WS-8 (harness-robustness): a GOVERNED run-level waiver clears pre-existing findings the batch did not
  # introduce (the retro's dashboard skips + e2e continue-on-error OUTSIDE the batch delta, which forced a
  # hand-stamp every batch). It does NOT silence them — the findings are already printed above. Governed =
  # ack + by + reason + expires; expiry forces re-review, so a disabled gate cannot pass forever. In CI
  # there is no run marker, so the waiver is impossible there and a genuinely disabled gate is never hidden.
  # (Full per-finding delta-scoping is deferred — arch-review flagged its risk of silently dropping a
  # finding outside the delta; a surfaced-and-expiring waiver is the sound, simpler mechanism.)
  marker="$(resolve_marker)"
  if [ -n "$marker" ] && [ -f "$marker" ]; then
    mk="$(cat "$marker" 2>/dev/null || true)"
    if governed_waiver_ok \
         "$(field_in_obj "$mk" gate_integrity_waiver ack)" \
         "$(field_in_obj "$mk" gate_integrity_waiver by)" \
         "$(field_in_obj "$mk" gate_integrity_waiver reason)" \
         "$(field_in_obj "$mk" gate_integrity_waiver expires)"; then
      echo "check-gate-integrity: WAIVED by a governed gate_integrity_waiver (findings surfaced above; by/reason/expires recorded, expiry forces re-review) — exit 0." >&2
      exit 0
    fi
  fi
  exit 1
fi
echo "check-gate-integrity: OK — no green-by-skip or can't-fail gate detected."
exit 0
