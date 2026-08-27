# ADR-0023 — Dispatch is an attempt; confirmation is a verdict

- **Status:** Accepted
- **Date:** 2026-08-27
- **Milestone:** `specs/021-dispatch-and-gate-integrity` (F2, AC-4/AC-6/AC-15)

## Context

The plugin makes two promises about review: **assignment** (a review-typed subagent is dispatched)
and **confirmation** (a batch does not close without a typed verdict from the roles it required). An
audit of v3.2.1 found the second promise was not held, and not for one reason:

1. `dispatch.jsonl` recorded that a reviewer was dispatched, and three consumer comments said the
   record proved the reviewer "was LAUNCHED" or "ran". A `PreToolUse` hook fires **before** the tool
   executes; it cannot witness a launch, a run, or a result. The record was one claim past its evidence.
2. `check-role-verdict --gate` printed, verbatim, "role confirmation is UNVERIFIED for this batch, not
   satisfied" — and returned 0. A gate that declares its own blindness and passes is the green-by-skip
   the whole tree exists to refuse.

Measured in this repo: verdict capture is **0 of 7** dispatches (`SubagentStop` never produced a
`verdicts.jsonl`), so `seen == 0` is the steady state here, not an edge case.

## Decision

**A dispatch record is an ATTEMPT. Confirmation is a typed verdict. No gate concludes the second from
the first.**

- `record-dispatch.sh` writes `"outcome":"attempted"` on every line. There is one value; the hook
  cannot observe another. The field is additive and no consumer may require it — pre-3.3.0 records
  keep counting toward the anti-collapse floor.
- `references/review-types.txt` states what `dispatch.jsonl` is and, explicitly, what may not be
  concluded from it: not launched, not ran, not finished, not "role satisfied".
- The anti-collapse floor (`check-role-dispatch`'s ≥1, `reviewer_dispatch_count`) keeps counting
  attempts. Counting attempts is honest and is what defeats the spec-169 collapse (no review-typed
  dispatch at all). It is not evidence of a completed review, and nothing treats it as such.

## The fail-closed-on-blindness rule, and the one thing it does not cover

A gate that declares it cannot confirm must not confirm (constitution **P10**; spec F1). This is
already constitutional; what this ADR records is the **audit clause that enforces it** —
`check-gate-integrity` clause 4 flags any `bin/check-*.sh` path that prints `DEGRADED`/`UNVERIFIED`/
`cannot` and then returns 0. The discriminator is the **return**, not the vocabulary: "cannot" appears
in a dozen honest FAIL messages, each followed by a refusal, and flagging those is how a gate gets
switched off (F4).

The single relief is a **governed, expiring waiver** (`role_verdict_waiver`, `gate_integrity_waiver`):
`ack` + `by` + `reason` + `expires`, through one `governed_waiver_ok`, consulted **after** the finding
is printed. Both have an operator door (`--waive`) and a writer (`record_governed_waiver`); the share
of closures under a waiver is a metric, because a waiver is an event and a rising share is the
mitigation failing.

**The separating principle** (why `check-role-verdict.sh` sanctions its own library-load `exit 0`):
a gate that cannot load `delivery-lib.sh` cannot evaluate **anything**, including its own waiver —
`governed_waiver_ok` lives in the file that failed to load. Blocking there would be unconditional and
un-waivable, a gate no operator can ever clear, which is worse than the failure it prevents. `seen == 0`
is different: it is an *evaluable* state with a *working* escape, so it refuses. Absent-and-saying-so
is the honest report of a gate that could not start; a gate that CAN start and cannot confirm refuses.

## The observability rule (D7)

The signal that distinguishes "waiting for the operator before Phase B" from "Phase B was skipped"
must be **observable, never declared**. An `announced_sha` the orchestrator writes into the ledger is
forgeable by the same mind the gate exists to check. So the Stop hook anchors on a harness-stamped
sha — the last closure, else the run's own baseline (`closure_anchor`) — and asks whether any non-doc
code has moved that no closure covers. `no-code` ⇒ waiting, allow; `code` ⇒ skipped, block;
`cannot-determine` ⇒ block. Reachability, not time (ADR-0002); three-valued, so an unresolvable anchor
never reads as "nothing to deliver".

## Consequences

- **Behaviour break.** Closures that used to succeed with zero captured verdicts now fail (MINOR →
  v3.3.0). In this repo that is every `kind:code` closure until the capture channel is fixed, which is
  out of this milestone's scope. The waiver is the sanctioned bridge; the metric watches it.
- **DC-1 stays open.** Whether `updatedInput` merges or replaces `tool_input` was never resolved — the
  only run available was measured against an already-patched plugin cache. The B2 fix (return the whole
  `tool_input` with `prompt` replaced) is correct under both readings and required by F3 regardless, so
  nothing here depends on the answer. The claim that "no review ever ran" is unproven and is not
  repeated.

## Out of scope (unchanged)

The forgery gap (ADR-0006/0008): `subagent_type` is model-authored, so this raises the degradation bar,
not the forgery bar. A blocking `PreToolUse[Agent|Task]` gate: still rejected — blocking a dispatch
pushes review inline. Verdict-capture reliability: F1 requires that *absence* be a refusal, not that
capture improve.
