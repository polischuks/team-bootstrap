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
#   - DOCUMENTATION that merely quotes a skip — judged by the FILE'S OWN form (`_is_doc_file`: `*.md`,
#     `*.mdx`, `*.txt`, …), never by the directory, so a real suite under `docs/` is still scanned.
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

# --- the operator door (spec 021 AC-7, T027) ---------------------------------
# `--waive BY REASON EXPIRES` records the governed waiver this gate reads. It exists because a waiver
# reachable only by hand-editing JSON inside a run marker is not a governed escape — nothing records
# who opened it or when it closes except the discipline of whoever was editing, and that is exactly the
# discipline under pressure when a batch will not close. Validation is record_governed_waiver's, which
# is governed_waiver_ok's, which is this gate's: one definition, so a waiver that records always works
# and one that would not work is refused here with a reason instead of failing later at the gate.
# Procedure and the standard for a good `reason`: references/enforcement.md.
if [ "${1:-}" = "--waive" ]; then
  shift
  if [ "$#" -ne 3 ]; then
    echo "usage: $(basename "$0") --waive BY REASON EXPIRES(YYYY-MM-DD)" >&2
    echo "  records gate_integrity_waiver in the active run marker. Expiry is mandatory and must be in the future." >&2
    exit 64
  fi
  record_governed_waiver gate_integrity_waiver "$1" "$2" "$3" || {
    echo "$(basename "$0"): REFUSED to record gate_integrity_waiver — needs a non-empty by and reason, and a future YYYY-MM-DD expires, under an unambiguous active run." >&2
    exit 1
  }
  exit 0
fi

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
SKIP_SEG = ("skip",) + COND_NAMES
Q = "\"" + "\x27" + "`"

# Comment syntax is per LANGUAGE, not universal. Truncating every line at the first #, // or --
# silently hid a later skip behind a JS private field (this.#ci), Python floor division (1 // 2), a
# shell long flag (--flag) and a decrement (n-- > 0) — five measured under-detections. The extension
# picks the markers; an unknown extension gets the conservative pair, and every marker still has to sit
# where a comment can start (line-start or after whitespace).
BY_EXT = {
    "py": ["#"], "rb": ["#"], "sh": ["#"], "bash": ["#"], "zsh": ["#"], "yml": ["#"], "yaml": ["#"],
    "pl": ["#"], "r": ["#"], "tf": ["#"],
    "js": ["//"], "jsx": ["//"], "ts": ["//"], "tsx": ["//"], "mjs": ["//"], "cjs": ["//"],
    "go": ["//"], "java": ["//"], "kt": ["//"], "kts": ["//"], "c": ["//"], "h": ["//"],
    "cc": ["//"], "cpp": ["//"], "hpp": ["//"], "cs": ["//"], "rs": ["//"], "swift": ["//"],
    "scala": ["//"], "php": ["//"], "dart": ["//"], "m": ["//"],
    "sql": ["--"], "lua": ["--"], "hs": ["--"], "ex": ["#"], "exs": ["#"], "elm": ["--"],
}
ext = path.rsplit(".", 1)[-1].lower() if "." in path.rsplit("/", 1)[-1] else ""
MARKS = BY_EXT.get(ext, ["#", "//"])

def strip_comments(t):
    out, q, i = [], None, 0
    while i < len(t):
        c = t[i]
        if q:
            out.append(c)
            if c == "\\" and i + 1 < len(t):
                out.append(t[i+1]); i += 2; continue
            if c == q: q = None
        elif c in Q:
            q = c; out.append(c)
        else:
            starts = (i == 0 or t[i-1].isspace())
            hit = None
            for mk in MARKS:
                if t[i:i+len(mk)] == mk and starts:
                    # `--` opens a comment only when followed by whitespace (SQL/Lua style); `--flag`
                    # is an argument and `n--` is an operator.
                    if mk == "--" and not (i + 2 >= len(t) or t[i+2].isspace()): continue
                    hit = mk; break
            if hit: break
            out.append(c)
        i += 1
    return "".join(out)

def split_args(t, k):
    # t[k] is the opening paren. -> (top-level args, parsed_ok)
    depth, q, cur, args, i = 0, None, "", [], k
    while i < len(t):
        c = t[i]
        if q:
            cur += c
            if c == "\\" and i + 1 < len(t):
                cur += t[i+1]; i += 2; continue
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
# The receiver may be a CHAIN (`test.describe.skip(`): match the whole chain, so the call is recognised
# and so a skip sitting MID-chain (`describe.skip.each(...)`, a first-class Jest/Vitest way to disable a
# whole parametrised suite permanently) is not lost because `each` happens to be the final segment.
CALL = re.compile(r"(?:^|[^\w$.])((?:[A-Za-z_$][\w$]*\s*\.\s*)*)([A-Za-z_$][\w$]*)\s*\(")
# A skip modifier can also be REFERENCED without being called: `const gate = describe.skip;`
BARE = re.compile(r"\.\s*(skip|Skip)\s*(?![\w$(])")
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
    # For a runner whose skip signature IS (condition, description), a non-literal first argument in a
    # 2+-argument call IS the condition -- including a plain boolean variable. The label hole stays
    # closed by the two-argument requirement: `test.skip(SKIP_REASON)` has one argument.
    if len(args) >= 2 and (recv or "").lower() in COND_FIRST: return True
    return False

out = []
try:
    lines = open(path, errors="replace").read().splitlines()
except Exception as e:
    # FAIL CLOSED. Exiting 0 here would excuse the whole file in silence, which is the one outcome
    # this gate exists to prevent -- and it would defeat the CLASSIFIER-FAILED fallback of its caller.
    sys.stderr.write("cannot read %s: %s\n" % (path, e)); sys.exit(1)

for n, raw in enumerate(lines, 1):
    if re.search(r"gate-integrity:\s*sanctioned", raw, re.I): continue
    code = strip_comments(raw)
    hit = False
    for m in CALL.finditer(code):
        chain, name = m.group(1), m.group(2)
        segs = [x for x in re.split(r"\s*\.\s*", chain) if x]
        # a skip that is not the final segment is a MODIFIER on the call, never a condition
        if any(sg.lower() in SKIP_SEG for sg in segs) and name.lower() not in NAMES:
            hit = True; break
        recv = segs[-1] if segs else None
        if name.lower() not in NAMES: continue
        args, ok = split_args(code, m.end() - 1)
        if not ok:
            # The call is wrapped over several lines. Complete it before judging: reporting a
            # prettier-wrapped conditional skip would be the fail-on-correct-code cost that gets
            # gates switched off. Still bounded, and still reported if it never closes.
            joined = code + " " + " ".join(strip_comments(l) for l in lines[n:n+5])
            args, ok = split_args(joined, m.end() - 1)
        if not conditional(recv, name, args, ok): hit = True; break
    if not hit and BARE.search(code): hit = True
    if not hit and DECOR.search(code): hit = True
    if hit:
        out.append("%d:%s" % (n, raw))
        if len(out) >= mx: break
print("\n".join(out))
' "$1" "${2:-20}" 2>/dev/null
}

# A classifier that cannot run makes this gate BLIND, and a blind gate that prints OK is precisely the
# silent degradation clause 2 of this file exists to flag. It used to end `|| true`: with python3 absent
# the function returned nothing, every file looked clean, and the gate reported OK (found by review, and
# reproduced with a stub python3 exiting 127). So it fails CLOSED, with the reason stated (P6/P10).
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-gate-integrity: CANNOT EVALUATE — python3 is required to classify skip calls and is not on PATH." >&2
  echo "  This gate is not passing; it is BLIND. Install python3, or record a governed gate_integrity_waiver." >&2
  exit 1
fi

viol=0

# 1) green-by-skip on a gate/invariant/constitutional/contract test -------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # PROSE is not a skipped test: `spec.md` matches the scan glob `--include=*spec*`, so a document that
  # merely QUOTES a skip was scanned as a suite (measured: this milestone's spec.md turned run-tests
  # red). The predicate is the FILE'S OWN form, not the directory it sits in — `_is_doc_path` would
  # exempt the whole `docs/` and `references/` trees, leaving a real suite at `docs/tests/gate_test.go`
  # unscanned, and keying on the directory would also re-scan prose that happens to live under `spec/`.
  _is_doc_file "${f#./}" && continue   # AC-13
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
    done < <(_unconditional_skips "$f" 20 || printf '0:CLASSIFIER-FAILED — this gate could not read the file and is NOT passing\n')
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

# 4) DECLARED BLINDNESS THAT PASSES ANYWAY (spec 021 AC-8) -----------------------
#
# The fourth way a gate stops gating, and the one that produced this milestone. check-role-verdict's
# `seen == 0` branch printed, verbatim, "role confirmation is UNVERIFIED for this batch, not
# satisfied" — and returned 0. Every word of the diagnosis was right; only the exit code disagreed
# with it. A gate in that shape is worse than a missing gate: it emits evidence of its own failure
# into a log nobody blocks on, and the batch closes green.
#
# F1 settles the rule: a gate that declares it cannot confirm must not confirm. Clause 2 catches the
# gate that says NOTHING; this one catches the gate that says the right thing and passes regardless.
#
# THE DISCRIMINATOR IS THE RETURN, NOT THE VOCABULARY. "cannot" appears in a dozen honest FAIL
# messages in this tree ("cites a commit git cannot resolve", "cannot verify reviewer independence"),
# every one of them followed by a refusal. Keying on the word alone would flag them all, and a check
# that cries wolf on correct code gets switched off — which is the outcome this whole file exists to
# prevent (F4). So a finding requires BOTH: the declaration, and a 0 reached from it.
#
# Three shapes are correctly NOT findings, and each is recognised by something in the code rather than
# by a hand-stamped exception:
#   - declare, then `return 1` / `exit 1` — the fix this clause exists to require;
#   - declare, then pass only through `governed_waiver_ok` — a governed, expiring escape whose finding
#     is printed before the waiver is consulted (AC-7). Governance is the difference between an escape
#     and a hole, and it is visible in the source;
#   - an inline `gate-integrity: sanctioned` marker, the convention the rest of this file already
#     uses. That door exists for a genuine AC-48 design and must carry its separating principle in the
#     reason — see check-role-verdict.sh, where a gate that cannot load its own library cannot
#     evaluate its own waiver either, so blocking there would be unconditional and un-waivable.
BLIND=0
for f in bin/check-*.sh; do
  [ -f "$f" ] || continue
  b="$(python3 -c '
import re,sys
DECL = re.compile(r"(DEGRADED|UNVERIFIED|CANNOT EVALUATE|cannot evaluate|cannot verify|cannot confirm|cannot certify|is BLIND)")
OUT  = re.compile(r"\b(echo|printf)\b")
SANC = re.compile(r"gate-integrity:\s*sanctioned", re.I)
PASS = re.compile(r"(^|[;&|{(]|\s)(return\s+0|exit\s+0)\s*(;|\}|$)")
STOP = re.compile(r"(^|[;&|{(]|\s)(return\s+[1-9]|exit\s+[1-9])|viol=|fail=|BLIND=|SILENT=")
GOV  = re.compile(r"governed_waiver_ok")
try: lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
except Exception:
    # A file this clause cannot read is not thereby clean. Fail closed, loudly, like the classifier above.
    print("0:UNREADABLE — this clause could not read the file and is NOT passing it"); sys.exit(0)
# The --self-test block belongs to the suite, not to the gate verdict: its fixtures print DEGRADED on
# purpose and its final `exit 0` is a test result. Excluded, as clause 2 excludes it. (No apostrophes
# below this line: the whole block is a single-quoted shell string, and one would end it early.)
st = next((i for i,l in enumerate(lines) if "--self-test" in l and "1:-" in l), len(lines))
# A sanction may sit on the line itself or anywhere in the contiguous COMMENT BLOCK immediately above
# it. A one-line trailing marker cannot carry a principle, and this door is only legitimate when it
# states the principle that separates it from the shape being flagged - so the reason needs room.
def sanctioned_above(idx):
    j = idx - 1
    while j >= 0 and lines[j].strip().startswith("#"):
        if SANC.search(lines[j]): return True
        j -= 1
    return False
out=[]
for i,line in enumerate(lines[:st]):
    if not (OUT.search(line) and DECL.search(line)): continue
    if SANC.search(line): continue
    # A VERDICT is what the gate says on its diagnostic channel, or what the script exits with. Text
    # written to STDOUT and followed by a function `return` is that helper DATA, not a decision:
    # check-seam-ack emits "(git status failed - cannot verify ...)" on stdout as a sentinel its caller
    # reads as a dirty path and then fails CLOSED on, and its `return 0` means "output complete".
    # Flagging it would be the cry-wolf this clause must avoid, and hand-stamping it would hide the
    # rule. So stdout declarations qualify only when the pass is a script-level `exit 0`.
    to_err = ">&2" in line
    def is_verdict(passline):
        return to_err or "exit" in passline
    # Same-line form first: `<test> || { echo "... cannot evaluate ..." >&2; exit 0; }`
    if PASS.search(line):
        if is_verdict(line) and not sanctioned_above(i):
            out.append("%d:%s" % (i+1, line.strip()))
        continue
    # Otherwise walk forward over code lines only, to the first decision.
    seen=0
    for j in range(i+1, min(i+1+40, st)):
        nxt = lines[j]
        if not nxt.strip() or nxt.strip().startswith("#"): continue
        if GOV.search(nxt): break              # governed escape — not a hole
        if STOP.search(nxt): break             # refuses, or records a violation
        if PASS.search(nxt):
            if is_verdict(nxt) and not SANC.search(nxt) and not sanctioned_above(j):
                out.append("%d:%s" % (i+1, line.strip()))
            break
        seen += 1
        if seen >= 8: break                    # bounded: a decision this far away is not this one
print("\n".join(out[:5]))
' "$f" 2>/dev/null)"
  [ -n "$b" ] || continue
  echo "check-gate-integrity: DECLARED BLINDNESS THEN PASSES in '$f' — says it cannot verify, returns 0:" >&2
  printf '%s\n' "$b" | sed 's/^/    /' >&2
  BLIND=$((BLIND + 1))
done
[ "$BLIND" -eq 0 ] || viol=$((viol + BLIND))

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
