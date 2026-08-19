# Phase 0 — setup-readiness gate

Two halves of "is this delivery viable?" are asked at two different times by two different gates:

| Gate | Concern | When | Question | Marker key |
|---|---|---|---|---|
| [`bin/check-preflight.sh`](../bin/check-preflight.sh) | **setup**-readiness | **Phase 0** (start) | "can the flow *run* correctly here?" | `preflight` |
| [`bin/check-preconditions.sh`](../bin/check-preconditions.sh) | **deliver**ability | end of Phase A | "can the output *land*?" | `precond` |

They are complementary, not redundant — different questions, different marker keys. See
[ADR-0009](../docs/adr/0009-preflight-setup-gate.md).

## What Phase 0 checks

Run against a project dir (`bin/check-preflight.sh [dir]`). **Detect-and-report only** — it never creates
scaffold.

**Fail-closed (exit 1)** when any of these is missing:

- **constitution** — resolved via the `feature.json` `constitution` key (not a hardcoded name; a declared
  path that does not resolve fails loud, naming it — P11).
- **`specs/` dir** — via `feature.json` `specs_dir` (default `specs`).
- **`feature.json`** — present and parseable (grep-based, no `jq` — portable to `jq`-less hosts).
- **`docs/adr/`** — via `feature.json` `adr_dir` (default `docs/adr`).
- **run marker** — `.runs/<run>/RUN` present with `intends_code`+`baseline_sha`.
- **git repo** — a non-git target cannot anchor a run (non-recoverable here; there is no run to ack).

**Warn (does not fail):** `specs/TEMPLATE/`, `AGENTS.md`, and a `baseline_sha` that does not resolve to a
commit (it only degrades the batch-window `predate` check downstream).

On completion it records `preflight:{exit,gaps,ack}` into the active run marker (graceful no-op when there
is no marker or the run is not `intends_code`).

## How it is enforced

`check-delivery.sh` blocks a run at **batch-announce time** when the marker is present and
`intends_code==true` AND it has ≥1 announced `kind:code` batch AND the `preflight` verdict is **absent**
(the gate never ran — treated as not-run, P10), `preflight.exit!=0 && preflight.ack!=true` (failed and
unacknowledged), or **present-but-unreadable** (a verdict we cannot read is not a pass). This mirrors the
`precond` clause; both read via object-scoped `field_in_obj` so the two objects' shared `exit`/`ack` keys
never cross-read. The clause is gated on a real code batch, so a direct-pipeline run (no ledger), a
marker-less replay, or a pre-feature run is inert.

## Acknowledging a gap

Fix the scaffold and re-run, **or** — on the human's go-ahead — set `preflight.ack:true` in
`.runs/<run>/RUN`. The ack covers the whole verdict (`preflight.exit!=0 && preflight.ack==true` ⇒
proceed). The one case an ack cannot help is a target that is **not a git repo**: `check-preflight` fails
on it outright and there is no run marker to hold the ack — fix the repo.

## The marker plumbing (why two objects can share `exit`/`ack`)

The run marker is grep-parsed (no `jq`, for portability). `precond` and `preflight` both carry `exit`/`ack`.
Reads use `field_in_obj MK OBJECT KEY` (isolate the balanced `"OBJECT":{…}` slice first, then extract), and
writes use `_marker_strip_obj_key MK KEY` (a **position-independent** object strip, the object analog of
`_marker_strip_flat_key`). The position-independent strip is load-bearing: `record_precond`'s original
greedy end-anchored strip deleted any object written **after** `precond`, so appending `preflight` would
have silently wiped the Phase-0 verdict on every end-of-Phase-A run (a self-disarm). Any future marker
object that reuses `exit`/`ack` must use these two helpers — never global first-match or an end-anchored
strip.

## Self-check

```
bin/check-preflight.sh --self-test     # all-present pass, one fail per required element, marker record, skip
bin/check-preflight.sh .               # against this repo (setup-ready when a run marker is active)
```
E2E: on a fully scaffolded repo it exits 0; on a bare `git init` dir it exits 1 with the named scaffold gaps.
