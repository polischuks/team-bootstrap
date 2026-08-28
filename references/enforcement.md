# Enforcement — make the gates non-skippable

A gate written as a role playbook is **prose the orchestrator can skip**. Anthropic's own data:
written instructions are followed ~70% of the time, a hook enforces at ~100%
([Claude Code best practices](https://code.claude.com/docs/en/best-practices)). Auditing real
`/deliver` output confirmed it — the reviewer roles existed, yet batches shipped dead code, drift,
and unreviewed diffs because the roles simply weren't run ("gate didn't run"). The fix is to move
enforcement of the **outcomes** off the LLM and onto the **harness**: roles *reason*, the harness
*enforces they held* ([The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification);
deterministic control flow, [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).

## Enforcement layers (defense in depth)

The first three layers enforce that the delivered **code is clean**. The fourth enforces that
**delivery actually happened** — a distinct class of failure the code-quality gates are blind to: a
batch declared "closed" in prose while no pipeline ran and no code changed. All three code gates pass
a docs-only or never-run batch (nothing to typecheck, no orphans, no drift), so "closed" stayed a
claim. The delivery-occurred layer makes it a recorded machine fact instead.

| Layer | Mechanism | Catches | Bypassable? |
|---|---|---|---|
| **Always-on** | Stop hook → [`../bin/quality-gate.sh`](../bin/quality-gate.sh) | typecheck + lint red on completion | no (harness) |
| **Batch gate** | [`../bin/verify-batch.sh`](../bin/verify-batch.sh) at each batch close | dead code (orphans), drift, green-by-skip, red-not-touching-tests (F1), under-covered change (F2), weak assertions (F3, opt-in) | LLM-invoked (see CI) |
| **Delivery-occurred** | [`../bin/check-delivery.sh`](../bin/check-delivery.sh) inside `verify-batch.sh` + the ledger stamp | a `kind:code` batch announced but **never closed** by a pipeline run; a closure with zero code delta | in-session: **no**; CI: only if the run's ledger is committed (`.runs/` is gitignored by default) |
| **Role-execution** | `PreToolUse` recorder → `.runs/<run>/dispatch.jsonl` + [`../bin/check-role-dispatch.sh`](../bin/check-role-dispatch.sh) inside `verify-batch.sh` | a `full`/`mvp` `kind:code` batch that dispatched **no reviewer subagent** — the silent collapse of the multi-role pipeline to single-thread (spec-169), **announced** to the user | in-session: **no** (marker-gated); CI: **not** re-run (`.runs/` gitignored — no dispatch record survives a fresh checkout); degradation-proof, not forgery-proof (ADR [0008](../docs/adr/0008-harness-verified-role-execution.md); per-role floor under enforce, ADR [0009](../docs/adr/0009-per-role-dispatch-floor.md)) |
| **Setup-readiness (Phase 0)** | [`../bin/check-preflight.sh`](../bin/check-preflight.sh) at Phase 0 records a `preflight` marker verdict; [`../bin/check-delivery.sh`](../bin/check-delivery.sh) blocks batch-announce while it is absent / failing-unacked / unreadable | a `/deliver` run against an **unscaffolded** project (no constitution / `specs/` / `feature.json` / `docs/adr/` / armed marker) — the downstream gates would no-op (P10 green-by-skip) | in-session: **no** (marker-gated); CI: `check-preflight` still runnable as a scaffold linter, but the *enforcement* is marker-gated (ADR [0010](../docs/adr/0010-preflight-setup-gate.md)) |
| **Independent backstop** | **CI** runs `verify-batch.sh` on every PR/push | everything above, from scratch, regardless of what the local run did | **no** — the merge blocks |

### How closure becomes a fact (delivery-occurred layer)

The orchestrator writes a ledger entry at Announce (`.runs/<run>/batches.jsonl`, `status:announced`).
Only `verify-batch.sh`, on a passing batch, flips it to `closed` and stamps `commit_shas` + a
`code_delta` computed over non-doc files. `check-delivery.sh` then fails the run if any prior
`kind:code` batch sits `announced` (announced, never delivered) or `closed` with zero code delta.

**Closure is a function of repository state git can prove, not a self-declared field** (v2.12.0, F-A).
An earlier design trusted the stamped numbers — a hand-written
`{"status":"closed","commit_shas":["deadbeef"],"code_delta":137}` passed, because nothing checked that
the SHA existed or that the delta was real. It no longer does. `check-delivery.sh`:

- `git rev-parse`/`cat-file` **each `commit_sha`** — a SHA git cannot resolve fails the run (AC-1);
- **recomputes** the non-doc delta from those commits (shared `nondoc_delta_of_shas` in
  [`../bin/delivery-lib.sh`](../bin/delivery-lib.sh), the same function `verify-batch.sh` stamps with, so
  stamp == recompute by construction) and fails if the stamped `code_delta` **exceeds** it (AC-2);
- under an active run **binds each commit to one batch** — no cross-batch SHA reuse, and every commit
  must post-date the run baseline (F-2), so closure cannot be earned from arbitrary pre-existing history.

So a forged `closed` line — prose **or** JSON — is inexpressible: it must name real, batch-owned,
post-baseline commits whose non-doc delta backs the stamp. That is the whole point.

**Self-starting + fail-closed** (F-B): a harness `UserPromptSubmit` hook
([`../bin/delivery-marker-init.sh`](../bin/delivery-marker-init.sh)) writes `.runs/<run>/RUN`
(`intends_code:true`, `baseline_sha`) — so "a delivery run is active" is a **machine fact the harness
owns**, not an orchestrator courtesy. It arms on **every code pipeline**, not just `/deliver`: the
orchestrated `/deliver` command *and* a direct `/team-bootstrap:team-bootstrap single-thread|mvp|full …`
run both ship code and are guarded equally. Analysis pipelines (`audit`, `audit-dd`, `l2p`) ship no code
and never arm. Under a marker, `check-delivery.sh` inverts its absent-input branch from *skip* to *fail*.
Without a marker (non-delivery session) the exit-0 skip stays, so nothing nags docs-only or WIP work.

**Delivery is satisfied two git-grounded ways** — neither forgeable by prose:

1. **Ledger closure** — a `verify-batch`-stamped `kind:code` batch (the `/deliver` Phase-B path, above).
2. **Baseline delta** — real non-doc code committed since `baseline_sha`, reachable from HEAD
   (`code_since_baseline` in [`../bin/delivery-lib.sh`](../bin/delivery-lib.sh)). This is the **direct
   pipeline** path: `/team-bootstrap single-thread …` writes no batch ledger (deliver.md itself
   recommends it for small changes), yet must still prove delivery by real commits.

An armed run with **neither** — no closed batch and no code since baseline — is fail-closed: it ran a
pipeline and shipped nothing. A delivery-aware Stop hook
([`../bin/delivery-stop-hook.sh`](../bin/delivery-stop-hook.sh)) blocks completion (exit 2) on the same
condition (or an announced-but-unclosed batch), so no code pipeline can finish having delivered nothing.

### Red→green is a git fact, not a boolean (P9)

P9 requires tests **written first, run and seen to fail**, then implemented to green. That was prose plus
a self-declared `tests_failed_first` boolean — the schema never required it and no gate checked it, so an
agent could write code and rubber-stamp tests after, or skip them, and still report `completed`. Now the
red step is git-grounded:

- [`../bin/check-tdd.sh --record-red`](../bin/check-tdd.sh), run at the red step, executes the project's `Test:` command,
  **requires** a non-zero (red) result — it refuses to record a green suite — and stamps the observed red
  (`red_sha` = HEAD) into `.runs/<run>/tdd.jsonl`. The record can only exist because the tests actually ran
  red; prose cannot fabricate it.
- [`../bin/check-tdd.sh`](../bin/check-tdd.sh) (a `verify-batch` gate) enforces this **per code batch**:
  for **each** `kind:code` batch (closed → against its own `commit_shas`; the in-flight one → against HEAD),
  a red record bearing that batch's id must exist whose `red_sha` is a **descendant of the run baseline and
  a proper ancestor of that batch's code**. One red record credits **at most one batch** (no reuse across
  batches), so `baseline < red₁ < code₁`, `code₁ < red₂ < code₂`, … — every batch is red-first in its own
  window. The suite must also be **green at HEAD**. Any code batch with no valid red ⇒ fail-closed. (A
  direct pipeline run with no ledger falls back to one run-level red before HEAD.)

Honest reach: it enforces that each code batch had *a* genuine red→green, on a project that declares a
runnable `Test:` command (no command ⇒ warns, unenforceable). It does **not** judge whether the test asserts
the *right* behavior — a wrong-but-failing test still counts; test quality stays with `qa-test-engineer` and
review. And, like the delivery layer, it is marker-gated ⇒ in-session (CI has no marker).

### Test-quality gates — the floor, not the ceiling (P9/P10, v2.17.0)

Three `verify-batch` gates raise what the harness mechanically guarantees about a batch's *tests*, each
marker-gated, git-grounded, project-declared-by-command, and **skip+warn when the project declares no
tooling** (never a false block):

- **F1 red-touches-tests** ([`../bin/check-tdd.sh`](../bin/check-tdd.sh) — `--record-red` and the close-time gate) —
  a recorded red must be caused by a **committed test-file change**, not an `--allow-empty` or unrelated
  red. Closes the narrow forge the base red gate left open ([tdd.md](tdd.md)).
- **F2 diff-coverage** ([`../bin/check-diff-coverage.sh`](../bin/check-diff-coverage.sh)) — after green, the
  batch's **changed non-doc lines** must be covered ≥ `CoverageThreshold:` (default 80), measured from the
  project's LCOV over the same `current_batch_base` window the `code_delta` stamp uses. Enforces *breadth*
  — catches "one trivial test for a 200-line change".
- **F3 mutation** ([`../bin/check-mutation.sh`](../bin/check-mutation.sh)) — the only automated judge of
  **assertion strength**: mutate the changed code, require score ≥ `MutationThreshold:`. **Opt-in/advisory
  by default** (cost); enforces only under `MutationMode: enforce`.

**Floor, not ceiling.** None of these certifies a *good* test suite — they eliminate the worst failures (no
test, fake red, under-coverage, vacuous asserts) mechanically. Whether a test asserts the **intended**
behavior stays with `test-designer`/`qa-test-engineer`/review — stated, logged, not proven (ADR-0003).
Contract fields live in [agents-md-contract.md](agents-md-contract.md); all three carry `--self-test` and
are `shellcheck`-clean (P8/P10).

Honest reach: `.runs/` is gitignored, so the ledger/marker are per-run *local* state. This layer bites
**in-session** — via the git-derived gate AND the harness marker, which the orchestrator cannot skip its
way past — and reproduces in CI **only when a run commits its ledger**. It does not weaken the
code-clean layers, which remain non-bypassable in CI regardless.

**Scope of the guarantee (be precise):** F-2 commit binding and the fail-closed branches are **marker-gated**,
so they run **in-session only** — in CI, neither marker nor ledger exists (`.runs/` gitignored), so
`check-delivery.sh` takes its exit-0 skip and the "independent backstop" means orphans/architecture/
gate-integrity, *not* the delivery-occurred layer. When `check-delivery.sh` runs **without** an active
marker it says so explicitly ("MARKER-LESS run — F-2 binding and fail-closed are NOT enforced"): a
marker-less pass is only the basic SHA-exists + delta-not-inflated check, not the full guarantee. Under
an active marker each cited commit must additionally be **reachable from HEAD** (on this run's delivered
history, not a sibling/discarded branch) and post-date the baseline. One further presence-dependency:
AC-7's blocking ack only bites if `check-preconditions.sh` actually recorded `precond.exit==2` — if that
probe is never run, no advisory is recorded and nothing blocks (the marker defaults `precond.exit:0`).

The batch gate is the same script CI runs, so a batch whose local run skipped `integration-verifier`
or `code-reviewer` still fails at merge. That is the point: **CI is the layer the orchestrator cannot
talk its way past.**

### Version-sync — manifests cannot drift (v2.18.0)

A release must not bump `VERSION` while leaving `.claude-plugin/plugin.json` / `marketplace.json` stale —
a drift this framework itself shipped twice (`v2.12.1`, `v2.17.0`), each time silently: the plugin
self-reported the old version and `claude plugin update` offered nothing.
[`../bin/check-version-sync.sh`](../bin/check-version-sync.sh) (a `verify-batch` gate) collects every
declared version field — for a plugin: `VERSION`, `plugin.json.version`, and **every** `"version"` in
`marketplace.json` (metadata + each `plugins[]`); otherwise the AGENTS.md `VersionFiles:` set — and
**fails when they disagree**, naming each location and the plurality value (report truth; the human
bumps). No version locations ⇒ skip + WARN. Marker-gated ⇒ in-session (a committed-manifest CI check is
a cheap follow-on). It has no version field of its own and dogfooded its own milestone: B2's bump to
2.18.0 closed only because all four fields agreed.

### Closure certifies fidelity, not just "tests green" (v2.19.0)

A retrospective found a HIGH bug (a CAS predicate `IN (owed-set)` where candidates were `= 'done'` → 0
rows updated → infinite loop) that **passed every gate**. The cause was not a missing gate but three
**disarmed** ones: P9 red-first, F2 diff-coverage, F3 mutation all **silently skipped** because the
project declared no `Test:`/`Coverage:`/`Mutation:` — the bug slipped through gates that were *off*, not
*absent* (same self-disarm class as the v2.18.1 marker-whitespace bug). Two adjacent gaps compounded it:
closure was silent on **fidelity** (are the declared tasks done, is every AC exercised by a test?) and on
the **named-but-unread high-risk seam**. Three `verify-batch` gates close that, each marker-gated ⇒
in-session, git/artifact-grounded, `--self-test`, never a false block:

- **A — enforcement-visibility** ([`../bin/check-enforcement.sh`](../bin/check-enforcement.sh)) — records
  which quality dimension is unenforceable (`enforcement_gaps` in the marker) and **blocks a code batch
  from closing** until `enforcement_ack:true`. A `run-rate|irreversible` batch **hard-fails** on any gap
  regardless of the ack (the CAS bug was a run-rate reconciliation path). The silent skip becomes a
  logged, dated decision — parity with the precond-ack pattern.
- **B — completeness** ([`../bin/check-completeness.sh`](../bin/check-completeness.sh)) — per batch, every
  `task_id` in the ledger entry must be `[x]` in `specs/<slug>/tasks.md`; `--final` (invoked by
  `deliver.md` at finalization) requires **no** `[ ]` left and **every** `AC-N` in `spec.md` referenced by
  ≥1 `is_test_path` file (`AcPattern:` configurable). Catches "closed but undone / unimplemented". Reads
  `tasks.md`, never writes it — the AC→test reference is the machine-grounded half of the check.
- **C — high-risk-seam ack** ([`../bin/check-seam-ack.sh`](../bin/check-seam-ack.sh)) — the architecture
  review records its highest-risk seams (`high_risk_seams:[{seam,paths}]`); a batch whose files intersect
  a flagged seam's paths must carry a `seam_acks` entry naming the seam + a resolvable commit (a recorded
  "read it in the shipped code"). Turns named risk → named manual verification into a recorded step.

Honest boundary (stated, not assumed): the A/C acks and B's `[x]` are **recorded, blocking, referenced** —
truthfulness is the human's, logged not proven (parity with `risk_rank`/precond). None replaces mutation
testing (F3) as the judge of assertion strength — they make its **absence** visible and force the
decision. The immediate unblock for a real project is to **declare `Test:`/`Coverage:`/`Mutation: enforce`**
so F1/F2/F3 actually run (out of this plugin's scope — P7 — documented). This milestone dogfooded all
three on itself, and building A's marker rewrite surfaced + locked a real bash-5.2 `${//}` backslash-leak
in the marker-write path — the exact seam C guards. See [ADR-0005](../docs/adr/0005-closure-fidelity-gates.md).

### The control surface is a standing high-risk seam (v2.26.0)

Every layer above protects the *delivered code*; nothing protected the **gates and hooks themselves**.
`check-gate-integrity` catches *green-by-skip* but has no notion of the expected gate set, so a batch that
edited `bin/check-*.sh` into vacuity or dropped a gate line from `verify-batch.sh` was caught by nothing.
The control-surface-protection milestone ([ADR-0012](../docs/adr/0012-control-surface-protection.md))
extends P10's non-disableability to the machinery itself — **without a new gate**. `check-seam-ack` now
treats the single-source glob set in [`control-surface.txt`](control-surface.txt) (read by
`delivery-lib.sh:control_surface_globs()`, BASH_SOURCE-relative like `review_types()`) as an
**always-present** high-risk seam, unioned in *before* the "no high_risk_seams recorded" early return. So a
`kind:code` batch (or, since the skip is keyed on the run-level `intends_code`, any batch inside a code run)
whose git window touches `bin/check-*.sh`, `verify-batch.sh`, `delivery-lib.sh`,
`record-dispatch.sh`, `hooks/*.json`, `.claude`, `.mcp.json`, `AGENTS.md`, `commands`, `agents`, or the list
file **must record a `control-surface` seam-ack** (naming the shipped commit + a `file:line` note) or the
batch cannot close. Two hardening fixes back it: the matcher is now **glob-aware** (an unquoted-`$token`
`case` branch, so `bin/check-*.sh`/`hooks/*.json` actually match — both detection and ack-validation route
through it and cannot disagree), and the batch-file window is **fail-closed** (an empty/unresolvable git
window never falls back to the ledger's self-declared `"files"`).

**How to record it when you legitimately edit the machinery** (this repo does, every milestone): after the
commit that ships the control-surface change, add to `.runs/<run>/RUN`:

```json
"seam_acks":[{"seam":"control-surface","commit":"<short-sha>","note":"path:line — what changed + why"}]
```

The commit must be reachable from HEAD, post-baseline, and actually touch a surface path (the same
validation chain as any seam-ack). A non-`control-surface`-named ack does **not** satisfy the standing seam.

**Honest boundary.** This makes a machinery change *declared + acked + reviewable*, not impossible. The
enforcing gate is itself control surface and `verify-batch` runs the committed HEAD, so a batch that
co-edits the **circular core** (`check-seam-ack`/`verify-batch`/`delivery-lib`/`control-surface.txt`) and
drops the gate invocation escapes the in-plugin check (isolated tampering is caught; a co-committed core
edit is not). Closing that is repo/org posture the plugin cannot force — a CI-from-trusted-ref check
(shipped as an *example*, [`.github/control-surface-ci.sh`](../.github/control-surface-ci.sh)) that is
non-circular **only under branch-protection**, plus org `sandbox-runtime` immutability. The headline is
declaration discipline, not tamper-proofing.

### The enforcement ack is a governed, expiring waiver (v2.20.0)

A second retrospective found gate A **worked but deprecated into routine**: a `feature|doc` batch passed
on a bare `enforcement_ack:true`, and the dogfood project re-acked the same gaps every run as "expected"
— the detector fired, but the ack became a perpetual free pass (F4 at the meta level). v2.20.0 makes the
waiver *governed* ([ADR-0007](../docs/adr/0007-time-boxed-waivers.md)):

- **Complete + dated.** A valid `enforcement_ack` now requires `enforcement_ack_by`,
  `enforcement_ack_reason`, `enforcement_ack_expires` (`YYYY-MM-DD`), and `enforcement_ack_category ∈
  {host_structural, deferred}`. Past `expires` (vs a passed-in `TEAM_BOOTSTRAP_NOW`, default system date),
  or any field missing ⇒ **no ack**. The waiver must be re-acknowledged, not silently inherited.
- **Category is derived, not trusted.** `host_structural` (the tool provably cannot exist on host) is
  legitimate only when **no** gap dimension has a declared+resolvable tool. If `Coverage:`/`Mutation:` is
  declared *and* resolves on PATH, that gap is `deferred` by construction (arm it, don't waive it) and a
  `host_structural` label is rejected → forced to `deferred`. This makes the exemption airtight on target
  projects — the label cannot be forged to dodge a tier.
- **Tiered hard-require, with a structural exemption.** An *ackable* gap (unwaived, or `deferred`) is
  hard-failed on the highest-cost paths: a batch touching a recorded `high_risk_seams` path **and** a
  `run-rate|irreversible` batch. A gap under a **valid `host_structural`** waiver is **exempt from every
  tier** — otherwise team-bootstrap (whose bash coverage/mutation tools cannot exist) could never ship a
  run-rate fix to its *own* gate machinery. Honest limit: for a repo whose gaps are permanently
  host_structural, the expiry buys **visibility in post-review**, not prevention; the tiered prevention is
  load-bearing for *target* projects where the tooling exists (gaps are `deferred` ⇒ no ack escape).

**Repo-capability opt-out — the honest state between `host_structural` and `deferred` (issue #66).**
`host_structural` means "the tool provably cannot exist on host". For most repos that is a *lie* — a
JS/Python project *can* run Stryker/coverage, it just doesn't — so a repo with no such toolchain had only
two ways past a `run-rate|irreversible` tier: mislabel `host_structural`, or **downgrade `risk_rank`** (the
launder this gate exists to prevent). Neither is honest. A repo may now declare a governed, repo-level
**`CapabilityOptOut:`** in AGENTS.md/CLAUDE.md (`mutation`/`diff-coverage`, plus `CapabilityOptOutBy:` /
`CapabilityOptOutReason:` and an optional `CapabilityOptOutExpires:`). A named dimension is dropped from the
tier's **owed-gap** set, so the batch closes on the gates the repo *can* run with the missing dimension left
recorded in `enforcement_gaps` — a **visible** gap, not a risk downgrade. Crucially this is **derived, not
trusted**, exactly like the `host_structural`→`deferred` demotion: a dimension whose `Coverage:`/`Mutation:`
command is declared **and resolves on PATH** is `deferred` (arm it), so the opt-out **cannot weaken
enforcement where the tooling exists**. It is repo-scoped (a capability decision, committed to the contract,
attributable by git blame), distinct from the per-run marker waivers below. team-bootstrap itself keeps its
`host_structural` waiver — its bash coverage/mutation tools genuinely cannot exist — but a target repo that
simply does not do mutation testing now has a first-class, honest way to say so.

**Diff-scoped mutation blind spot (target-project doctrine).** Where mutation *is* armed, diff-scoped
runs match against production code, so an assertion weakened in an otherwise-unchanged file, or precision
erosion spilling into an untouched region, is invisible to the per-batch run (cargo-mutants / Stryker note
this explicitly). Target projects should pair the diff-scoped enforce gate with a **scheduled full-repo
advisory** run as backstop. team-bootstrap declares no mutation tool, so this is doctrine, not a local job.

### Role execution is harness-observed, not narrated (v2.21.0)

The layers above enforce that the delivered **code is clean** and that **delivery occurred**. They do not
see *how* the pipeline executed. On spec-169 the `full` pipeline **silently collapsed to single-thread** —
the orchestrator absorbed the builder **and** the reviewer roles, `verify-batch` still went green, and the
user was told "delivered, gates passed" while no independent review ran. `full`/`mvp` exist precisely to
give each batch a fresh independent mind (P2); that separation was **prose the orchestrator could skip**.

The **role-execution layer** moves it onto the harness. A non-blocking `PreToolUse[Agent]` recorder
([`../bin/record-dispatch.sh`](../bin/record-dispatch.sh)) writes each **reviewer-typed** dispatch
(`subagent_type` ∈ [`review-types.txt`](review-types.txt), the single source) to `.runs/<run>/dispatch.jsonl`;
[`../bin/check-role-dispatch.sh`](../bin/check-role-dispatch.sh) then **fails closed and announces** when a
`full`/`mvp` `kind:code` batch closes with zero reviewer-typed dispatches. Doctrine mandates the four review
roles dispatch as subagents with a dedicated review type in `full`/`mvp` (`single-thread` inline stays
sanctioned, P1), and `check-review-ack`'s marker claim is now **corroborated** by a real dispatch record
(closing 0006's forgeable-marker residual for the dispatch dimension).

Honest reach ([ADR-0008](../docs/adr/0008-harness-verified-role-execution.md)): `subagent_type` is
model-authored, so this is **degradation-proof, not forgery-proof** — it catches a total inline collapse,
not a decoy review-typed no-op dispatch; and it proves the reviewer was *dispatched*, not that it *completed*
or was *good* (quality stays 0006 + the refutation doctrine). **Per-role floor (v2.22.0, ADR-0009):** the ≥1
total-collapse fail is the hard floor; **under enforce** the gate additionally requires **every mandated role**
covered (`full` = all four dedicated types `integration-verifier`/`architecture-reviewer`/`regression-guardian`/
`tb-code-reviewer`; `mvp` = `code-reviewer` + `regression-guardian`), so a 1-of-4 partial collapse is caught.
Attribution needs distinct per-role slugs (`subagent_type` alone could not tell `integration-verifier` from
`regression-guardian`). It ships in **warn** — announces the missing roles, does not fail — flipping to enforce
only when the committed `references/role-dispatch-enforce` marker is present (after a dispatch probe confirms
four-distinct-slug adoption; the plugin cannot force dispatch, so enforce is reachable only once measured).
Per-role raises the **degradation** floor, not the forgery bar. And, like the
delivery layer, it is marker- and `dispatch.jsonl`-gated ⇒ **in-session only** (`.runs/` is gitignored, so a
fresh CI checkout has no dispatch record and the gate skips). It is strictly stronger than a marker string,
and it is the same prose→harness move this whole document embodies — now applied to **process**, not only
outcomes. On an `intends_code` `kind:code` batch whose pipeline is neither `full`/`mvp` nor the sanctioned
`single-thread` (a malformed marker), the gate **fails closed** rather than skip — undeterminable input is
never a silent pass.

## CI backstop (add to the target project)

Add a job that runs the batch gate against the change — this is what makes review non-optional:

```yaml
# .github/workflows/verify.yml (target project)
name: verify
on: [pull_request, push]
jobs:
  gates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }   # check-orphans needs the diff
      - run: path/to/team-bootstrap/bin/verify-batch.sh .
```

A red `verify` check blocks the merge. Dead code, drift, and green-by-skip cannot reach `main` even
if the delivery run skipped the reviewer roles.

## Strict opt-in — block completion in-session

For zero tolerance within a session, register `verify-batch.sh` on the **Stop / SubagentStop** hook
so Claude Code **cannot finish a batch** until the gates pass ([Hooks reference](https://code.claude.com/docs/en/hooks)):

```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "${CLAUDE_PLUGIN_ROOT}/bin/verify-batch.sh" } ] } ] } }
```

This is **not shipped on by default** — the outcome checks (orphans/architecture) are heuristic and
would block *every* stop, including intentional work-in-progress pauses. Claude Code caps consecutive
Stop-hook blocks (default 8) to prevent loops. Enable it per project when you want the session itself
to be non-bypassable; otherwise rely on the CI backstop, which is both non-bypassable and non-annoying.

## Role coverage (the other half)

Enforcement assumes the reviewer roles are *in the pipeline* to begin with. `code-reviewer`,
`integration-verifier`, `architecture-reviewer`, and `regression-guardian` are now in **`mvp`,
`full`, and `single-thread`** — no pipeline ships a batch unreviewed. The harness layers above make
sure they actually run.

## Governed waivers — the only sanctioned way past a fail-closed gate

Two gates refuse rather than pass when they cannot confirm, and both are relieved the same way: a
**governed waiver** recorded in the active run marker.

| gate | waiver key | what it relieves |
|---|---|---|
| `bin/check-role-verdict.sh --gate` | `role_verdict_waiver` | a **dropped capture** for the in-flight batch: every required role IS in `dispatch.jsonl` but no verdict landed (spec 021 AC-6/AC-7; discriminated per issue #81 — see below) |
| `bin/check-gate-integrity.sh` | `gate_integrity_waiver` | pre-existing green-by-skip / can't-fail findings the batch did not introduce |
| `bin/check-mutation.sh` | `mutation_waiver` | under `MutationMode: enforce`, a diff-scoped mutation run infeasible for this batch — a small change dragging a large file into mutation (issue #66 comment) |

**Governed** means four fields, all required: `ack:true`, `by`, `reason`, `expires` (`YYYY-MM-DD`, in
the future). A bare `ack` is not a waiver. An expired one is not a waiver. There is one definition —
`governed_waiver_ok` in `delivery-lib.sh` — and both the writer and the gates read it, so a waiver that
records always works and one that would not work is refused at write time with a reason.

### The procedure

```bash
bin/check-role-verdict.sh --waive "<who>" "<why>" 2099-01-01
```

```bash
bin/check-gate-integrity.sh --waive "<who>" "<why>" 2099-01-01
```

```bash
bin/check-mutation.sh --waive "<who>" "<why>" 2099-01-01
```

Each writes its own key into the run marker of the active run and prints what it recorded. Until spec
021 there was **no writer at all**: the only occurrence of `gate_integrity_waiver` outside the gate
that read it was a hand-written fixture in a test, which made "hand-edit JSON in the run marker" the
whole procedure. That is not a governed escape — nothing records who opened it or when it closes
except the discipline of whoever is editing, and that is exactly the discipline under pressure when a
batch will not close.

### What a waiver does not do

- **It does not silence the finding.** Both gates print the finding *before* consulting the waiver, then
  announce that they waived it. A governed escape that hides its own finding is an invisible one.
- **It does not expire on its own terms.** `expires` is mandatory so a waiver is an event with an end
  date rather than a posture. After it lapses the gate refuses again, which is the point.
- **It is run-scoped, not batch-scoped.** A per-batch waiver invites one per batch (spec 021 OQ-2).

### Watch the share, not the instance

`bin/delivery-metrics.sh` reports **code runs closed under a waiver** as a share. One waiver is an
event. A rising share is the mitigation failing: the escape has become the way batches close.

Read this before waiving `role_verdict_waiver` in particular. Verdict capture was measured at **0 of 7**
dispatches in this repo (spec 021 plan §8.3) — every review-typed subagent, under an armed run with a
`kind:code` batch in flight, and `verdicts.jsonl` was never created. So after v3.3.0 this waiver is not
an exception path here; it is the only way a `kind:code` batch closes until the capture channel is
fixed, and fixing it was explicitly out of that milestone's scope. Waiving it is correct. Waiving it
without an issue tracking the capture channel is how the number stops being watched.

### The capture-failure path, discriminated (issue #81)

The root cause is a host limitation, proven and settled: **Claude Code does not emit `SubagentStop` for
Agent-tool-dispatched review subagents** (upstream anthropics/claude-code#27755-class; issue #60). The
verdict a reviewer returns in-report therefore never reaches `verdicts.jsonl` through that hook. Two
things now stop the waiver from being blind ceremony:

1. **The waiver is DISCRIMINATING.** `dispatch.jsonl` (written on `PreToolUse[Agent]`, the **reliable**
   channel) records fact-of-dispatch. `check-role-verdict.sh --gate` uses it to split the old ambiguity:
   - **capture-dropped** — every required role IS in `dispatch.jsonl`, but no verdict landed. This is the
     *only* case `role_verdict_waiver` may relieve. Diagnosis: `capture-channel-did-not-fire` (or
     `captured-then-lost` per #46) in `.runs/<run>/verdict-capture.jsonl`.
   - **skipped** — a required role is **absent** from `dispatch.jsonl` (it was never dispatched). Diagnosis
     `role-not-dispatched` (partial) or `no-reviewer-dispatched` (nothing at all). This case is **never
     waivable**: the gate returns non-zero *before* consulting the waiver, so a valid `role_verdict_waiver`
     cannot pass a batch that skipped a review. Dispatch the missing role — do not reach for the waiver.

2. **A synchronous channel that does not need `SubagentStop`.** Instead of waiting for a hook that will
   not fire, record each reviewer's verdict **explicitly, after it returns**:

   ```bash
   printf '%s' '<the reviewer's typed verdict JSON>' | bin/check-role-verdict.sh --record <role>
   ```

   This validates the verdict against the role's required shape in `role-output.schema.json` (a shapeless
   "looks fine" is blocked, exit 2, exactly as the hook path blocks it), refuses to record a verdict for a
   role that has **no** `dispatch.jsonl` record (you cannot manufacture evidence for a review that never
   ran), and on success writes the same `verdicts.jsonl` line the gate reads — so `--gate` then confirms
   the batch **with no waiver at all**. `commands/deliver.md` instructs the orchestrator to call this after
   the review fan-out returns.

   **Honest limit:** this is *orchestrator-recorded*, not host-forced. Nothing in the host compels the
   `--record` call; a run that skips it lands back on the capture-dropped waiver above. What it is **not**
   is transcript-scraping or a flaky async hook — when the orchestrator does call it, the write provably
   happens and the gate provably reads it. Its forgery bar is the existing one (ADR-0006/0008): the verdict
   must carry its role's declared shape, and a well-formed lie still passes. Recording the verdict of a
   review that actually ran is correct; the discriminating waiver above remains the sanctioned path for the
   genuine host-drop case.
