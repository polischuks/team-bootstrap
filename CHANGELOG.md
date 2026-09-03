# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.10.1] — 2026-09-03

**Retro-fix batch (#104 writer, #127–#129).** Four issues from live `/deliver` runs (spec-110, spec-187), each shipped red-first with a revert-check.

### Fixed

- **`code_baseline_sha` WRITER shipped** (#104, reopened): 3.10.0 released only the consumer (`current_batch_base` reads the field) — the writer was never added, so the field stayed unset and a Phase-A `feature.json` commit kept leaking into the first code batch's tdd anchor. `delivery-marker-init` now stamps `code_baseline_sha=HEAD` at the A→B boundary (armed harness run, `tasks.md` committed at HEAD, no code batch announced, field unset). The code-batch guard reads the run's **own** ledger (`.runs/$run`), not `resolve_ledger` — which honours the exported `TEAM_BOOTSTRAP_RUN` and could point at a different run than the arm is stamping.
- **Delta helpers survive an empty sha list** (#127, regression from 3.10.0): `nondoc_delta_of_shas`/`impl_delta_of_shas` crashed with `unbound variable` on an empty list under `set -u` (bash 3.2). Guarded with `${list[@]+"${list[@]}"}`; the test runs under `set -u` so it reddens without the fix.
- **`--record-lock` doctrine warns the mutation-revert is destructive** (#128): `git checkout -- <file>` reverts **all** uncommitted changes in the file, not just the mutation — on spec-110 it wiped co-located green edits. `check-tdd`'s messages and `deliver.md` now tell the operator to commit green (or stash) first.
- **Announce-before-dispatch warning** (#129): dispatching a reviewer before its `kind:code` batch is announced attributes the dispatch to the previous **closed** batch, and `check-role-verdict --record` then refuses. `record-dispatch` now emits a non-blocking warning (scoped to `intends_code` runs) naming the ordering error before the refusal.

### Notes
- Activation needs a plugin reinstall at 3.10.1.
- CI-suite policy (#53/#54/#59, `ci.yml continue-on-error`) remains a deferred follow-up.

## [3.7.0] — 2026-08-28

**Test-infrastructure + delivery-integrity batch (#53–#81).** Ten issues from the spec-176 live run and a 3.6.0 test-cost analysis, integrated with one acceptance-caught stale-green fixed on the way in.

### Fixed

- **check-delivery understands a withdrawn batch** (#75): a pre-code reviewer no_go is recorded as `status:withdrawn`; the gate now resolves each id to its latest status (withdrawn = terminal, like closed) instead of reading the withdrawal as "a later batch ⇒ abandoned" and fail-closing the run. `deliver.md` documents withdrawal as the sanctioned no_go response. Caught live on spec-176, where it forced a manual ledger reset.
- **Nested marker objects tolerate spaced JSON** (#80): the presence detectors for `precond`/`preflight` (and the write-guards) route through one whitespace-tolerant `obj_present`, so a `json.dump`-spaced marker no longer false-blocks delivery with "Phase-0 gate never ran".
- **Role-verdict waiver discriminates dropped-capture from skipped-role** (#81): a required role absent from `dispatch.jsonl` (skipped) stays blocked even with a waiver; only a dispatched-but-uncaptured role (host SubagentStop didn't fire, #60) is waivable. Adds a synchronous `check-role-verdict --record` channel the orchestrator calls after a review returns — verdict capture independent of the flaky hook (orchestrator-recorded, documented as such, not machine-forced).

### Added / performance

- **Selective test runs** (#76): `run-tests.sh --changed` runs only the members an edit could affect; `<glob>` runs named members; the full run stays the default. A `--changed` run agrees with a full run on shared members.
- **Result cache** (#77): opt-in `--cache` skips members whose inputs are unchanged since their last green; `--no-cache` forces full; green-only, input-keyed, so a cached pass can't mask a failure.
- **Parallel-runner test shrunk** (#78): 17s → ~3s, gated to run only when the runner changes.
- **De-forked integration gates** (#79): wiring tests inspect the call site instead of re-forking peers' `--self-test`; per-role evals batched/cached. ~28s off the serial suite, no gate weakened (mutation gates still redden). *Acceptance note: #79's liveness cache keyed on the repo tree, not the invoked root, colliding across test fixtures — fixed to engage only for the repo's own root (`verify-batch` invocation), preserving the delivery-retry dedup.*
- **CI runs the declared Test: suite** (#53/#54): a matrix job runs `bin/run-tests.sh` (+ the runner's own two proofs) on macOS (required, green) and ubuntu (informational, `continue-on-error`) with `fetch-depth: 0`. Linux portability of a few members (#59) stays a data-driven follow-up the informational leg now surfaces per-member.

### Notes
- Activation needs a plugin reinstall at 3.7.0.
- #59 (full ubuntu-green) remains open; the CI job makes its failures visible without blocking.

## [3.6.0] — 2026-08-28

**Friction cluster from three live retrospectives.** Eleven fixes to the delivery gates and doctrine surfaced by real `/deliver` runs (specs 185, 097, 178-179) — one a regression from 3.4.0, the rest long-standing sharp edges where the machinery assumed a shape the real work didn't hold.

### Fixed

- **check-delivery counts only batch lines** (#62, regression from #56): the `{"confirm":"<id>"}` line that check-batch-confirm appends no longer inflates the ledger total or makes a confirmed in-flight batch read as "abandoned". Counts/orders over lines carrying `"id"` only.
- **Un-pinned the completeness path** (#63): `commands/deliver.md` uses `${CLAUDE_PLUGIN_ROOT}/bin/check-completeness.sh` instead of a stale `2.18.1/bin/...` absolute path.
- **verify-batch caches the suite verdict on tree state** (#64): a retry whose tree is byte-identical (e.g. an ack-only ledger edit) reuses the cached green instead of re-running the whole suite; any real code change invalidates the key. Mutation was already cached.
- **stop-hook distinguishes waiting-for-reviewers from abandoned** (#65): an open batch with reviewers dispatched (per dispatch.jsonl) and not yet returned is treated as *waiting* — no exit-2 churn — while a genuinely abandoned code run still blocks.
- **Enforcement gains a governed repo-capability opt-out** (#66): a repo that does not run mutation/coverage tooling declares it (attributable, visible, in AGENTS.md) so run-rate/irreversible batches close without a risk_rank downgrade — ignored the moment a real tool resolves on PATH. `check-mutation` also gains the governed `--waive` the other enforce gates have.
- **First-class regression-lock batch form** (#67): a batch may prove itself with a lock whose obligation is "the lock reddens when the locked behaviour is mutated" (`check-tdd --record-lock`), instead of a manufactured HEAD~1 red.
- **check-tdd rejects an obvious wrong-cause red** (#68): an import/collection/syntax/missing-file red no longer satisfies red-first on its own; any assertion signal still passes (conservative, to avoid false-rejects).
- **Preflight tells Mode-2 from split-brain** (#69): a spec-only pre-Phase-A start (plan/tasks legitimately not yet produced) is no longer reported as a partial/split-brain tree; a dir that *lost* recorded artefacts still fails.
- **Single-sourced the reviewer panel** (#70): check-role-dispatch and check-review-ack now read one shared required-reviewer set, so a batch never fails review-ack late for a role dispatch said it didn't need. (Root cause: review-ack ran before the sized set was recorded.)
- **gate-integrity scopes to the batch delta; diff-coverage shows its denominator** (#71): standing skips outside the batch no longer demand a waiver each run (whole-tree audit stays available via `--audit`); coverage output states measured-vs-total changed lines.
- **A marker helper CLI** (#72): `bin/marker.sh` records acks/waivers in the correct validated shape (proven against the gates that read them) so operators never hand-edit the machine-owned RUN JSON.

### Notes

- Activation needs a plugin reinstall at 3.6.0.
- CI test-suite job remains deferred to #59.

## [3.5.0] — 2026-08-28

**Verdict capture rewired + delivery cost instrumented.** Two fixes from watching real 3.4.0 delivery runs where verdict capture was 0-of-N and a single spec cost ~1.1M tokens / ~3h46m with no way to see where.

### Fixed

- **Verdict capture is carried off the plugin-level `SubagentStop` event** (#60). The capture path previously lived only in each review agent's frontmatter `Stop` hook, which does not fire for Agent-tool-dispatched subagents — so `verdicts.jsonl` was never written and every code batch closed on a manual waiver. `check-role-verdict` now reads the subagent's own transcript (`agent_transcript_path`, not the main-session `transcript_path`), and `hooks.json` registers a plugin-level `SubagentStop` for the review roles. When capture still cannot run, the batch-close gate writes a `verdict-capture.jsonl` trace naming *why* (`capture-channel-did-not-fire`) instead of a guess — the gate still refuses/waives fail-closed. NOTE: live firing of `SubagentStop` for Agent-tool dispatches is a host capability this layer cannot force or self-test; the fix makes capture mechanically possible and the failure diagnosable.

### Added

- **Per-batch and per-role wall-time instrumentation** (#61). `record-dispatch` stamps each review dispatch with `ts`; `verify-batch` stamps `closed_at` on batch close; `delivery-metrics` reports per-batch and per-role wall-time (human + `--json`) so a multi-hour run can be attributed. Tokens are **not** included: a bash hook cannot see per-subagent token usage (investigated — no hook payload carries it), and the output says so (`tokens_available:false`) rather than fabricating a number.

### Notes

- Activation of the new `SubagentStop` registration needs a plugin reinstall at 3.5.0.
- The CI test-suite job remains deferred to #59 (suite not yet green on any GitHub runner).

## [3.4.0] — 2026-08-28

**Batch: eight open issues.** Verdict capture, sizing honesty, guard scoping, delivery flow, and the
first CI enforcement of the test suite itself.

### Fixed

- **Verdict capture identifies its role from the agent frontmatter** (`--hook-role <slug>`), not from a
  payload field a real `SubagentStop` does not carry — the cause of 0-of-7 capture (#44). A captured
  verdict is also mirrored durably into the run marker, so an external wipe of `verdicts.jsonl` is
  reported as a *durability breach* naming the loss rather than reverting silently to "unverified" (#46).
- **An operator-declared tier reconciles its dependent sizing fields** instead of leaving `review_depth`,
  `risk_categories`, and `assigned_roles` describing the superseded computation; the harness re-size no
  longer overrules a human-set tier (#47).
- **The degraded-sizing re-size fires mid-turn** on `PostToolBatch` (`bin/delivery-resize.sh`), so a run
  whose artefacts land inside one agentic turn recovers without waiting for the next prompt (#48).
- **guard-git judges the target repository** of the git command (`git -C`, `cd … && git`), not the
  session repo, failing closed to the session on an unresolvable target (#49).
- **Per-batch delivery is non-stop by default**; the stop is a mechanism (`bin/check-batch-confirm.sh`,
  PreToolUse[Bash]) that blocks commit when `risk_rank ∈ {irreversible, run-rate}` or a role requested
  approval and no ledger confirmation exists — reading the field rather than asking the model to
  remember. The action-class backstop (guard-git + remote protection) remains the real guard against a
  forged-low rank (#56).

### Added

- **The test runner is now control surface** — `bin/run-tests.sh` is declared in
  `references/control-surface.txt`, so narrowing its member selection or dropping its failure
  propagation becomes an ack-required, independently-reviewed edit rather than a silent one (#54).

### Notes

- The three new hook bodies (`delivery-resize`, `check-batch-confirm`) and the frontmatter `--hook-role`
  wiring activate only after the plugin is reinstalled at 3.4.0.
- **#53 (CI runs the declared `Test:` suite) is deferred to #59.** Adding the job revealed the suite is
  not green on any GitHub runner — a pre-existing portability gap (bash/coreutils/shallow-checkout), not
  a regression here. It lands once #59 makes the suite CI-green on a macOS+ubuntu matrix.

## [3.3.0] — 2026-08-27

**Dispatch and gate integrity** (`specs/021-dispatch-and-gate-integrity`). Two independent defects let
a batch close green without a confirmed review: a ledger that recorded a dispatch as if it were a
completed review, and a verdict gate that declared it could not confirm and passed anyway. Both are
closed, along with five other false-result defects in the gates. See
[ADR-0023](docs/adr/0023-dispatch-attempt-vs-verdict.md).

### BREAKING

- **A `kind:code` batch with zero captured role verdicts no longer closes.** `check-role-verdict --gate`
  printed "role confirmation is UNVERIFIED for this batch, not satisfied" and returned 0; it now returns
  non-zero. The wording is unchanged — the outcome is not.
  *What the first run after reinstall will hit:* verdict capture was measured at **0 of 7** dispatches
  in this repository — `SubagentStop` never produced a `verdicts.jsonl`, across every dedicated review
  type. So on this codebase the refusal fires on essentially every code batch until the capture channel
  is fixed, which is **out of this milestone's scope**. The sanctioned bridge is a governed, expiring
  waiver:
  ```
  bin/check-role-verdict.sh --waive "<who>" "<why>" <YYYY-MM-DD>
  ```
  It records `role_verdict_waiver` (ack/by/reason/expires) in the run marker, the gate still prints the
  finding, and `bin/delivery-metrics.sh` reports the share of closures running under a waiver. Track the
  capture channel in an issue rather than letting the share climb. See
  [references/enforcement.md](references/enforcement.md).

### Fixed

- **A dispatch record is now marked an attempt.** `dispatch.jsonl` lines carry `"outcome":"attempted"`;
  a `PreToolUse` hook fires before the tool runs and cannot witness a launch, a run, or a result. The
  field is additive — pre-3.3.0 records without it still count toward the anti-collapse floor. Three
  consumer comments that claimed a record proved a reviewer "was LAUNCHED"/"ran" are corrected.
- **`check-gate-integrity` gains two clauses.** Clause 4 flags any `bin/check-*.sh` path that declares
  blindness (`DEGRADED`/`UNVERIFIED`/`cannot`) and returns 0 — the discriminator is the return, not the
  word, so honest FAIL messages are untouched. Clause 5 flags the SIGPIPE-under-`pipefail` class: a
  streaming producer (`git log`, `grep -r`, `find`, `seq`, `cat FILE`) feeding an early-exit consumer
  (`head`, `grep -q`), which can end a pipeline at 141.
- **The pipefail class has a fail-OPEN sub-class, not only a false failure.** Under `pipefail`,
  `producer | grep -q X` can return non-zero **even when `grep` matched**, so the caller reads "not
  found" for an X that is present — nondeterministic on buffering, so it passes in the small and fails
  at scale. Both directions are neutralised at the hazard sites and guarded by the meta-check.
- **The Stop hook tells waiting from skipping.** An announced-unclosed code batch with no code beyond
  the last closure is the flow *waiting* for the operator before Phase B, and no longer blocks;
  uncommitted non-doc edits, or a commit past the closure, still block. The anchor is harness-stamped,
  never an orchestrator declaration.
- **An ambiguous active run is declared, not guessed.** Two `.runs/*/RUN` sharing the newest mtime with
  no `.runs/current` yielded whichever sorted first. It now resolves to a sentinel that reads as "no
  path" to ordinary marker-gated gates (they skip) and as "ambiguous" to decision gates (the Stop hook
  fails closed). Pin `TEAM_BOOTSTRAP_RUN` or write `.runs/current` to disambiguate.

### Note

This release does **not** claim that "no review ever ran" on v3.2.1. Whether the pre-fix
`updatedInput` shape actually broke dispatch (DC-1) was never resolved — the only run available was
measured against an already-patched plugin cache. The B2 fix (hand back the whole `tool_input` with
only `prompt` amended) is correct whether the vendor merges or replaces `updatedInput`, so nothing here
depends on the answer.

## [3.0.0] — 2026-08-26

**Live roles and harness wiring** (`specs/020-live-roles-and-harness-wiring`). The policy layer could
compute which roles a change needed and had no way to say so; forty-seven of fifty-one roles had no
subagent definition and were invisible to the harness by construction. Both are closed.

Live role bindings, by the only honest measure (`bin/eval-role.sh --liveness`): **7 → 11**.

### BREAKING

- **Four roles gain a required handoff field.** `chaos-engineer` (`resilience_verdict`),
  `test-designer` (`test_design_verdict`), `legal-compliance-checker` (`release_recommendation`,
  promoted from optional) and `architecture-reviewer` (`architecture_verdict` + `review_mode`, with
  the mode's own fields required conditionally). A handoff from any of these that omits its field is
  now invalid. Role versions 1.1.0 → 2.0.0.
  *Migration:* emit the field. `bin/check-role-verdict.sh --self-test` shows the shape.
- **The per-role dispatch floor enforces by default.** `references/role-dispatch-enforce` is
  committed, so a code batch that dispatched fewer roles than it earned now FAILS instead of warning.
  The floor is sized from the batch's own paths, not blanket.
  *Migration:* dispatch the roles the harness names, or set `TEAM_BOOTSTRAP_ROLE_FLOOR=warn` for a
  single run. The gate message names the missing role.
- **A custom profile must declare `tier:` keys.** The tier→roles base set moved out of
  `delivery-lib.sh` into `profiles/*.map` as `tier:full` / `tier:mvp` / `tier:single-thread`.
  *Migration:* copy the three lines from `profiles/default.map`. A profile without them does not
  break — it falls back to the STRICTEST base and says so — but it will over-review until fixed.
- **`bin/tdd-red.sh` is deleted.** Its observation step is now `bin/check-tdd.sh --record-red`.
  *Migration:* replace `bin/tdd-red.sh --batch <id>` with `bin/check-tdd.sh --record-red --batch <id>`.
  Behaviour, exit codes and the `tdd.jsonl` record are unchanged.
- **`references/review-types.txt` grows by four slugs** (both forms each). Hosts that parse this file
  see new entries; the existing ones are untouched.

### Added

- **Risk categories and the assigned role set reach the model** on the sanctioned context channel, in
  the Ф0.1 wording, and land on the run marker as `risk_categories` / `assigned_roles`.
- **`bin/check-context-phrasing.sh`** — the "facts, never imperatives" rule becomes a gate. Imperative
  phrasing trips the prompt-injection defence, so the text is shown to the user instead of accepted.
- **`bin/check-role-triples.sh`** — a dispatchable role is complete (agent + both slug forms + playbook
  + registry row) or it is not shipped.
- **`bin/check-role-liveness.sh`** — P12 as a gate. It mutates the mutation eval: `--liveness` must
  FAIL on a profile with a provably dead binding, and the count `constitution.md` declares must match
  the count measured.
- **`references/role-registry.md`** — all 51 roles, their liveness status, and the reason for each
  that is not revived.
- **Two risk categories from the diff**: `no-tests` (non-doc work with no test file) and `licence`.
- **Constitution P12** — a role is alive only if an eval reddens when it is removed. Constitution
  1.0.1 → 1.1.0.
- **ADR-0021** (containment posture) and **ADR-0022** (native Task events stay observational).

### Changed

- **Context over the 10 000-character ceiling spills** to `.runs/<id>/context.txt` and the emission
  states the path, instead of being cut in silence.
- **An unavailable tier judgement is recorded** with a named cause (`no-model-cli`, `timeout-60s`,
  `unparseable-answer`, …) instead of leaving no trace. It writes no `tier=` line, so it is inert by
  construction. One transient timeout no longer disables judgement for the rest of the run.
- **`check-gate-integrity.sh` gains a third detector**: a gate that exits 0 on an unmet precondition
  without stating a reason. It found one real hole — an unreadable `delivery-lib.sh` made two hook
  bodies pass in silence.
- **`check-version-sync.sh` covers `README.md`** as a scan for claimed-current versions. This repo
  shipped 2.11.0 there against 2.34.0 in `VERSION` for twenty-three releases.
- **`SECURITY.md`** said "four Claude Code hook points"; there are eleven registered events and 39
  scripts. The table now lists each with what it does and which can block.
- **`references/speckit-preimpl-flow.md`** 214 → 119 lines; **builder playbooks** 522 → 309.
- **The 2.x changelog is archived** to [docs/changelog/v2.md](docs/changelog/v2.md).

### Fixed

- **The ≥1 independent-reviewer floor is asserted in code.** It had held by accident: every branch of
  the old hardcoded tier case happened to contain `code-reviewer`. Once the list became org-editable,
  a profile could have sized the anti-collapse floor away silently, on the strictest tier.
- **One tier→roles mapping instead of three.** `_roles_for` in `size-from-spec.sh` (self-described as
  a mirror), the `case` in `delivery-lib.sh`, and `_emit_ctx`/`_json_esc` in `delivery-marker-init.sh`
  — the last still truncating after `delivery-lib` had learned to spill.
- **A stale comment in `profiles/default.map`** claimed `perf` was unmapped, two screens above the
  line mapping it.
- **`roles-alive.test.sh`** reconstructed the category vocabulary by scraping source with `[a-z/]+`,
  a class with no hyphen, so `no-tests` was reported dead while being emitted correctly.
- The last two **SC2164** sites: a failed `cd` made two scripts evaluate the current directory
  instead of the one they were handed.

## [3.0.1] — 2026-08-26

Follow-ups from the v3.0.0 implementation audit. No behaviour changes — a doc, a comment, a registry
section, and a test that now tests something. Cut as a patch because **3.0.0 shipped the defect
below**: the tag was created before the audit ran, so anyone installing 3.0.0 gets the imperative
this release removes.

### Fixed

- **`commands/deliver.md` no longer instructs the model to read the run marker for its assignment.**
  Line 19 said, verbatim, "Read the verdict out of the run marker (`pipeline`, `tier_source`,
  `sizing`, `role_plan`)" — the exact obligation AC-6 was written to remove. Two more at lines 78 and
  145. All three are reference now; the verdict is already in the model's context on the
  `UserPromptSubmit` channel, and `.runs/<id>/RUN` holds the same fields for the gates.

  The assertion guarding this **passed for the whole milestone**. Its pattern,
  `read (the )?(run )?marker`, requires the words to be adjacent, and the real sentence has "the
  verdict out of" between them — a test whose pattern cannot match the line it was written to catch.
  It now carries a poisoned-fixture case proving it can fail.

- **`delivery-lib.sh`'s `record_required_roles` no longer documents a call site that was deleted.**
  Its comment read "Recorded at announce so the close gate reads a FACT" — precisely the practice
  AC-25 ended, because at announce the batch window is empty and the computed set collapses to
  `[code-reviewer]`. The call lives in `verify-batch.sh`; the comment now says so and says why.

### Added

- **`references/role-registry.md` → *Deferred — playbook volume*** records the AC-31 shortfall
  (2.9 % against a 30 % target) with the reason the number is not the governing rule — constitution
  P12 is stricter — and the condition for reopening it. Tracked deliberately: `specs/*/` is
  gitignored, so a debt recorded only in `plan.md` is invisible to whoever could clear it.

## [3.1.0] — 2026-08-27

Two defects observed on a live run (`176-withgauge-platform-integration`), both the same shape: **the
harness stated a weaker fact than the one it acted on.** Minor rather than patch — an unresolved tier
now buys a deeper review than it did, which is a behaviour change, though a strictly stricter one.

### Fixed

- **A degraded sizing is reported as `not computed`, never as `none`.** `size-from-spec.sh` returns
  `degraded=1 reason=no-tasks-md` — non-empty output and no classification at all. The marker treated
  any non-empty output as "the classifier ran", so a spec with no `tasks.md` produced *"Risk
  categories detected: none"*: a computed result that was never computed, told to the model about a
  diff nobody had classified. AC-1g fixed exactly this for the branch where the classifier is never
  consulted; the degraded branch walked straight through it.

- **An unresolved tier buys the STRICTEST review depth, not the shallowest.** The same marker said, in
  one breath, *"every tier-reading gate fails closed until Phase A resolves it"* and *"Review depth:
  low"* — telling the gates to enforce maximally and the model to review minimally.
  `review_depth_for_tier` answered `low` from its catch-all branch, which covered `single-thread`
  (legitimately light) together with `auto`, empty and unrecognised (not light — unknown).
  `single-thread` is now matched explicitly and everything unresolved answers `high`, the rule
  `tier_base_roles` has followed since 3.0.0.

- **One depth mapping, not two.** `delivery-marker-init.sh` carried its own copy, and it drifted the
  moment the library learned the stricter answer. v3.0.0's changelog claimed three copies of a mapping
  became one; there was a fourth, of a different mapping, and it went unfound until a live run showed
  the two disagreeing.

## [3.2.0] — 2026-08-27

Four defects found by **watching a real delivery run** (`176-withgauge-platform-integration`), none of
which any test had asked about. The root one explains the other three and explains why that run's
marker had been edited by hand.

### Fixed

- **A degraded sizing is recomputed when the artefacts arrive.** The marker is written once, on the
  first arm — and for a description-form run that moment is always *before* Phase A produces
  `tasks.md`, so the sizing degrades. Every later arm took the `[ -f "$marker" ]` branch, re-stated
  the stored context and exited, so the degraded verdict never recovered: the run stayed
  `pipeline=auto` for its whole life with a perfectly sizable `tasks.md` on disk beside it.

  That is why the observed run's marker had `pipeline`, `sizing_degraded` and `risk_categories`
  hand-written into it — the orchestrator was doing the harness's job because the harness had stopped
  doing it, while `tier_source` went on claiming `harness`.

  A re-arm now re-sizes a degraded run and says so, once. The scope is narrow: only degraded runs,
  only the fields the hook owns. New `splice_marker_fields` (atomic, JSON-validated) preserves
  `precond`, `preflight`, `repro_env`, the acks and `baseline_sha` — which is why the hook refused to
  rewrite an existing marker at all, and the reason the fix is a field-level splice rather than a
  rewrite. A run that sized successfully is left alone: re-deciding a settled tier every prompt would
  make the verdict a moving target for the gates that read it.

- **A declared role is validated against the roles that exist.** `⚠ <word>` was unioned into the
  required set unvalidated. The observed `tasks.md` carried, in its **conventions legend**,
  ``- `⚠ reviewer` where a review lens is load-bearing.`` — and the harness read the documentation
  *of* the notation as a *use* of it, assigning a role called `reviewer`: no playbook, no agent, no
  slug, nothing that could ever satisfy it. Under the enforce default that is a requirement with no
  action that meets it. Unknown words are now dropped and recorded as `declared-unknown:<word>`.

- **A task id wrapped in markdown emphasis counts as a task.** `- [ ] **T001**` did not match the
  counter, so the observed `tasks.md` reported 0 tasks of thirty-odd and the `tasks>=12` tier signal
  silently read zero.

- **`not computed` names which kind.** "The classifier was not consulted" and "the classifier ran and
  could not classify: `<reason>`" are different problems fixed in different places; they had collapsed
  into one sentence.

## [3.2.1] — 2026-08-27

Findings from auditing the code against the two founder docs (Д1 «Как оживить роли», Д2 «Харнесс:
бест-практис»), plus one defect the audit session then observed live in its own hook stream.

### Fixed

- **The red step names a script that exists.** `commands/deliver.md` still instructed
  `bin/tdd-red.sh`, deleted when its observation step moved into `bin/check-tdd.sh --record-red` —
  every code batch's P9 instruction pointed at nothing. The command now names the real entry point,
  and AC-29e pins the class: no command playbook may reference the deleted driver.

- **The pre-dispatch brief reaches every role.** The `SubagentStart` matcher covered
  `team-bootstrap:.*` plus the `-reviewer`/`-verifier`/`-guardian` suffix families — so when the host
  strips the plugin prefix (the documented failure `review-types.txt` keeps two slug forms for),
  `chaos-engineer`, `devops-platform`, `test-designer` and `legal-compliance-checker` matched nothing
  and silently lost their brief. The four bare slugs are explicit now; AC-11b pins the class for any
  agent added later.

- **A closed batch is a record, not an obligation.** `inflight_batch` falls back to the *last* ledger
  line when nothing is announced, and two consumers took the fallback at face value:
  `check-review-batch.sh` re-announced a closed batch's role gap as "still missing … fails closed at
  closure" on every PostToolBatch of every later session, and `session-context.sh` opened each
  session with the oxymoron "In-flight batch … (status=closed)". Both now treat only an `announced`
  batch as in flight (P6: a duty closure already discharged is not re-stated as pending).

### Added

- **`tests/hook-behaviour.test.sh`** — behaviour tests for the three hooks the spec-020 audit found
  wired but never exercised: `check-review-batch.sh` (a1–a6), `session-context.sh` (b1–b5),
  `guard-git.sh` (c1–c7). The suite also records the AC-43 divergence: the spec asked for a blocking
  PostToolBatch gate; the shipped inform-only contract is correct (blocking the fan-out pushes review
  inline — the spec-169 collapse), and a3 pins it so a well-meaning "fix" toward the spec's letter
  goes red instead of shipping.

## Earlier releases

Entries for majors that are no longer current are archived one file per major, so this file stays the size of the *live* series:

- [2.x](docs/changelog/v2.md)
- [1.x and earlier](docs/changelog/v1.md)
