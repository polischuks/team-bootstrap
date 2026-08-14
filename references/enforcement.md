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

- [`../bin/tdd-red.sh`](../bin/tdd-red.sh), run at the red step, executes the project's `Test:` command,
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

- **F1 red-touches-tests** ([`../bin/tdd-red.sh`](../bin/tdd-red.sh) + [`../bin/check-tdd.sh`](../bin/check-tdd.sh)) —
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
