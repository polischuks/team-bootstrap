# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.28.0] - 2026-08-20

> **pipeline-integrity-hardening** — closes the four confirmed bypass gaps the 2026-08-20 audit
> ([specs/pipeline-execution-integrity/findings.md](specs/pipeline-execution-integrity/findings.md) A–D)
> found in the *shipped* implementations of A–D. Hardening, not new capability: each already-shipped
> gate is made to actually hold on the path the audit walked. Landing batch-by-batch; WS-A first.

### Fixed
- **WS-A — the role/review gate is now anchored at RUN-CLOSE, not only at batch-close (ADR-0014).**
  The Stop hook (`bin/delivery-stop-hook.sh`) previously let a degraded `full`/`mvp` run that committed
  code *inline without announcing a batch* stop at exit 0 — no reviewer, user not told (the spec-169
  collapse surviving on the no-batch path). Now:
  - the direct-delivery `code-since-baseline` allowance is **refused for `full`/`mvp`** and, fail-closed,
    for an **absent/unrecognized `pipeline`** — only `single-thread` (no role fan-out) keeps it (AC-A1/A2/A5);
  - the Stop hook **independently asserts the ≥1 independent-reviewer floor** over closed `kind:code`
    batches via the shared `reviewer_dispatch_count` — a `full`/`mvp` run whose closed batch shows zero
    reviewer dispatch is blocked at run-close, not only inside `verify-batch` (AC-A3).
  - **Live posture (AC-A4):** the hard, live guarantee is **≥1 independent reviewer** (enforced under
    both `warn` and `enforce`). The per-role "all four" floor remains **staged in `warn`** pending the
    adoption probe (as ADR-0009 already discloses); no doc claims all four roles as live-enforced.
  - Retained honest limit: WS-A stays at the ADR-0006 marker/dispatch **forgeability ceiling** (a forged
    `status:closed` with `dispatch.jsonl` deleted is trusted) — the win is *harness-observed dispatch at
    run-close*, not tamper-proofing.
- **WS-C — the control-surface set no longer misses registered hook/gate bodies, and a dirty working tree
  can no longer neuter a gate unseen (ADR-0014).**
  - Added `bin/guard-git.sh`, `bin/quality-gate.sh`, `bin/delivery-stop-hook.sh`, `bin/delivery-marker-init.sh`
    to `references/control-surface.txt` — each is a registered hook or a `verify-batch` gate body, so a
    vacuity edit (`exit 0`) to any of them is now a declared, ack-required control-surface event, not a
    silent gate-disable (AC-C1).
  - `check-seam-ack` now fails closed on **uncommitted** modifications to any control-surface path in the
    working tree (`git status --porcelain -z -c core.quotepath=false` — NUL-delimited, unquoted, so a
    surface path with a space/non-ASCII name under a whole-tree entry isn't hidden by git's default quoting;
    both sides of a staged rename are checked), even when `git diff base..HEAD` is clean of them — closing the
    hole where a gate edited in place takes effect for the run (verify-batch executes the working tree) yet
    never appears in the committed window (AC-C2). Scoped to the control surface — a dirty feature file is
    unaffected (AC-C3).
  - **KNOWN GAP (AC-C4):** the two additions that are *hook* bodies (`delivery-stop-hook`,
    `delivery-marker-init`) are weaker than a `verify-batch` gate — a gutted hook body is caught only at the
    *next* batch close, which a tamperer who already neutered the Stop gate can avoid by never closing. And
    the circular core (`check-seam-ack`/`verify-batch`/`delivery-lib`/`control-surface.txt`) co-edited in one
    diff still escapes in-plugin. Both stay delegated to repo/org posture (CI-from-trusted-ref; sandbox-runtime).
- **WS-D — the commit/merge-on-default branch guard no longer fails open on three parse bypasses (ADR-0014).**
  `bin/guard-git.sh`:
  - **B1** — the env-assignment strip now also handles a **single-quoted** value with a space
    (`FOO='a b' git commit`), not only the double-quoted twin the finding-#1 fix covered (AC-D1).
  - **B2 / fail-closed posture (OQ-4)** — a git subcommand that is **not a recognized git subcommand** (an
    alias such as the `ci` from `git -c alias.ci=commit ci`, or an obfuscating token) is now blocked on the
    default branch under an armed run (AC-D2). Recognized non-commit/merge subcommands — reads *and*
    mutations like `tag`/`stash`/`rebase`, and the explicitly-not-gated `push`/`pull` — stay **fail-open**,
    keeping the false-positive rate low so the guard is never trained-away (R5, AC-D4). Only a *clean*
    bare-subcommand-shaped token fails closed; punctuation-carrying debris from the quote-blind segment
    split (e.g. a `status'` fragment out of `git log --grep 'x; git status'`) is treated as split debris and
    allowed, so a read with a shell metacharacter in a quoted arg never false-blocks on the default branch.
  - **B3** — `--git-dir` / `--work-tree` are now honored for target-repo resolution, so
    `git --git-dir=… --work-tree=… commit` is judged against the repo it actually writes to, not the guard's
    cwd (AC-D3).
  - **KNOWN GAP (AC-D6):** determined obfuscation (`eval "git commit"`, `$(which git) commit`, wrapper
    scripts, base64) remains uncaught — the guard stays best-effort git-parsing, not a security boundary;
    the hard backstop is remote branch-protection. The push-to-`main` half stays delegated (unchanged).
- **WS-B — preflight is now a readiness gate, not a scaffold linter (ADR-0014; founder-approved reopening of
  the ADR-0010 descope).** `bin/check-preflight.sh` adds three runtime probes, all HARD (ackable via a
  governed waiver):
  - **test-command presence (AC-B1)** — a code run whose `AGENTS.md`/`CLAUDE.md` declares no runnable
    `Test:` fails closed (it cannot be red-first-verified), read via the shared `_test_cmd`.
  - **toolchain/dependency presence (AC-B2)** — the `Test:` command's binary must resolve (PATH or file),
    and a present dependency lockfile must have its install dir (`node_modules`) — caught *before* Phase B,
    not reactively when `quality-gate` hits "command not found".
  - **operating-tree coherence (AC-B3)** — `baseline_sha` must resolve to a commit (now HARD, was WARN),
    and the run's own docs-contract (`spec/plan/tasks.md` under the marker's `feature`) must be present in
    the build tree (no split-brain).
  - **`_test_cmd` promoted into `delivery-lib.sh` (T040/AC-B1)** so `check-tdd` and `check-preflight` share
    one definition of the project's test command — the T0 the original descope skipped.
  - **Governed waiver replaces the bare preflight ack (AC-B5).** `delivery-lib`'s new reusable
    `governed_waiver_ok` (by/reason/unexpired-`expires`, darwin-portable `YYYY-MM-DD` string compare)
    now gates a failing preflight in `check-delivery`; a one-time `ack:true` no longer papers over a later
    independent readiness failure on the same run. `record_preflight` was widened to preserve the waiver
    fields across a re-run.
  - **`Prepare:` contract field (AC-B4)** — a network-permitted setup command declared in `AGENTS.md` and
    run by `/deliver` in Phase 0 *before* the pipeline fires, so deps are provisioned in a named phase
    (documented in `deliver.md` + `references/agents-md-contract.md`; this repo declares `Prepare: N/A`).
  - Scaffold-linter checks are **retained** (AC-B6 — git-repo/`feature.json`/constitution/`specs`/`adr`/
    run-marker gaps still fail closed).

## [2.26.0] - 2026-08-19

### Added
- **Control-surface protection — the gates cannot be silently disabled mid-run (`control-surface-protection`,
  ADR-0012).** `check-seam-ack` now treats the single-source glob set in
  [`references/control-surface.txt`](references/control-surface.txt) (read by
  [`bin/delivery-lib.sh`](bin/delivery-lib.sh) `control_surface_globs()`, BASH_SOURCE-relative like
  `review_types()`) as an **always-present high-risk seam**, unioned in **before** the "no high_risk_seams
  recorded" early return. A `kind:code` batch (or any batch inside an `intends_code` run) whose git window
  touches the plugin's own machinery — `bin/check-*.sh`, `bin/verify-batch.sh`, `bin/delivery-lib.sh`,
  `bin/tdd-red.sh`, `bin/record-dispatch.sh`, `hooks/*.json`, `.claude`, `.mcp.json`, `AGENTS.md`,
  `commands`, `agents`, or the list file itself — must record a `control-surface` seam-ack (naming the
  shipped commit + a `file:line` note) or the batch cannot close. Extends P10 non-disableability from the
  *delivered code* to the *machinery*. **No new gate** (consolidated into `check-seam-ack`; a parallel gate
  would duplicate its validation chain and re-glob-blind it). Dogfooded from this milestone's own Batch A.
- **CI-from-trusted-ref check, shipped as an EXAMPLE** ([`.github/control-surface-ci.sh`](.github/control-surface-ci.sh)
  + [`.github/workflows/control-surface-guard.yml`](.github/workflows/control-surface-guard.yml)) — on a PR,
  diffs control-surface files vs the trusted base and fails unless a commit carries a `Control-Surface-Ack:`
  trailer. **Recommended repo/org posture, NOT a plugin guarantee:** non-circular only under GitHub
  branch-protection (a same-repo PR runs its own workflow copy); the trailer is author-written → visibility
  + human review, not prevention. Uniform with `sandbox-runtime` immutability.

### Changed
- **`bin/check-seam-ack.sh` hardened** (correctness fixes to the shipped gate): (a) **glob-aware**
  `_intersects` — an explicit unquoted-`$token` `case` branch matches `bin/check-*.sh` / `hooks/*.json`
  (the shipped quoted matcher was glob-blind), iterated line-by-line so globs never pathname-expand against
  the CWD; both touch-detection and ack-validation route through it and cannot disagree; (b) **fail-closed**
  `_batch_files` — an empty/unresolvable git window no longer falls back to the ledger's self-declared
  `"files"` (a tamperer controls them). Inherited `--self-test` fixtures retargeted off the control surface
  so the standing seam does not retroactively regress them.

### Notes
- No constitution bump (stays 1.0.1): operationalizes P3/P6/P10/P11 as already written. Enumeration
  invariants unchanged (51 role playbooks / 6 pipelines); **no new gate script**. Honest limits recorded, not
  hidden: the self-reference circular core (`check-seam-ack`/`verify-batch`/`delivery-lib`/the list) is
  protected only under repo/org posture (CI-from-trusted-ref under branch-protection; `sandbox-runtime`), and
  the seam-ack is forgeable-honest (declared + reviewable, not impossible) — the same ceiling as
  `risk_rank`/`seam_acks`.

## [2.27.1] - 2026-08-19

### Fixed
- **`check-preflight` self-test hermeticity — the suite no longer goes red under an active delivery run.**
  [`bin/check-preflight.sh`](bin/check-preflight.sh)'s `--self-test` scaffolded a temp run marker named `r` but
  invoked the gate inheriting the caller's `TEAM_BOOTSTRAP_RUN`, so `resolve_marker` looked for the *outer*
  run's marker (absent in the scaffold) and spuriously reported "missing run marker" — making `bin/run-tests.sh`
  fail whenever run under an active `TEAM_BOOTSTRAP_RUN` (e.g. `verify-batch` → `check-tdd` → `run-tests`), i.e.
  a false `check-tdd` red mid-delivery. The self-test now runs the gate with `env -u TEAM_BOOTSTRAP_RUN` so
  marker resolution falls back to the scaffolded `.runs/*/RUN`; [tests/preflight-setup.test.sh](tests/preflight-setup.test.sh)
  also drops its exported run marker before the child self-test/E2E. No runtime behavior change (test-only).

## [2.27.0] - 2026-08-19

### Added
- **Reproducible-env posture — provenance fingerprint + posture doc (`repro-env-posture`, ADR-0013).** The
  capstone of the `pipeline-execution-integrity` program (the "documentation + posture" tier). A Claude Code
  plugin **cannot force** a container / restricted egress / managed settings (constitution P7); so this ships
  the two things in reach:
  - **An audit-only `repro_env` provenance stamp folded into the already-consumed
    [`bin/check-preconditions.sh`](bin/check-preconditions.sh)** (round-1 review: a standalone recorder would be
    *unconsumed*; fold it into a gate whose record is already read). On an armed `intends_code` run it records a
    flat `repro_env` array — `container:` (docker/podman/k8s/codespaces/devcontainer/none, from
    `/.dockerenv`/`/proc/1/cgroup`/env hints), `os:`/`bash:`/`git:`/`dirty:` provenance, and the honest
    non-observables `egress:unverified` + `sandbox:unknown` — via the shipped `record_marker_list`. It is
    **exit-preserving** (a pure addition; never changes `check-preconditions`' exit codes, never blocks) and
    **audit-only** (`check-delivery`/`verify-batch` never read it — a weak posture still closes clean, the
    fidelity default being the user's real repo). Container signals take injectable `REPRO_*` overrides;
    `TEAM_BOOTSTRAP_REPRO_ENV=off` disables the stamp. **No new `bin/` artifact.**
  - **A recommended-posture doc** — [references/repro-env-posture.md](references/repro-env-posture.md): the
    reference devcontainer + default-deny `init-firewall` egress allowlist + managed-settings floor
    (`failIfUnavailable` + allowlist + credential isolation) + the fire-all credential-exfil warning (incl. the
    no-TLS-termination/domain-fronting caveat) + the fidelity-vs-reproducibility tension — each carrying a "the
    plugin cannot force this — you/your org enable it" note. A [`.devcontainer/`](.devcontainer/devcontainer.json)
    example ships as adoptable repo config, not enforcement.
  - **Disclosed limits (P11):** `egress:unverified`/`sandbox:unknown` always (unobservable in jq-free bash);
    container detection is Linux-centric (macOS reports `none`). Dogfoods control-surface-protection (the
    `check-preconditions` edit recorded a `control-surface` seam-ack).

## [2.25.0] - 2026-08-19

### Added
- **Commit-on-default branch guard (`branch-protection-gate`, ADR-0011).** A new **blocking**
  `PreToolUse[Bash]` hook [`bin/guard-git.sh`](bin/guard-git.sh) that, on an armed `intends_code` run,
  refuses a `git commit`/`git merge` while HEAD is the **default branch** (`main`/`master`) — exit 2,
  "branch first" — so a delivery commit lands on a feature branch and the default branch is reached only via
  a human-authorized PR (hardens P5 at the harness; enforcement-only, no new constitution invariant).
  Registered on a `PreToolUse` `Bash`-tool matcher ([hooks/hooks.json](hooks/hooks.json)).
  - **JSON-decode extractor** (not the first-quote-truncating `field_str`): un-escapes `\" \\ \n \t \r \/`
    (leaves `\uXXXX` literal — a documented non-goal); splits segments on `&& || | ; ( )` **and newline** so a
    chained or multi-line `git commit` cannot slip; **subcommand-position** scan so a commit *message* or an
    `echo` that merely mentions the tokens never triggers a block.
  - **Total + fail-safe + kill-switch.** Anything unrecognized/undecodable/malformed-marker → exit 0 (never
    breaks the shell); `TEAM_BOOTSTRAP_DELIVERY_GATE=off` / `TEAM_BOOTSTRAP_GITGUARD=off` disable it.
    **Portable termination** — `timeout`/`gtimeout` wrap the branch-detection git calls only if present
    (else bare, since they are local + instant), so it still fires on a host without `timeout`.
  - **Disclosed limits (P11).** Best-effort git-parsing (catches the default/accidental invocation, not an
    obfuscated one); branch-detection falls back to `main`/`master` when `origin/HEAD` is unset — always in
    the safe direction. **`git push` / `gh pr merge` / `gh api` are NOT gated** (no false-pass-safe extraction
    of a chained push; a hollow in-turn ack) — remote-write authorization stays P5 prose + the
    `check-preconditions` advisory, and the hard backstop is the remote's **branch-protection** (required PR
    review). Doctrine: [references/irreversibility.md](references/irreversibility.md),
    [commands/deliver.md](commands/deliver.md).

## [2.23.0] - 2026-08-19

### Added
- **Setup-readiness layer — Phase 0 gate (`preflight-setup-phase`, ADR-0010).** A first-class
  [`bin/check-preflight.sh`](bin/check-preflight.sh) runs **before Phase A** and fails **closed** when a
  project is not scaffolded for the pre-implementation flow (constitution resolved via `feature.json`,
  `specs/`, parseable `feature.json`, `docs/adr/`, an armed run marker; `specs/TEMPLATE/`/`AGENTS.md`/
  unresolvable `baseline_sha` are warnings). Detect-and-report only (never creates scaffold); `jq`-free
  (portable). It records a blocking `preflight:{exit,gaps,ack}` verdict, and [`bin/check-delivery.sh`](bin/check-delivery.sh)
  blocks batch-announce for an `intends_code` run with a real `kind:code` batch while `preflight` is
  **absent** (gate never ran — P10 not-run), failing-and-unacked, or **present-but-unreadable**. Symmetric
  to the end-of-Phase-A `precond` deliverability gate; the two answer different questions ("can it *run*
  here?" vs "can it *land*?") and record different marker keys. Wired into the `/deliver` command as a
  Phase 0 step ([commands/deliver.md](commands/deliver.md)); doctrine in
  [references/preflight-setup.md](references/preflight-setup.md).

### Fixed
- **Marker self-disarm on a trailing object (write side).** `record_precond`'s greedy end-anchored strip
  only worked while `precond` was the marker's terminal field; once Phase 0 appends `preflight` after it,
  the end-of-Phase-A `check-preconditions` run would silently delete the trailing `preflight` on every
  normal run — the feature disarming itself with no error. Both marker writers now use a position-
  independent `_marker_strip_obj_key` (object analog of `_marker_strip_flat_key`), and both delivery
  clauses read via object-scoped `field_in_obj`, so `precond` and `preflight` can share `exit`/`ack`
  safely. `record_precond`/`record_preflight` are single-sourced in `delivery-lib.sh`.

### Notes
- No constitution bump (stays 1.0.1): the gate operationalizes P3/P6/P10/P11 as already written.
  Enumeration invariants unchanged (51 role playbooks / 6 pipelines). The non-ackable gap class proposed
  in the spec was **descoped** as unreachable at the enforcement layer (a non-git target fails
  `check-preflight` with no run to ack; a bad baseline is warn-only) — all `preflight` verdicts are ackable
  via `preflight.ack`.

## [2.22.0] - 2026-08-19

### Added
- **Per-role dispatch floor (`all-four-role-dispatch`, ADR-0009).** Raises the role-dispatch gate from ≥1
  reviewer dispatch (the exec-role-integrity total-collapse floor) to **every mandated review role dispatched**
  under its **own dedicated collision-free type** — `integration-verifier`, `architecture-reviewer`,
  `regression-guardian`, `tb-code-reviewer` (`agents/<role>.md`). `references/review-types.txt` gains an
  optional `<TAB>role` column; `delivery-lib.sh` gains `role_of_slug` / `roles_covered` / `mandated_roles` /
  `missing_roles` / `role_floor_mode`. `check-role-dispatch.sh` + `check-review-ack.sh` fail a `full`/`mvp`
  `kind:code` batch missing any mandated role (`full` = all four; `mvp` = `code-reviewer` +
  `regression-guardian`); the ≥1 total-collapse floor stays **hard under both modes**.
- **warn → enforce ramp, mechanically gated on the committed `references/role-dispatch-enforce` marker** (no
  version tripwire). Ships in **warn** (marker absent) — announces missing roles, does not fail — until a
  dispatch probe confirms four-distinct-slug adoption and the marker is committed (a governed, evidenced flip).
  Overrides: `TEAM_BOOTSTRAP_ROLE_FLOOR` (mode), `TEAM_BOOTSTRAP_ROLE_ENFORCE_MARKER` (path, tests only).

### Changed
- **Doctrine supersedes ADR-0008's "all four dispatch under `independent-reviewer`" mandate** — each role now
  dispatches under its own dedicated type (`references/{review-types.txt, subagent-dispatch.md, subagent-mapping.md,
  orchestrator.md, pipelines/full.md, pipelines/mvp.md}`); generics remain honored for the ≥1 floor during the
  warn ramp. Honest limit carried forward: per-role raises the **degradation** floor, not the **forgery** bar.
- **`check-delivery.sh` self-test robustness** — anchors its delta-bearing fixtures to the most recent non-doc
  commit reachable from HEAD (mirrors `_is_doc_path`), so a doc-final batch (a doc-only HEAD) no longer reads
  the `code_delta:1` fixtures as forged. Latent bug surfaced by delivering a doc batch.

## [2.21.0] - 2026-08-18

### Added
- **Role-execution layer — harness-verified reviewer dispatch (`exec-role-integrity`, ADR-0008).** A
  non-blocking `PreToolUse[Agent]` recorder ([`bin/record-dispatch.sh`](bin/record-dispatch.sh)) writes each
  reviewer-typed subagent dispatch (`subagent_type` ∈ [`references/review-types.txt`](references/review-types.txt),
  the single source) to `.runs/<run>/dispatch.jsonl`; a new `verify-batch` gate
  ([`bin/check-role-dispatch.sh`](bin/check-role-dispatch.sh)) **fails closed and announces to the user**
  when a `full`/`mvp` `kind:code` batch closes with **zero** reviewer-typed dispatches — the silent
  collapse of the multi-role pipeline to single-thread (spec-169). Signal keys off dispatch **occurrence**
  (no completion status: background dispatch yields `async_launched`, `SubagentStop` is flaky #27755).
- **Dedicated review type + doctrine.** New plugin agent [`agents/independent-reviewer.md`](agents/independent-reviewer.md);
  `full`/`mvp` mandate the four review roles (integration-verifier, architecture-reviewer, regression-guardian,
  code-reviewer) dispatch as subagents with the dedicated review type. Adds the missing `subagent-mapping`
  rows for integration-verifier + regression-guardian (previously orphaned to `general-purpose`,
  indistinguishable from a builder).
- **`check-review-ack` corroboration.** A `review_acks` entry is valid in `full`/`mvp` only when a
  reviewer-typed dispatch is recorded for that batch — the marker `reviewer` claim must be
  harness-corroborated, not a bare string (closes 0006's forgeable-marker residual for the dispatch
  dimension). New shared `delivery-lib` `reviewer_dispatch_count()` — one definition used by both the gate
  and the corroboration.

### Changed
- `verify-batch` gate list adds `role-dispatch` (after `review-ack`, before `delivery`).
- Docs: [`references/hooks.md`](references/hooks.md), [`references/enforcement.md`](references/enforcement.md),
  [`references/subagent-dispatch.md`](references/subagent-dispatch.md), `orchestrator.md`, `pipelines/{full,mvp}.md`.
- `bin/check-delivery.sh` AC-2 self-test fixture decoupled from HEAD size (synthesized doc-only commit).

### Hardening (post-review)
- **Fail-closed on undeterminable input.** An `intends_code` `kind:code` batch whose pipeline is neither
  `full`/`mvp` nor the sanctioned `single-thread` (a malformed marker) now **fails closed** in both
  `check-role-dispatch.sh` and `check-review-ack.sh`'s dispatch corroboration — previously it silently
  skipped (a fail-open against the fail-closed design).
- **Empty batch id is non-matchable.** `reviewer_dispatch_count` returns 0 for an empty `bid`, so a
  malformed ledger entry with no `id` can no longer be satisfied by an orphan `{"batch":""}` dispatch record.
- Disclosed the enforcement floor explicitly (ADR-0008, `pipelines/{full,mvp}.md`, `enforcement.md`): the
  gate verifies **≥1** reviewer-typed dispatch (the total-collapse signature), **not that all four roles
  dispatched**, and is **in-session only** (`.runs/` gitignored ⇒ no CI re-run). `head -c` bound on the
  recorder's stdin; `ADR-000Z` placeholder → `ADR-0008` across all files.

### Honest limit
- `subagent_type` is model-authored ⇒ the role-execution gate is **degradation-proof, not forgery-proof**
  (catches a total inline collapse, not a decoy review-typed no-op dispatch) and proves the reviewer was
  *dispatched*, not *completed* or *good* (ADR-0008, ADR-0006). No constitution bump (stays v1.0.1).

## [2.20.0] - 2026-08-18

### Added
- **Governed enforcement waiver (gate A, `check-enforcement.sh`).** `enforcement_ack` is now a dated,
  expiring, categorized waiver (`by`/`reason`/`expires`/`category`); category is derived (declared+resolvable
  tool forces `deferred`); a valid `host_structural` gap is exempt from every hard-require tier, a `deferred`
  gap is not. Stops the ack deprecating into a perpetual free pass (ADR-0007).
- **Disposition governance gate (gate B, `check-disposition.sh`).** A fired review finding of severity ≥
  MEDIUM cannot be self-dispositioned to non-blocking; a downgrade requires an independent, dated waiver
  (approver≠builder, current commit — a new commit voids it). Closes the "fired finding downgraded to a
  comment" failure.
- **Independent review-ack gate (gate C, `check-review-ack.sh`).** A `kind:code` batch cannot close without a
  recorded independent clean-context adversarial review (reviewer≠builder, context:clean, verdict:go, commit
  anchored); a credible refutation must link to a gate-B-governed MEDIUM+ finding. Reviewer independence is a
  clean-context subagent, cross-model is opt-in hardening (ADR-0006).
- team-bootstrap ships its own `AGENTS.md` (`Test:`/`TestGlobs:`); `bin/run-tests.sh` test runner.
- `reviewFindings`/`review_acks`/`review_refutations` schema branches on the reviewer roles; reviewer role
  version bumps (architecture-reviewer 1.1.0, code-reviewer 1.3.0, overengineering-reviewer 1.2.0).

### Changed
- `verify-batch` gate list adds `disposition` and `review-ack` (after `seam-ack`, before `delivery`); the
  stale `gate_results` stamp string now enumerates all gates.

## [2.19.1] - 2026-08-17

### Fixed

- **Gate B AC→test check strengthened — a bare comment no longer counts as a test (post-delivery review,
  B6).** `check-completeness.sh --final` accepted an `AC-N` token appearing *anywhere* in a test-path file,
  so a bare `# AC-1 AC-2` comment (or an AC listed in a header block with no test) satisfied the
  "every AC referenced by a test" gate — reference, not assertion. An `AC-N` now counts only when it appears
  within **±3 lines of a test/assertion construct** (`assert`, `expect(`, `def test`, `@Test`, `it(`,
  `EXPECT_`, … — polyglot default, overridable via the new **`AcTestPattern:`** AGENTS.md field). Bias stays
  lenient on weak signals (co-location, not parsing) — only the genuine hole (an AC with *no* test construct
  anywhere near it) blocks. Regression-locked (`check-completeness --self-test`: ACs asserted near a
  construct → pass; the same ACs in a bare comment → fail; `AcTestPattern`/`AcPattern` overrides exercised).

## [2.19.0] - 2026-08-17

### Fixed

- **Gate C seam-ack anchor strengthened (post-delivery review, B5).** `check-seam-ack.sh` accepted any
  **resolvable** commit as the ack — so acking with a resolvable-but-unrelated commit (e.g. the run
  baseline, which never touched the seam) passed, making "read it in the shipped code" a recorded gesture
  rather than an anchor to the actual change. The ack commit must now be **reachable from HEAD**,
  **post-baseline**, and have **actually changed the seam's paths** (`git show --name-only` intersects
  the seam). Regression-locked (`check-seam-ack --self-test`: ack=baseline → fail; ack=non-seam-touching
  post-baseline commit → fail; ack=the seam-touching commit → pass).

### Added

- **Closure-fidelity gates — closure certifies fidelity + non-vacuousness, not just "tests green."** A
  retrospective found a HIGH bug (a CAS predicate `IN (owed-set)` vs candidates `= 'done'` → 0 rows → an
  infinite loop) that passed every gate: P9 red-first, F2 diff-coverage, and F3 mutation all **silently
  skipped** because the project declared no `Test:`/`Coverage:`/`Mutation:` — the bug slipped through
  gates that were *off*, not *absent* (the v2.18.1 self-disarm class). Three new `verify-batch` gates,
  each marker-gated ⇒ in-session, git/artifact-grounded, `--self-test`, `shellcheck` clean, never a false
  block on a non-delivery session:
  - **A — `bin/check-enforcement.sh`.** Records which quality dimension is unenforceable
    (`enforcement_gaps` in the RUN marker: `red-first`/`diff-coverage`/`mutation`) and **blocks a code
    batch from closing** until `enforcement_ack:true`. A `run-rate|irreversible` batch hard-fails on any
    gap regardless of the ack. The silent skip becomes a logged, dated decision (parity with precond-ack).
  - **B — `bin/check-completeness.sh`.** Per batch, every `task_id` in the ledger entry must be `[x]` in
    `specs/<slug>/tasks.md`; `--final` (invoked by `deliver.md` at finalization) requires no `[ ]` left
    and every `AC-N` in `spec.md` referenced by ≥1 test-path file (`AcPattern:` configurable). Reads
    `tasks.md`, never writes it.
  - **C — `bin/check-seam-ack.sh`.** The architecture review records its highest-risk seams
    (`high_risk_seams:[{seam,paths}]`); a batch whose files intersect a flagged seam's paths must carry a
    `seam_acks` entry naming the seam + a resolvable commit (a recorded "read it in the shipped code").
  - Wired A, B(per-batch), C into `bin/verify-batch.sh`; B `--final` into `commands/deliver.md`
    finalization. `architecture-reviewer` soundness handoff gains `high_risk_seams`. New marker fields
    documented in `references/agents-md-contract.md`; enforcement layer in `references/enforcement.md`;
    ADR-0005. Constitution unchanged (1.0.1) — the gates operationalize P6/P9/P10/P3/P11.
  - Dogfooded on itself: A flagged this bash-gate repo's three gaps (acked, feature-rank); B verified each
    batch's own `task_ids` and the milestone's AC→test coverage; C required (and got) a `seam_acks` entry
    on the batch that touched the recorded `marker-rewrite` seam.

### Fixed

- **`delivery-lib.sh` marker-list rewrite leaked a literal backslash (bash 5.2).** Building gate A's
  `record_marker_list`/`_marker_strip_flat_key`, a `${var//pat/rep}` normalization with escaped
  `\{`/`\}` replacements inserted literal backslashes into the RUN marker when replacing a key that
  followed a nested array (`high_risk_seams`) — corrupting the marker and disarming every fail-closed gate
  (the exact v2.18.1 class, on the very seam gate C guards). Replaced the substitution with version-stable
  single-char prefix/suffix surgery; regression-locked as case R6 in `check-enforcement --self-test`.

## [2.18.1] - 2026-08-14

### Fixed

- **Whitespace-fragile marker parser silently disabled fail-closed (critical).** `delivery-lib.sh`'s
  `field_str`/`field_num`/`field_bool` matched `"key":value` with **no space after the colon**. A RUN
  marker written with `": "` (e.g. `python json.dumps`' default) parsed as **empty** → `intends_code`
  read false → `check-tdd`, `check-delivery` (fail-closed), `check-version-sync`, `check-diff-coverage`,
  `check-mutation` all **silently skipped**, turning the guard off with no error. Added `[[:space:]]*`
  after the colon in all extractors (and `shas_of_line`), so compact **and** spaced markers parse.
  Regression-locked in `check-delivery --self-test` (spaced marker → still fail-closed).
- **`commit_shas` included the test-only RED commit (and pre-baseline commits), breaking closure.**
  `verify-batch` stamped `git log current_batch_base..HEAD` verbatim, and `current_batch_base` fell back
  to `origin/main` without consulting the RUN marker's `baseline_sha`. So (a) the TDD red commit became
  the **oldest** `commit_sha` — which `check-tdd` uses as the batch's code-anchor, and `red_sha` cannot
  be a proper ancestor of itself → **post-closure FAIL**; and (b) pre-baseline commits leaked in, which
  `check-delivery`'s predate check flagged as forged. Fixed both: `current_batch_base` uses the marker's
  `baseline_sha` for the first batch, and `verify-batch` excludes recorded `red_sha` commits from
  `commit_shas` (impl-only). Regression-locked in a new `verify-batch --self-test`.

## [2.18.0] - 2026-08-14

### Added

- **Version-sync gate — manifests cannot drift.** The plugin's version lives in four places that must
  agree (`VERSION`, `.claude-plugin/plugin.json` `version`, `marketplace.json` `metadata.version` +
  each `plugins[].version`). A release that bumps one and forgets the others is silent and
  outward-facing — the plugin self-reports the old version and `claude plugin update` offers nothing.
  This framework shipped that drift **twice** (`v2.12.1`, `v2.17.0`). Now
  [`bin/check-version-sync.sh`](bin/check-version-sync.sh) (a `verify-batch` gate) collects every
  declared version field and **fails when they disagree**, naming each location and the plurality value
  (no auto-fix — the human bumps). Default plugin set, else AGENTS.md `VersionFiles:`
  ([agents-md-contract.md](references/agents-md-contract.md)), else skip+WARN (never a false block).
  Marker-gated ⇒ in-session; jq-free. Wired into [`verify-batch.sh`](bin/verify-batch.sh);
  `--self-test` 7 cases; `shellcheck` clean. See [ADR-0004](docs/adr/0004-version-sync-gate.md),
  [enforcement.md](references/enforcement.md). Delivered via `/deliver` (B1 code, B2 doc); the gate
  dogfooded this milestone — B2's bump to 2.18.0 closed only because all four fields agree. No
  constitution bump.

## [2.17.0] - 2026-08-13

### Added

- **Three test-quality `verify-batch` gates — the floor, not the ceiling.** v2.15/2.16 made "a test was
  written and seen to fail" a git fact; these raise what the harness guarantees about the tests themselves,
  each marker-gated (in-session), git-grounded, declared by an AGENTS.md command, and **skip+warn when the
  project declares no tooling** (never a false block). See [ADR-0003](docs/adr/0003-test-quality-gates.md),
  [enforcement.md](references/enforcement.md), [tdd.md](references/tdd.md),
  [agents-md-contract.md](references/agents-md-contract.md).
  - **F1 red-touches-tests** — [`bin/tdd-red.sh`](bin/tdd-red.sh) refuses a red whose committed change
    since baseline touched **no** test-path file (rejects `--allow-empty` and non-test-only reds; exit 4),
    and [`bin/check-tdd.sh`](bin/check-tdd.sh) requires each code batch's red window
    `<prev-code-tip‖baseline>..red_sha` to change ≥1 test path. Test-path set = a default glob set ∪
    AGENTS.md `TestGlobs:` (extends, never shrinks; inline-test layouts widen it to their source globs).
    Commit the failing test **before** recording red — that commit is the `red_sha`.
  - **F2 diff-coverage** — new [`bin/check-diff-coverage.sh`](bin/check-diff-coverage.sh): the batch's
    changed non-doc lines must be covered ≥ `CoverageThreshold:` (default 80), parsed from the project's
    **LCOV** over the same `current_batch_base` window the `code_delta` stamp uses (shared definition —
    `stamp_batch_closed` refactored to call it, so F2 and the stamp cannot drift). `measured=0` with
    changed lines WARNs loudly (not a silent pass); separator-anchored `SF:` path match.
  - **F3 mutation** — new [`bin/check-mutation.sh`](bin/check-mutation.sh): mutate the changed code, require
    score ≥ `MutationThreshold:` (default 60). **Opt-in/advisory by default**; enforces only under
    `MutationMode: enforce`. Parses a normalized `mutation_score:`/`killed:total:` line (adapters for
    Stryker/mutmut/PIT/cargo-mutants are docs, not per-tool parsers); `total:0` passes (no divide-by-zero).
  - New AGENTS.md contract fields: `TestGlobs`, `Coverage`, `CoverageFile`, `CoverageThreshold`,
    `Mutation`, `MutationThreshold`, `MutationMode`. Shared helpers `is_test_path`, `read_test_globs`,
    `window_touches_test`, `current_batch_base`, `changed_nondoc_lines` in
    [`bin/delivery-lib.sh`](bin/delivery-lib.sh). F2/F3 wired into [`bin/verify-batch.sh`](bin/verify-batch.sh).
    Each new/changed script ships `--self-test`; `shellcheck --severity=error bin/*.sh` clean; existing
    gate self-tests unregressed. Delivered via `/deliver` (batches B1–B4). No constitution bump.

### Fixed

- **F2 partial-coverage vacuous pass (post-delivery review, batch B5).** A review probe found
  `check-diff-coverage.sh` computed `covered ÷ measured`, not `covered ÷ changed`: when the `Coverage:`
  command was **not** cover-all and omitted some changed lines, those lines silently dropped from the
  denominator and the gate reported a confident "100% OK" over the measured subset — a silent vacuous pass
  (it only warned when *zero* lines were measured, not when *some* were). Now a partial report emits a
  **loud WARN** naming the unmeasured lines by default, and the new `CoverageStrict: true` counts unmeasured
  changed lines as misses (denominator = all changed non-doc lines) so a non-cover-all report **fails**.
  Self-test extended (partial→WARN, partial+strict→fail).

## [2.16.0] - 2026-08-13

### Changed

- **The TDD red gate is now per-batch.** v2.15.0 required one observed red *anywhere* on the run — a
  multi-batch run could satisfy it with a single red step. [`bin/check-tdd.sh`](bin/check-tdd.sh) now
  requires **each** `kind:code` batch to have its own red record (`tdd-red.sh --batch <id>`) whose
  `red_sha` is a **descendant of the run baseline and a proper ancestor of that batch's own commits**,
  with **one red record crediting at most one batch** — so `baseline < red₁ < code₁`, `code₁ < red₂ <
  code₂`, … Every code batch is red-first in its own window; you cannot cover B2 with B1's red. A direct
  pipeline run (no ledger) keeps the single run-level red. `check-tdd --self-test` 5 cases (incl.
  red-reuse rejection); `shellcheck` clean; [deliver.md](commands/deliver.md), [tdd.md](references/tdd.md),
  [enforcement.md](references/enforcement.md) updated.

## [2.15.0] - 2026-08-13

### Added

- **P9's red step is now harness-enforced, not a self-declared boolean.** P9 mandates "tests written
  first, run and *seen to fail*," but nothing checked it: `tests_failed_first` was an optional boolean the
  schema never required and no gate read — an agent could write code, add rubber-stamp tests (or none), and
  still report `completed`. Closed with a git-grounded red→green gate:
  - **[`bin/tdd-red.sh`](bin/tdd-red.sh)** (run at the red step) runs the project's AGENTS.md `Test:`
    command, **requires** a non-zero (red) result — it refuses to record a green suite — and stamps the
    observed red (`red_sha` = HEAD) into `.runs/<run>/tdd.jsonl`. The record exists only because the tests
    actually ran red; prose cannot fabricate it.
  - **[`bin/check-tdd.sh`](bin/check-tdd.sh)** (a `verify-batch` gate) fails a code-shipping armed run unless
    a red record exists whose `red_sha` is a **descendant of the run baseline and a proper ancestor of HEAD**
    (red observed on this run's work, before the code) **and** the suite is **green at HEAD** now. No red
    record → fail-closed: the red step was skipped.
  - Honest reach: enforces that a genuine red→green happened, on a project that declares a runnable `Test:`
    command (none → warns, unenforceable); does **not** judge whether the test asserts the *right* behavior
    (that stays with `qa-test-engineer`/review); marker-gated ⇒ in-session. `check-tdd --self-test` 5 cases;
    `shellcheck` clean.

### Changed

- **P9 clarified** to name its enforcement (constitution **1.0.0 → 1.0.1**, PATCH — the invariant is
  unchanged, now actually enforced). The `tests_failed_first` schema field is re-described: the git-anchored
  red record is the enforcement, not the boolean.

## [2.14.0] - 2026-08-13

### Changed

- **The delivery guard now fires across *all* code pipelines, not just `/deliver`.** Previously the
  `UserPromptSubmit` hook armed the run marker only on a `/deliver` invocation, so a direct
  `/team-bootstrap:team-bootstrap single-thread|mvp|full …` run (which `deliver.md` recommends for small
  changes) escaped the guard entirely — no marker, no gates. Closed:
  - **[`bin/delivery-marker-init.sh`](bin/delivery-marker-init.sh)** arms on any team-bootstrap
    code-pipeline invocation — the `/deliver` command *or* a direct `/team-bootstrap:` pipeline run — and
    recognizes `single-thread` alongside `mvp`/`full`. Analysis pipelines (`audit`/`audit-dd`/`l2p`) ship
    no code and never arm.
  - **Delivery is now satisfied two git-grounded ways** ([`bin/delivery-lib.sh`](bin/delivery-lib.sh),
    `code_since_baseline`): a `verify-batch`-stamped ledger closure (the `/deliver` path) **or** real
    non-doc code committed since `baseline_sha`, reachable from HEAD (the direct-pipeline path, which
    writes no ledger). Neither is forgeable by prose. `check-delivery.sh` and `delivery-stop-hook.sh`
    accept either; an armed run with **neither** is fail-closed — it ran a pipeline and shipped nothing.
  - Self-tests extended: `check-delivery --self-test` 14 cases, `delivery-stop-hook --self-test` 5 cases;
    `shellcheck --severity=error` clean; [enforcement.md](references/enforcement.md) updated.

## [2.13.0] - 2026-08-13

### Added

- **Advisory pipeline selector — [`bin/select-pipeline.sh`](bin/select-pipeline.sh).** Pipeline choice
  (`single-thread` / `mvp` / `full`) is the one high-leverage decision the delivery gate leaves entirely
  to the operator — and the same "just ship it" pressure that skips review also picks the *lighter*
  pipeline. Nothing else in the flow catches an under-sized choice; this does. It sizes the change's diff
  (file count, non-doc lines, distinct top-level layers) and scans for **risk touches** — security/auth,
  data/schema/migrations, infra/deploy, public API/contract, dependency manifests — where any single risk
  touch lifts the recommendation to `full` (the sanctioned multi-role + audit-trail tier, P1). With
  `--chosen <pipeline>` it exits **2** when the choice is *lighter* than recommended (e.g. `single-thread`
  on a change that touches auth across layers → recommends `full`). It is a **visible nudge, not a block**
  — the operator still decides (constitution P1); a hard gate here would only relocate the same soft call.
  Wired into `/deliver`'s Phase-A gate as an advisory. Counts untracked files (which `git diff` omits) and
  ships `--self-test` (11 cases); `shellcheck --severity=error` clean.

## [2.12.2] - 2026-08-12

### Fixed

- **Plugin packaging — the plugin now installs through the standard `/plugin` flow (and its hooks
  register).** v2.12.1 shipped the delivery gate, but the repository was not a valid, installable
  plugin/marketplace, so `/plugin install` failed with a generic error and the hooks never loaded.
  Verified end-to-end with the Claude Code CLI (`claude plugin validate` passes; `claude plugin
  install` succeeds; the `UserPromptSubmit`/`Stop` hooks fire in a CLI session):
  - Added [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) — the repo is now its
    own marketplace (`/plugin marketplace add polischuks/team-bootstrap`).
  - Corrected [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) to the documented manifest
    schema: `author` is an object (was a string), and the invalid `skills` array was removed (the
    root `SKILL.md` auto-loads). Wrong-typed fields are load errors, which blocked install.
  - Plugin `source` clones over **HTTPS** (`url`) instead of `github`/SSH. The `github` source
    resolved to an SSH clone that failed host-key verification (`No ED25519 host key is known for
    github.com … Host key verification failed`) on machines without github.com SSH configured — the
    actual cause of the "Plugin couldn't be installed" error.
  - Rewrote [INSTALL.md](INSTALL.md) with the correct, hook-registering install methods (marketplace /
    skills-directory / `--plugin-dir`, plus the non-interactive `claude plugin …` subcommands) and a
    note that some embedded surfaces load skills/commands but do not execute plugin hooks.

## [2.12.1] - 2026-08-12

### Fixed

- **Post-review hardening of the delivery gate (R-1–R-3, N-1)** ([bin/check-delivery.sh](bin/check-delivery.sh),
  [bin/delivery-marker-init.sh](bin/delivery-marker-init.sh)). An execution-grounded review of 2.12.0 confirmed
  the headline fixes but found closure could still be earned by non-run commits and that success reporting
  overstated what actually ran. Landed as batches B6–B7 (both git-verified):
  - **R-2 reachable-from-HEAD binding** — each cited `commit_sha` must now be reachable from `HEAD`
    (`git merge-base --is-ancestor <sha> HEAD`), so a sibling/discarded/cherry-pick-source commit no longer
    earns closure. This is the primary "earned by *this* run's commits" guarantee, independent of `baseline_sha`.
  - **R-1 honest reporting** — the success line distinguishes `GIT-VERIFIED` (active marker: F-2 + fail-closed
    enforced) from a `WEAK` marker-less check where those protections are off, instead of labelling both "git-verified" (P6).
  - **R-3** — `delivery-marker-init.sh` omits `baseline_sha` rather than writing a bogus `"unknown"`;
    `check-delivery.sh` warns when an active baseline does not resolve (including when absent).
  - **N-1 class fix** — the success line now **enumerates every anchor's real state**
    (`marker`/`reuse`/`reachability`/`predate`/`fail-closed` = `ON`/`OFF`), so `GIT-VERIFIED` is definitionally
    incapable of claiming more than actually ran. The "protection silently off when its input is absent"
    pattern (F-B, R-1, N-1) now surfaces as an `=OFF` token rather than a silent pass.
  - `check-delivery.sh --self-test` now 13/13; `delivery-stop-hook --self-test` 3/3; shellcheck clean;
    historical ledger still passes.

## [2.12.0] - 2026-08-12

### Added

- **Delivery gate: unforgeable, self-starting, fail-closed (F-A–F-E)** ([references/enforcement.md](references/enforcement.md),
  [docs/adr/0002-closure-from-git-state.md](docs/adr/0002-closure-from-git-state.md)). A running review of
  v2.11.0's mechanism (not its commit names) found the delivery-occurred layer did not yet achieve its own
  goal: closure had moved from prose to a **forgeable JSON line**, the gate **failed open** when no ledger
  existed, and no hook invoked it. This milestone closes that:
  - **`bin/delivery-lib.sh`** (new) — one shared definition of ledger/marker resolution, SHA resolution,
    the `risk_rank` enum, and `nondoc_delta_of_shas` (the non-doc code delta). `check-delivery.sh`
    recomputes with it; `verify-batch.sh` stamps with it — so stamp == recompute by construction.
  - **F-A unforgeable closure** — `check-delivery.sh` `git rev-parse`s every `commit_sha` (missing →
    fail), recomputes the non-doc delta and fails if the stamped `code_delta` **exceeds** it, and (under
    an active run) **binds commits to one batch** (no cross-batch reuse; must post-date `baseline_sha`).
    A hand-written `closed` line citing `deadbeef` or an inflated delta now fails.
  - **F-B self-starting + fail-closed** — a harness `UserPromptSubmit` hook
    (**`bin/delivery-marker-init.sh`**, new) writes `.runs/<run>/RUN` on `/deliver`, so "delivery active"
    is a machine fact the harness owns; under that marker, no ledger or zero closed `kind:code` → **exit 1**.
    No marker keeps the exit-0 skip (non-delivery sessions are not nagged).
  - **F-C delivery-aware Stop hook** (**`bin/delivery-stop-hook.sh`**, new) — blocks completion (exit 2)
    while a marked run has code work announced-but-unclosed; no-op without a marker. On `Stop` only (not
    `SubagentStop`, which would deadlock batch-closing subagents).
  - **F-D recorded, blocking deliverability ack** — `check-preconditions.sh` records an exit-2 advisory
    into the marker; `check-delivery.sh` blocks Phase B until `precond.ack:true`.
  - **F-E declared `risk_rank`** — `check-delivery.sh` rejects a higher-rank `kind:code` batch closing
    after a lower-rank one (order by load-bearing risk, bleeding-stopper first).
  - Disable the delivery hooks for a session with `TEAM_BOOTSTRAP_DELIVERY_GATE=off`. The historical
    `deliver-delivery-guard` ledger still passes unchanged (regression-pinned). Honesty of `risk_rank`
    and `precond.ack` is out of scope (enum/flag-constrained + logged, not proven).

## [2.11.0] - 2026-08-12

### Added

- **Delivery-occurred enforcement — closure-by-artifact (P0–P2)** ([references/enforcement.md](references/enforcement.md)).
  Addresses the failure a retrospective on real `/deliver` output surfaced: the existing gates enforce
  that delivered *code is clean* (orphans / drift / green-by-skip / typecheck-lint), but **nothing
  enforced that delivery happened**. A batch declared "closed" in prose while no pipeline ran and no
  code changed passes every code-quality gate — nothing to typecheck, no orphan, no drift — so "closed"
  stayed a claim; six doc commits and zero shipped code could be reported as a closed batch. Now closure
  is a machine fact:
  - **`bin/check-delivery.sh`** — a fail-closed gate over the run ledger (`.runs/<run>/batches.jsonl`):
    a `kind:code` batch announced but never closed, or closed with `code_delta = 0`, fails the run.
    `kind:doc` batches earn no delivery credit. Graceful no-op when no ledger exists.
  - **`bin/verify-batch.sh`** — on a passing batch it **stamps** the in-flight ledger entry
    `status:closed` with `commit_shas` + a per-batch `code_delta` (computed since the previous closed
    batch, over non-doc files). Only the script — never the orchestrator's prose — can flip a batch to
    closed. Added as the fifth gate inside the same script CI runs.
  - **First batch must be code (P2)** — a run that delivers any code must open with the load-bearing
    code, not the document explaining it; `check-delivery` rejects a run whose first batch is `kind:doc`
    while code batches wait behind it (a docs-only run is left alone). The "B1 ≠ doctrine" rule.
  Honest reach: `.runs/` is gitignored, so this layer is non-bypassable **in-session** and reproduces in
  CI only when a run commits its ledger; the code-clean layers remain non-bypassable in CI regardless.
  Shifts evidence-not-assertion into *delivery*, not just code quality
  ([Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).

- **Deliverability-precondition gate in Phase A (P1)** ([bin/check-preconditions.sh](bin/check-preconditions.sh)).
  The ten-second `git ls-remote` that belongs at the plan, not after the files are written. Phase A can
  produce a perfect spec/plan/tasks against a delivery path that dead-ends at a wall — a remote that
  isn't reachable, a branch the build-from-git deploy never sees, a publication step needing an
  authorization nobody asked for. Run at the end of Phase A, it checks remote reachability, whether the
  current branch is on the remote / diverges, detects a build-from-git deploy source (Railway / Render /
  Fly / Vercel / Netlify / Heroku / GH Actions) and flags push/publication as irreversible. Exit 1 (hard)
  stops; exit 2 (advisory) must be surfaced and acknowledged before Phase B. Wired into `/deliver` Phase A
  and cross-referenced from [references/irreversibility.md](references/irreversibility.md).

### Changed

- **`/deliver` closes batches by the ledger, not by assertion** ([commands/deliver.md](commands/deliver.md)).
  Announce writes the announced ledger entry; step 6 **reads** closure from the ledger (a batch is closed
  only if its entry says so). New batch-ordering rule: order by load-bearing risk, not ease of writing —
  doc-only batches go last and earn no delivery credit.
- **`failure-policy` — delivery-command policy (P3)** ([references/failure-policy.md](references/failure-policy.md)).
  A confirmation to deliver ("fire") requires a pipeline run that produces code, not another round of
  analysis or review; the enforced signal is a stamped `code_delta > 0`, not prose.
- **`best-practices-research` — pull briefs per-batch (P4)** ([references/best-practices-research.md](references/best-practices-research.md)).
  A fifth cost-control move: produce a domain's brief when the first batch touching it fires, not all
  briefs up front. Front-loading 100% of analysis before 0% of delivery is the failure this avoids; a
  cached brief costs nothing extra, it just moves next to the code it serves.

## [2.10.0] - 2026-08-10

### Added

- **Grounding to mechanism, not name (P11)** ([references/grounding-to-mechanism.md](references/grounding-to-mechanism.md)).
  Addresses the dominant *avoidable* failure surfaced by a retrospective on real `/deliver` output:
  agents inferring a capability from a name that sounds right and stopping at the first hop
  (`enumerate_active_*` read as "activity" when the meaning lived four hops away in a SECDEF SQL
  predicate; a `reason` token read as granting access when the SECDEF function did; a "mirror" assumed
  to include a validator it didn't — the same mistake made twice, the second inside the fix for the
  first, while `AGENTS.md > ## Known Hazards` warned in plain text). The rule: any "X already handles
  this" traces to the **terminal definition** (SQL / validator / CHECK / guard) at `file:line`, never
  to the name; read the surface's Known Hazards/Invariants before implementing; a mitigation is
  verified by **exercising** it, not by prose; `plan.md` is the single source of truth `tasks.md`
  derives from. New rules on `cto-architect` (design), `backend-engineer` (implement), and
  `code-reviewer` ("read three hops deeper" — verify claims against the mechanism). Constitution P11.
  This is evidence-not-assertion shifted **left** into reasoning about existing code — where the
  post-implementation gates don't reach. Grounded in source-driven-development and ground-truth from
  the environment ([Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).

## [2.9.0] - 2026-08-08

### Added

- **Harness-enforced gates (fix for skipped review / dead code in `/deliver`)**
  ([references/enforcement.md](references/enforcement.md)). The reviewer roles are prose an LLM
  orchestrator can skip (~70% adherence); an audit of real `/deliver` output confirmed batches
  shipping dead code and unreviewed diffs because the roles simply didn't run. Enforcement of the
  **outcomes** now moves onto the harness:
  - **`bin/verify-batch.sh`** — one batch gate that runs orphans (dead code / not-wired) +
    architecture drift + gate-integrity + typecheck/lint. Run at each batch close **and in CI**.
  - **CI backstop** — a `verify.yml` template so the same gate runs on every PR; a batch that
    skipped the roles locally is blocked at merge (the layer the orchestrator can't talk past).
  - **Strict opt-in** — register `verify-batch.sh` on the Stop/SubagentStop hook to block
    in-session completion (not on by default — heuristic checks would block WIP pauses).
  Grounded in [Claude Code hooks](https://code.claude.com/docs/en/hooks) (deterministic enforcement),
  [The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification), and
  [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents).

### Changed

- **`code-reviewer` added to `mvp` and `single-thread`** (was `full`/`audit` only) — no pipeline
  ships unreviewed. `/deliver` reviews every batch regardless of pipeline.
- **`single-thread` runs the same enforcement flow** — its Verify phase now runs `verify-batch.sh`
  as a hard machine backstop (orphans + drift + gate-integrity + typecheck/lint) and mandates
  `code-reviewer`, with the same CI backstop as `mvp`/`full`. Uniform verification across every
  pipeline, enforced by the harness, not prose.

## [2.8.0] - 2026-08-01

### Added

- **Best-practices research before implementation** ([references/best-practices-research.md](references/best-practices-research.md)).
  Before building in a domain, its current best practices land on the blackboard as a distilled,
  cited **brief**. Right-sized to stay cheap: **per domain, not per task** (reused across the domain's
  tasks), **novelty-gated** (only unfamiliar/risky domains; skips are logged), `tavily-research`
  (~10× cheaper than manual triangulation), and distilled (raw pages stay isolated). Cost envelope
  ~15–45K tokens per milestone. `discovery-research` extended to emit the brief and added to `mvp`;
  `backend-engineer`/`frontend-engineer` must cite the brief (contradicting it without a reason is a
  review finding); wired into `/deliver` Phase A, `single-thread` planning, and a subagent-dispatch
  trigger. Grounds source-driven-development at the *domain* level, distilled per
  [context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).

## [2.7.0] - 2026-07-21

### Changed

- **`/deliver` default pipeline is now `full`** (was `mvp`). Omitting the pipeline word runs the
  full role coverage + audit trail; pass `mvp` explicitly for the lighter pipeline.

## [2.6.0] - 2026-07-21

### Changed

- **Uniform verification across all pipelines (P10).** The reliability gates (`integration-verifier`,
  `architecture-reviewer`, `regression-guardian` + orphan/architecture/gate-integrity machine checks +
  capability conformance) are now **mandatory in `single-thread` too**, run as clean-context subagents
  in its Verify phase — not risk-gated. single-thread is lightweight in *orchestration* (one session
  builds), never in *verification*: skimping gates on the default pipeline is the false economy that
  produces "done but not real" and forces a costlier re-audit. The three gate roles gain
  `single-thread` in `compatible_pipelines`; the "when to use" guidance now frames the choice as
  orchestration/audit-trail, not verification rigor.

## [2.5.0] - 2026-07-21

Reliability milestone driven by an audit of real `/deliver` output (126 of 224 confirmed
PARTIAL/MISSING findings were marked `[x]/CLOSED`). Makes verification **cumulative, fail-closed,
and meta-checked** — the Anthropic-grounded cure for "closed for the workflow that existed that day."
Sources: [Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
(capability evals graduate to a regression suite that holds ~100%),
[Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)
(ground truth from the environment), [Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
(tools are contracts), [The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification).

### Added

- **`regression-guardian` role + cumulative-invariant gate** ([role](references/roles/regression-guardian.md),
  [doctrine](references/regression-and-invariants.md)): re-runs the accumulated invariant/regression
  suite **across all workflows** each batch, **graduates** verified closures into the suite, and
  meta-checks **gate integrity**. Schema-enforced: `completed` requires `regressions_found: 0`,
  `regression_suite_current: true`, `gate_integrity_ok: true`. Fixes the dominant failure — an
  invariant closed for one workflow that a later milestone silently breaks.
- **Gate-integrity meta-check** — `bin/check-gate-integrity.sh` flags **green-by-skip** (a
  gate/constitutional/contract test that passes only because it's skipped) and **can't-fail gates**
  (`continue-on-error` on a CI gate). A gate that didn't run is a failure, not a pass.
- **Capability conformance (`declared ⇒ exercised`)** in `integration-verifier`: a claimed
  capability/vendor/tool must be observably exercised, not merely present (new `capability_gaps`;
  `completed` requires 0). Catches "declares 15 tools, dispatches 9" and "connected = string exists."
- **Constitution P10** — verification is cumulative and fail-closed. Role count 50 → 51; MVP 9 → 10,
  Full 22 → 23. `AGENTS.md` gains an optional `## Invariants` section.

## [2.4.0] - 2026-07-10

Architecture-governance milestone: soundness + conformance gates that stop a batch from passing
tests and E2E wiring while drifting from the app's architecture. MINOR — new role + additive gates.

### Added

- **Architecture conformance & soundness gates** ([references/architecture-reviewer.md](references/roles/architecture-reviewer.md),
  [references/architecture-baseline.md](references/architecture-baseline.md)) — closes the gap where
  a batch passes tests + E2E wiring yet violates the app's architecture (architectural **drift**).
  New independent `architecture-reviewer` role (builder ≠ auditor, `thinking: extended`) with two
  modes: **soundness** (Phase A — is `plan.md` correct and baseline-fitting? gate before any batch)
  and **conformance** (Phase B — per batch, no drift from the baseline; hard gate). Schema-enforced:
  a `completed` handoff requires `architecture_sound`/`conformance_verified` true and
  `drift_findings: 0`.
- **`bin/check-architecture.sh`** — architecture **fitness functions**: delegates to the project's
  arch-lint tool (dependency-cruiser / Deptrac / go-arch-lint) or applies declared forbidden-import
  rules from the baseline. Wired into `mvp`/`full` (after `integration-verifier`) and both `/deliver`
  phases.
- Role count 49 → 50; MVP 8 → 9, Full 21 → 22 (role-matrix, constitution enumeration, SKILL).
  `AGENTS.md` gains an optional `## Architecture` (baseline) section.
  Grounded in [architectural fitness functions](https://www.infoq.com/articles/fitness-functions-architecture/),
  [conformance/governance](https://developersvoice.com/blog/architecture/architectural-fitness-functions-automating-governance/),
  and [drift vs. erosion](https://earezki.com/ai-news/2026-06-08-architecture-drift-detection-keep-your-code-aligned-with-design/).

## [2.3.0] - 2026-07-09

Agent-quality & autonomy hardening — Tier 1 + Tier 2 practices from Anthropic and other vendors,
applied to the pipeline. Sources: [Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents),
[Claude Code best practices](https://code.claude.com/docs/en/best-practices),
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents),
[Demystifying evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents),
[OpenAI — A practical guide to building agents](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/),
[The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification).

### Added

- **TDD red→green discipline** ([references/tdd.md](references/tdd.md)) — tests first, **run and
  seen to fail**, implement to green, tests immutable. Engineer handoffs set `tests_failed_first`.
- **Harness-enforced quality gate (hooks, ~100% vs ~70% prose)** — `hooks/hooks.json` Stop hook
  runs `bin/quality-gate.sh` (fast typecheck+lint from AGENTS.md; no-ops outside team-bootstrap
  projects; `TEAM_BOOTSTRAP_QUALITY_GATE=off` to disable). Full/E2E stay with integration-verifier
  + CI. ([references/hooks.md](references/hooks.md)).
- **Evidence, not assertion** — `verification_evidence` (real command output) is schema-required
  when a `backend-engineer` / `frontend-engineer` / `qa-test-engineer` handoff is `completed`.
  Verified: `completed` without evidence is REJECTED.
- **Per-step ground-truth verification** — engineer roles verify (typecheck+lint+tests) after each
  significant change, not only at the end.
- **Structured note-taking** ([references/note-taking.md](references/note-taking.md)) — durable
  run-notes across compaction (third context lever beyond compaction + distilled subagent returns).
- **Adversarial & cross-model verification** ([references/adversarial-verification.md](references/adversarial-verification.md))
  — refutation panels + optional cross-provider second opinion for high-stakes calls.
- **Extended thinking** — new `thinking: extended` frontmatter field on high-reasoning roles
  (`cto-architect`, `cto-tech-lead`, `solution-architect`, `integration-verifier`,
  `release-manager`); documented in [references/model-tiers.md](references/model-tiers.md).
- **Outcome-based evals (north-star)** + new grader dimensions (`evidence_present`,
  `red_green_followed`, `outcome_pass_rate`, `adversarial_escalation_honored`) in
  [references/trace-evals.md](references/trace-evals.md).
- **Constitution P9** — verify by red→green and evidence, never by assertion.

## [2.2.0] - 2026-07-09

Reliability milestone: an outcome-based integration gate that stops agents from shipping unwired
/ dead code while reporting success. MINOR — new role + additive gate, no breaking changes.

### Added

- **`integration-verifier` role + hard integration gate** — closes the "backend built the
  endpoint, frontend never called it, both reported done" failure. An independent, read-only
  auditor runs after the builders (`mvp`/`full`, and each `/deliver` batch) with a **clean
  context** (builder ≠ auditor): it executes the E2E command from `AGENTS.md` and scans for
  orphans (any produced endpoint/component with no live consumer). Schema-enforced hard gate — a
  handoff **cannot be `completed` unless `integration_verified: true` and `orphans_found: 0`**;
  otherwise `blocked`, sent back, and after 3–5 attempts stopped for human rollback. Grounded in
  published vendor practice: outcome-based verification, evaluator-optimizer separation, and
  harness-enforced gates ([Anthropic — Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents),
  [The Verification Gap](https://codemyspec.com/blog/agentic-qa-verification)).
- **`bin/check-orphans.sh`** — heuristic dead-code/unwired-artifact scan over a batch diff
  (advisory input to the verifier): flags added exports/routes with no consumer.
- **Vertical-slice doctrine** in the pre-implementation flow and `/deliver`: batches deliver a
  working end-to-end path, and acceptance criteria are written as user-observable outcomes — not
  horizontal layers. Role count 48 → 49 (constitution enumeration updated, MINOR).

## [2.1.1] - 2026-07-04

Patch: portability + correctness fix for the l2p citation gate, surfaced by dogfooding the
pipeline on a live landing.

### Fixed

- **`bin/check-citations.sh`**: table-header rows are now skipped structurally (the line above a
  `|---|` separator) instead of by a case-sensitive keyword list — fixes false positives on
  lowercase headers. Rewritten single-pass without `mapfile` so it runs on bash 3.2 (macOS),
  where the previous version silently passed. Surfaced by dogfooding the `l2p` pipeline on a live
  landing.

## [2.1.0] - 2026-07-04

Adds the `l2p` (Landing-to-Platform) gap-audit pipeline — a third read-only audit lens that
turns landing↔platform↔docs gaps into an implementation backlog. MINOR: new pipeline + six
roles, no breaking changes.

### Added

- **`l2p` pipeline** ([references/pipelines/l2p.md](references/pipelines/l2p.md)) — read-only
  Landing-to-Platform gap audit: finds where landing promises, platform delivery, and docs
  diverge, and turns each gap into an ICE-ranked implementation task that `single-thread` /
  `mvp` / `full` (or `/deliver`) consume. Six new roles (`recon`, `usecase-miner`,
  `cartographer`, `funnel-auditor`, `gatekeeper`, `gap-backlog-author`) with strict evidence
  discipline — every downstream claim cites a `recon` grounding id (C###/S###/F###/I###) or is
  tagged HYPOTHESIS/ESTIMATE. Domain refs under [references/l2p/](references/l2p/).
- **`bin/check-citations.sh`** — machine-checked evidence gate: scans `l2p-artifacts/` for
  assertions lacking a grounding id, hardening the citation discipline that was previously
  prose-only.
- Role count 42 → 48; pipelines 5 → 6 (constitution enumeration updated, MINOR per its rules).
  Ports the funnel-cartography framework into team-bootstrap as a native audit→backlog lens.

## [2.0.0] - 2026-07-04

Spec-driven delivery milestone: a one-command flow (`/deliver`) chains the full
pre-implementation sequence into step-by-step batch delivery, backed by a versioned
constitution and milestone scaffolding, plus reviewer-consensus and disposition gates. Major
bump reflects the new delivery entry point and governance model. The handoff-contract change is
**backward-compatible** (the new field is optional; older handoffs still validate).

### Added

- **`/deliver` command** ([commands/deliver.md](commands/deliver.md)) — one entry point that runs
  the full pre-implementation flow autonomously (`speckit-constitution` → `specify` → `clarify` →
  `plan` → `tasks` → `analyze`), gates on unresolved blockers, then drives implementation batches
  **step-by-step** through `mvp`/`full` (waits for confirmation between batches; commits local,
  never pushes without authorization). Documented in USAGE.md.

- **Pre-implementation flow doctrine** ([references/speckit-preimpl-flow.md](references/speckit-preimpl-flow.md)):
  a 6-step spec → plan → tasks → dispatch sequence, positioned as the recommended **first step**
  before pipelines run and mapped onto the bundled `speckit-*` skills. Linked from README and SKILL.md.
- **Pre-implementation scaffolding** so the flow runs against team-bootstrap itself:
  [`constitution.md`](constitution.md) v1.0.0 (invariants P1–P8 + amendment/enumeration rules
  distilled from existing doctrine), [`specs/`](specs/) convention with a milestone
  [`TEMPLATE/`](specs/TEMPLATE/), [`feature.json`](feature.json) active-milestone pointer, and
  [`docs/adr/`](docs/adr/) seeded with ADR-0001 (single-thread-by-default).

- **Reviewer consensus signal.** Optional `reviewer_consensus` array on the reviewer roles
  (`code-reviewer`, `security-reviewer`, `performance-reviewer`, `accessibility-reviewer`,
  `data-schema-reviewer`): per-finding `flagged_by` / `reviewers_total` / `disposition`, so a
  finding raised by a majority of independent reviewers reads as high-confidence and the
  denominator stays honest about reviewers that didn't run. Documented in
  [trace-evals.md](references/trace-evals.md).
- **Disposition gate before `go`.** `release-manager` emits an optional
  `unresolved_blocking_findings`; whenever present, a `go` decision requires it to be `0`, so no
  open CRITICAL/HIGH finding can coexist with a ship verdict. The field is optional (older
  handoffs stay valid) and the playbook instructs roles to always emit it. New grading dimensions
  `disposition_gate_honored` and `consensus_denominator_honest` in
  [trace-evals.md](references/trace-evals.md).
- **Repo hygiene: `.github/dependabot.yml`** (github-actions ecosystem — the only dependency
  surface for a markdown asset) and **`.github/workflows/security.yml`** (shellcheck + `bash -n`
  on `bin/*.sh`, gitleaks secret scan). The markdown/shell analog of a vuln-scan gate.
- **`.github/workflows/release.yml`** — on a `v*` tag: verifies the tag matches `VERSION` and
  `plugin.json`, re-runs the role/JSON gates, packages the plugin as a tarball, and cuts a
  GitHub Release with auto-generated notes.

### Changed

- **Handoff contract (backward-compatible):** `release-manager` gains an optional
  `unresolved_blocking_findings` field. Existing handoffs without it remain valid; when present,
  the `go`-requires-`0` gate is enforced. No migration required.

## [1.7.0] - 2026-06-26

SOTA-hardening pass (steps B–E): tiered models, layered guardrails + circuit breaker, an
independent evaluator gate with a runnable per-role eval, an enforced subagent return budget, and a
runnable version gate. Also corrects `.claude-plugin/plugin.json` version (was stale at `1.0.0`) to
track the CHANGELOG line.

### Added

**Tiered model strategy across all 42 roles (step B).** The `model:` frontmatter field — previously
uniform `claude-opus-4-7` on every role — is now differentiated into three tiers and bumped to the
current generation. Opus (`claude-opus-4-8`, 12 roles) for production-critical / irreversible /
high-stakes reasoning (architecture, security, legal, money, release go/no-go, incident response,
schema migrations, AI engineering); Sonnet (`claude-sonnet-4-6`, 24 roles) for implementation,
reviews, and product/design/research; Haiku (`claude-haiku-4-5-20251001`, 6 roles) for mechanical /
comms / simple-check work. New [references/model-tiers.md](references/model-tiers.md) documents the
assignment rule and is the source of truth. This cuts run cost on long pipelines without lowering
quality where reasoning depth changes the outcome.

**Layered guardrails + circuit breaker (step C).** New [references/guardrails.md](references/guardrails.md)
formalizes guardrails as a layered defense instead of ad-hoc rules inside roles:

- **Input guardrail** — a new orchestrator Step 0.5 that screens the spec for injection/integrity,
  scope, and feasibility *before* the pipeline fans out, so a doomed or unsafe run is stopped before
  N roles burn tokens. Verdicts `pass` / `needs_input` / `reject`; safety is hard, scope is advisory.
  New stop reason `input_guardrail_rejected`.
- **Output guardrail** — documented secret/PII scan before any `Write`/`Edit`/commit/publish,
  composing with (not replacing) the irreversibility action-class gate.
- **Circuit breaker** — orchestrator now tracks tool-calls-without-progress per role and trips at
  `max_tool_calls_without_progress` (default `12`), independent of the schema retry budget (2) and
  verification loop (3). New stop reason `circuit_breaker_tripped`; policy in
  [failure-policy.md](references/failure-policy.md#circuit-breaker-policy).

The tool-layer guardrail (`tool_surface` + irreversibility action classes) already existed and is
cross-referenced, not changed.

**Independent evaluator gate + runnable per-role eval (step A).** New
[references/evaluator.md](references/evaluator.md) adds a GAN-style evaluator that judges a role's
artifact *before* the handoff is accepted, countering self-evaluation bias:

- **Context-reset judge** — the evaluator runs as a fresh subagent receiving only the success
  criteria + the artifact, never the generator's narrative or the full blackboard. This is the one
  sanctioned exception to inline shared-context execution; generators stay inline (Cognition intact),
  only the judge is isolated. The judge runs on a strong model regardless of the role's own tier.
- **Mandatory for** `release-manager`, `security-reviewer`, and code/migration-writing roles;
  on-demand elsewhere; skipped for roles with no verifiable artifact.
- **Per-dimension rubric** — `criteria_coverage` / `grounding` / `correctness` / `safety` /
  `quality`, scored one at a time on a 0–4 scale with concrete-evidence justifications and shuffled
  dimension order to cancel position bias.
- **Bounded evaluator-optimizer loop** — `pass` accepts; `revise`/`fail` triggers one optimizer
  cycle (`max_evaluator_cycles` default `1`); `safety-fail` is a hard stop. New stop reason
  `evaluator_gate_failed`. Wired into orchestrator Step 5.5.
- **`bin/eval-role.sh`** — runnable eval: deterministic frontmatter validation against the role
  schema (`--all` for a CI gate) + LLM-as-judge prompt assembly (emits the prompt; invokes `claude`
  only with `--judge`; never fabricates a score). `evals/` is no longer docs-only.

### Changed

**Subagent return budget is now enforced (step D).** Previously the condensed summary was an
*optional* ≤200-token convention; it is now a **hard contract**. `summary` in the role-output schema
gains `maxLength: 1200` (~200 tokens), so an over-budget summary fails handoff validation. The
`### Subagent return` contract in [references/subagent-dispatch.md](references/subagent-dispatch.md)
is rewritten: exactly three things cross back to the main thread — the structured handoff (capped
summary), artifact **paths** (never bodies), and nothing else. This stops deep-audit / research
roles (`security-reviewer`, `discovery-research`, `performance-reviewer`) from dumping large working
sets into the shared blackboard.

**Trace-replay as an enforced version gate (step E).** [references/versioning.md](references/versioning.md)
previously described regression evals aspirationally; they are now a concrete, runnable **version
gate** with two layers: Layer 1 (static) is `bin/eval-role.sh <role>` / `--all`, blocking on
frontmatter drift and runnable today; Layer 2 (behavioral) replays a role's baseline specs and
blocks the bump on any grader regression, verdict flip, new schema failure, or >25% unjustified
token regression. [references/trace-evals.md](references/trace-evals.md) is cross-linked as the
behavioral half. Agent configuration (instructions, tool defs, guardrails, model pin) is now treated
as code: a behavior change is reviewed like a code change. Documents the model-tier change (step B)
as a minor-class pending ratification. Fixed a stale `claude-opus-4-7` example in the versioning
docs.

## [1.6.0] - 2026-05-20

### Added

**Senior-grade skill integration across all 29 previously skill-less roles + 2026 best-practice rules.** Pre-v1.6, only 13 of 42 roles had skills integrated (the v1.2.1 audit-dd team, v1.3 design roles, v1.4 marketing roles, v1.5 post-release roles). v1.6 backfills the remaining 29 roles with senior-grade skill integration patterns.

**Roles updated to v1.1.0 with skill integration + senior-grade rules:**

*Implementation (3):*
- `backend-engineer` — TDD + source-driven + incremental + security-as-code patterns
- `frontend-engineer` — production UI + browser-testing + performance budget enforcement
- `devops-platform` — CI-as-code + deploy-checklist + security-hardening + observability-first

*Architecture (3):*
- `cto-architect` — ADR-grade decisions + stable interface contracts + convergent design
- `solution-architect` — interface boundaries + ADRs + integration-pattern decisions
- `cto-tech-lead` — multi-axis quality framework + adversarial verification + ADR-grade standards

*Strategic & Discovery (5):*
- `discovery-research` — cited research + competitive intelligence + AI-visibility baseline
- `product-manager` — convergent prioritization + ICP precision + AI-displacement awareness
- `product-ba` — spec-driven requirements + edge-case discipline + ADR records
- `business-analyst` — spec-grade requirements + research synthesis + NFRs first-class
- `delivery-manager` — task decomposition + incremental delivery + parallelism documented

*Review & Quality (8):*
- `test-designer` — TDD discipline + adversarial coverage + property-based tests
- `qa-test-engineer` — real-browser verification + root-cause debugging + multi-tenant isolation tests
- `accessibility-reviewer` — UI-engineering patterns + real-browser a11y tree + WCAG 2.2 awareness
- `performance-reviewer` — profile-first + CWV budget enforcement + LLM cost budgets
- `security-reviewer` — security-hardening + LLM-specific threats + multi-tenant as security boundary
- `data-schema-reviewer` — migration safety + multi-tenancy isolation + audit-log immutability
- `overengineering-reviewer` — simplification patterns + YAGNI + AI-aesthetic detection
- `code-reviewer` — multi-axis review + AI-generated code awareness + test correctness verification

*Release & Communication (4):*
- `release-manager` — shipping checklist + staged rollout + observability pre-verification
- `release-docs` — runbook discipline + ADR-grade configuration documentation
- `stakeholder-communicator` — humanized customer comms + outcome-led framing
- `documentation-agent` — ADR-grade docs + humanized end-user content

*Optional / Specialty (6):*
- `ux-researcher` — research synthesis + competitive UX + persona-grounded friction
- `whimsy-injector` — production UI + humanized whimsy copy + brand-consistent voice
- `ai-engineer` — context engineering + LLM TDD + AI-visibility measurement + multi-provider architecture
- `chaos-engineer` — experiment-as-code + ADR-grade hypothesis records + LLM failure modes
- `legal-compliance-checker` — cited 2026-current research + structured policy extraction + EU AI Act
- `incident-responder` — systematic root-cause + blameless postmortems + humanized status updates

### Skill mappings — all locally installed

All skills referenced by new role integrations are present in the canonical local installs (`~/.claude/skills/<name>/SKILL.md`). No new skills to install — v1.6 leverages the existing 47-skill local set fully.

**`skills-manifest.json` v1.4.0** — `full` pipeline section now declares **5 required + 12 recommended + 25 optional skills** with `used_by` lists covering all 42 roles. `bin/check-skills.sh full` resolves all 42 in reference setup.

**Highest-coverage skills** (used across many roles):
- `documentation-and-adrs` — **14 roles** (canonical documentation pattern)
- `competitor-analysis` — 9 roles
- `tavily-research` — 9 roles
- `copywriter` — 7 roles
- `idea-refine` — 8 roles
- `research-synthesis` — 6 roles
- `data-storyteller` — 5 roles
- `test-driven-development` — 5 roles
- `code-review-and-quality` — 5 roles
- `spec-driven-development` — 5 roles

### 2026 best-practice rules added to each role

Beyond skill integration, each role's `## Rules` section was extended with 2026-current best practices:

**Engineering roles:**
- TDD + doubt-driven verification before believing yourself
- Source-driven implementation (cite docs, never hallucinate APIs)
- Strict typing — no `any` in strict-mode codebases
- Multi-provider LLM architectures (foundation-model TOS changes quarterly)
- Performance budgets enforced in CI (CWV, p95 SLOs, LLM cost per request)
- Security shift-left (multi-tenant isolation as security boundary, not just architecture)
- Observability-first design (OpenTelemetry, structured logs from day one)

**Strategic roles:**
- ICP precision over breadth
- AI-displacement risk awareness (24-36 month horizon for any product decision)
- AEO/GEO posture in market-facing decisions
- Outcome-led, not feature-led
- Honest measurement (no vanity metrics, no rounding tricks)

**Review roles:**
- AI-generated code pattern awareness (flag generic over-abstraction)
- Multi-axis quality framework over subjective taste
- Performance + a11y budgets enforced, not optional
- WCAG 2.2 awareness (not just 2.1)

### Why senior-grade matters in 2026

The 2025-2026 shift from "AI agents can write code" to "AI agents can be senior engineers" requires explicit pattern documentation. Without skill-grounded rules:

1. **Engineering decisions default to AI-aesthetic** — over-abstracted factories, generic error messages, comment ceremony
2. **Architecture lacks decision provenance** — tribal knowledge evaporates with team changes
3. **Strategic roles produce wishlist scope** — no convergent narrowing, no ICP precision
4. **Reviews catch surface issues only** — multi-axis frameworks missing means missing systemic problems
5. **Communications read as AI-generated** — trust erodes with stakeholders, customers, partners, community

v1.6 closes these gaps by making senior-grade patterns explicit and skill-validated.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. All 29 role updates are version 1.0.0 → 1.1.0 (minor bump, additive). Existing pipelines continue to work; new skill invocations are recommended/optional unless explicitly listed as required (the 5 blocking skills from v1.5 remain the only blocking ones).

If `bin/check-skills.sh full` shows missing recommended/optional skills, the pipeline still runs via fallbacks. Quality drops proportionally to missing skills. Reference setup has all 42 skills installed locally.

### Total skill coverage in team-bootstrap v1.6.0

| Tier | Count | Notes |
|---|---:|---|
| Required (blocking) | 5 | humanize, humanize-ai-text, persona-customer-support, research-synthesis, idea-refine |
| Recommended | 12 | Used by 4+ roles each; core senior toolkit |
| Optional | 25 | Used by 1-3 roles each; specialized |
| **Total** | **42 skills** | **across 42 roles** |

Skills installed in reference setup: 47 (5 unused but available for future roles).

## [1.5.0] - 2026-05-20

### Added

Three post-release strategic roles closing the **customer + ecosystem + community** gap. Pipeline previously shipped products and translated launches into growth motion, but had no dedicated owner for retention motion, partner ecosystem, or community-led growth. v1.5 introduces all three with a parallel fan-out pattern (CSM + partnerships + community) feeding `growth-marketer` synthesis.

**New roles (all inline-only, opt-in for `full` + `single-thread`, all skill-blocking by design):**

- **`customer-success-manager` role** ([references/roles/customer-success-manager.md](references/roles/customer-success-manager.md)) — Canonical CSM function. Owns customer health framework (weighted dimensions + status definitions), voice-of-customer report, per-account QBR prep template (with industry + competitive context), onboarding playbook (0/7/30/60/90-day milestones + escalation triage), customer communication templates (onboarding / renewal / expansion / at-risk sequences), cohort retention dashboard. Position: after `release-manager`, parallel with partnerships-lead + community-manager. Pipeline-blocking on `persona-customer-support` + `research-synthesis` + `humanize-ai-text`.

- **`partnerships-lead` role** ([references/roles/partnerships-lead.md](references/roles/partnerships-lead.md)) — Ecosystem strategy + partner pipeline execution. Owns partner landscape map (with competitive overlap analysis), partnership thesis (top 3-5 with strategic rationale + expected lift), per-partner brief template, outreach + activation playbook (humanized for AI-detect avoidance), co-launch comms package (multi-platform), partnership performance dashboard. Conditional: technical integration vetting rubric (api-and-interface-design) + content / SEO partner scoring rubric (backlink-analyzer). Position: parallel with CSM + community-manager. Pipeline-blocking on `humanize` + `idea-refine`.

- **`community-manager` role** ([references/roles/community-manager.md](references/roles/community-manager.md)) — Community-led growth motion end-to-end. Owns channel strategy (tiered: Own / Native presence / Listen only), daily engagement engine (cross-platform with humanized copy), moderation playbook (5-tier escalation), voice-of-community report, 3-tier ambassador / advocacy program, community visual assets (badges + banners + reaction visuals), community health dashboard. Position: parallel with CSM + partnerships-lead. Pipeline-blocking on `humanize` + `humanize-ai-text`.

### Skill-blocking constraint (new in v1.5)

Unlike all prior roles where missing skills caused graceful degradation, v1.5 introduces **strictly required skills** that cause `status: blocked` if missing. The harness validates skill availability before role dispatch and refuses to run the role without them.

| Skill | Required by role(s) | Why blocking |
|---|---|---|
| `humanize` | partnerships-lead (outreach + co-launch), community-manager (every post + moderation) | AI-detected partner outreach has < 1% reply rate; communities reject AI-flagged posts |
| `humanize-ai-text` | CSM (renewal/expansion/at-risk sequences), community-manager (ambassador program) | AI-detected customer comms erode trust; ambassadors ghost transactional programs |
| `persona-customer-support` | CSM (health framework + onboarding escalation) | Manual customer-management framework fails QA on triage rigor |
| `research-synthesis` | CSM (VoC theme extraction) | Unstructured summary loses theme density + segment correlation |
| `idea-refine` | partnerships-lead (thesis convergence audit trail) | Unstructured prioritization fails QA on convergence rigor |

All 5 blocking skills present in canonical local installs at `~/.claude/skills/<name>/SKILL.md`. `bin/check-skills.sh full` now reports a `[required]` tier separate from `[recommended]` + `[optional]`.

### Deep skill integration in role workflows

All three v1.5 roles document **per-skill invocation point** within their Output Template — skills aren't listed as references, they're called out at the specific workflow step where they're invoked, producing named artifacts. This pattern is stronger than v1.3 / v1.4 (where skills were recommended without binding to specific output sections).

Example from `customer-success-manager.md`:
> **Invocation:** Used `Skill: persona-customer-support` to derive escalation triage patterns from existing support behavior + ticket categorization.
> **Invocation:** Used `Skill: data-storyteller` to design the health score visualization + cohort breakdown.

Each role's `checks:` section includes per-skill invocation verifications (`skill_X_invoked: passed`), making skill usage auditable in the handoff trace.

### Parallel fan-out pattern (post-release coordination)

When 2+ of {CSM, partnerships-lead, community-manager} run, they execute in **parallel** as separate subagent dispatches (if available) or sequentially. Each produces independent strategic artifacts that `growth-marketer` then **synthesizes** into the unified channel + content + AI search posture + growth loops strategy:

```
release-manager
       ↓
  ┌────┼────┐                ← v1.5 parallel fan-out
  ↓    ↓    ↓
 CSM  PL   CM
  └────┼────┘
       ↓
growth-marketer (synthesizes)
       ↓
stakeholder-communicator
```

This pattern is documented in `pipelines/full.md` ("Post-release stages — when to include").

### Supporting updates

- **`skills-manifest.json` v1.3.0** — `full` pipeline section now declares 5 required + 9 recommended + 18 optional skills. New `[required]` tier introduces blocking semantics.
- **`pipelines/full.md`** — rewritten with parallel fan-out diagram + new "Post-release stages — when to include" decision matrix (per-role triggers + skip conditions).
- **`subagent-mapping.md`** — new "Customer / Partnership / Community roles (v1.5)" section with primary + fallback subagent types; all three roles added to inline-only list with skill-blocking caveat documented.
- **`role-matrix.md`** — all three roles in Optional Roles table with triggers + skill-blocking flags + parallel-execution position; new selection-rule entries (with CSM / with partnerships / with community).
- **`role-output.schema.json`** — three roles added to root `oneOf`; per-role definitions with role-specific required fields (`retention_strategy_confidence`, `voc_themes_count`, `at_risk_arr_percent`, `partnership_priorities_count`, `expected_partner_channel_contribution`, `owned_channels_count`, `ambassador_program_tiers`, `expected_community_channel_contribution`).
- **`INSTALL.md`** — new "Required: Full pipeline — install skills for v1.5 post-release roles" section. Per-skill table + install priority by product context (SaaS-with-retention / developer-tools / ecosystem-first / consumer / internal-tool / patch).

### Total role count

team-bootstrap v1.5.0 now ships **41 roles** total (up from 38 in v1.4): 14 implementation + 8 review + 6 audit-DD + 4 strategic (discovery / product-manager / product-ba / business-analyst) + 2 design + 2 marketing-strategy + **3 customer/partnership/community (NEW)** + 2 release + others.

### Why dedicated post-release strategic roles

Pre-v1.5, the pipeline assumed `release-manager` → `stakeholder-communicator` → `documentation-agent` was sufficient post-release. This worked for shipping, but failed for:

1. **Retention** — without CSM, NRR / GRR / logo retention strategy was implicit. Subscription businesses live or die on retention math.
2. **Ecosystem** — without partnerships-lead, partner pipeline was opportunistic. Products with distribution ceilings on direct channels can't scale without ecosystem motion.
3. **Community** — without community-manager, community-led growth defaulted to "we'll figure it out post-launch." For developer tools / prosumer SaaS / AI products, community signal is the primary buyer evaluation channel.

These three roles aren't optional luxuries — they're **deal-defining for products in their respective contexts** (subscription / ecosystem / community). v1.5 closes the gap by making them first-class pipeline citizens with skill-validated execution.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when v1.5 roles are not opted in.

Opt into v1.5 roles by inserting them in the pipeline per `pipelines/full.md` "Post-release stages — when to include" decision matrix. If any v1.5 role is invoked but its required skills are missing, the role returns `status: blocked` immediately (no work attempted) — install required skills via the paths in `INSTALL.md` and retry.

## [1.4.0] - 2026-05-20

### Added

Dedicated GTM + ongoing growth stages for the `full` and `single-thread` pipelines. Closes a gap from v1.0–v1.3 where the pipeline shipped products but had no role responsible for positioning, ICP selection, pricing strategy, launch sequencing, channel strategy, content engine, or AI search posture. Existing `stakeholder-communicator` produced release notes one-shot; nothing built the ongoing growth motion.

- **`product-marketer` role** ([references/roles/product-marketer.md](references/roles/product-marketer.md)) — Canonical Product Marketing Manager (PMM) function. Owns ICP definition, positioning statement, category framing, messaging hierarchy, pricing strategy, launch sequencing (alpha/beta/GA), sales enablement (discovery questions + objection handling + ROI calculator inputs), competitive battle cards. Position: after `product-manager`, before `business-analyst` — positioning shapes downstream requirements rather than arriving post-release. Inline-only by default.

- **`growth-marketer` role** ([references/roles/growth-marketer.md](references/roles/growth-marketer.md)) — Strategic growth function (CMO-equivalent, named for work not title). Owns channel strategy (mix + CAC + ramp + kill criteria), content engine (cadence + topic clusters + SEO/AEO posture), brand-as-moat (category-defining terminology, recognized-metric play, community positioning), growth loops (with k-factor / payback), attribution model, AI search posture per platform (ChatGPT / Perplexity / Claude / Gemini / Google AI Overview), growth experiments backlog (ICE-ranked), 30/60/90 day plan. Position: after `release-manager`, before `stakeholder-communicator` — translates ship event into compounding growth motion. Inline-only by default.

- **Skill ecosystem integration for both roles** — `Skill` in `tool_surface.allow`; `## Recommended skills` section per role; all referenced skills present in canonical local installs (`~/.claude/skills/<name>/SKILL.md`):
  - `product-marketer` core: `competitor-analysis` (non-negotiable for positioning), `copywriter`, `brief`, `tavily-research`, `idea-refine`, `persona-customer-support`
  - `growth-marketer` core: `30x-seo-ai-visibility` (highest leverage in 2026), `ai-seo`, `seo-aeo-best-practices`, `seo-audit`, `seo-geo`, `find-keywords`, `programmatic-seo`, `backlink-analyzer`, `competitor-analysis`, `tavily-research`, `social-media-posts`, `copywriter`, `brief`, `data-storyteller`, `idea-refine`

- **`skills-manifest.json`** v1.2.0 — extends `full` pipeline section with 14 additional marketing-specific optional skills. Total `full` pipeline now: 4 recommended + 18 optional skills. `bin/check-skills.sh full` resolves all 22 against local installs.

- **`pipelines/full.md`** updated — `product-marketer` inserted after `product-manager` (before `business-analyst`); `growth-marketer` inserted after `release-manager` (before `stakeholder-communicator`); updated role flow diagram + new "Marketing stages — when to include" decision matrix (greenfield launch / pricing change / repositioning / growth plateau / AEO shift / internal tool / patch).

- **`subagent-mapping.md`** updated — new "Marketing roles (v1.4)" section with primary + fallback subagent types; both roles added to inline-only list.

- **`role-matrix.md`** updated — both roles in Optional Roles table with triggers + "Inserts after" position; new selection-rule entries (with product-marketer / with growth-marketer).

- **`role-output.schema.json`** updated — `product-marketer` + `growth-marketer` added to root `oneOf`; new per-role definitions with role-specific required fields (`positioning_confidence`, `pricing_confidence`, `primary_channel_thesis`, `ai_search_priority`).

- **`INSTALL.md`** updated with new "Full pipeline — install referenced skills for marketing roles" section. Per-skill table + install priority by product type (greenfield launch / pricing change / growth plateau / content scaling / internal tool / patch).

### Why dedicated marketing stages

The pipeline previously assumed products would just "ship" — `release-manager` made go/no-go, `stakeholder-communicator` wrote business-language release notes, done. But the gap between "shipping" and "growing" is where most products die — `product-marketer` answers "who buys this and what do we say" before development, and `growth-marketer` answers "how does this compound week-over-week" after launch. Without these roles, GTM decisions are made by founders at runtime under pressure, which is the wrong cognitive context (focus on shipping, not market motion).

For products entering markets where AI search visibility (AEO / GEO) is now the primary growth surface — every consumer / prosumer / B2B product launching in 2026 — `growth-marketer` is the role that owns the AI search posture explicitly. Without it, AEO/GEO defaults to "we'll figure it out post-launch," which is too late.

### Total role count

team-bootstrap v1.4.0 now ships **38 roles** total (up from 36 in v1.3): 14 implementation roles + 8 review roles + 6 audit-DD roles + 4 strategic roles (discovery / product-manager / product-ba / business-analyst) + 2 design roles + 2 marketing roles + 2 release roles + others.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when marketing roles are not opted in. Opt into marketing stages by inserting `product-marketer` and/or `growth-marketer` in the pipeline per the [pipelines/full.md](references/pipelines/full.md) "Marketing stages — when to include" decision matrix.

### Inline-only rationale

Both `product-marketer` and `growth-marketer` run inline by default — their strategic artifacts (positioning / pricing / channel mix / content cadence / launch sequencing) are inherited by downstream release + communication roles. Fragmenting them across subagent contexts risks `release-manager` missing the launch sequencing or `stakeholder-communicator` missing the brand narrative. Dispatch only with explicit `--isolate` when running a marketing-only audit with no release decision downstream.

## [1.3.0] - 2026-05-20

### Added

Dedicated UX/UI design stages for the `full` and `single-thread` pipelines. Closes a gap from v1.0–v1.2 where `frontend-engineer` was expected to consume "UI specs" that no upstream role produced — design decisions defaulted to runtime intuition, which is the root cause of generic AI-aesthetic output across the pipeline.

- **`ux-designer` role** ([references/roles/ux-designer.md](references/roles/ux-designer.md)) — Translates research into interaction architecture: information architecture, user flows, screen-by-screen wireframes (structural only, no visual styling), interaction patterns, mental-model mapping, UX writing guidelines. Position: after `ux-researcher` (or `product-manager` if research skipped), before `ui-designer`. Inline-only by default (downstream roles inherit component inventory + mental model).

- **`ui-designer` role** ([references/roles/ui-designer.md](references/roles/ui-designer.md)) — Translates UX architecture into visual design: design tokens (color/type/spacing/motion/radii), component library spec (variants/states/a11y contract), screen-by-screen reference prototype in HTML + Tailwind, implementation mapping (component → primitive → token usage). Position: after `ux-designer`, before `frontend-engineer`. Inline-only by default.

- **Skill ecosystem integration for both roles** — `Skill` in `tool_surface.allow`; `## Recommended skills` section per role with skill-name → when-to-invoke → what-it-gives mapping:
  - `ux-designer`: `research-synthesis`, `idea-refine`, `competitor-analysis`, `tavily-research`, `persona-customer-support`
  - `ui-designer`: `frontend-ui-engineering` (highest-leverage), `api-and-interface-design`, `image-generation`, `competitor-analysis`, `documentation-and-adrs`, `idea-refine`
  - All recommended skills present in canonical local skill installs (`~/.claude/skills/<name>/SKILL.md`)

- **`skills-manifest.json`** v1.1.0 — added `full` pipeline section with 4 recommended + 5 optional skills per design role. `bin/check-skills.sh full` now verifies install state for design stages.

- **`pipelines/full.md`** updated — new "Optional Roles" section explicitly lists `ux-designer` + `ui-designer` insertion points; new "Design stages — when to include" decision matrix; updated role flow diagram with optional design stage branches.

- **`subagent-mapping.md`** updated — new "Design roles (v1.3 — dedicated UX + UI design stages)" section with primary + fallback subagent types; both roles added to inline-only list.

- **`role-matrix.md`** updated — both roles in Optional Roles table with triggers + "Inserts after" position; new selection-rule entries.

- **`role-output.schema.json`** updated — `ux-designer` + `ui-designer` added to root `oneOf`; new per-role definitions extending `base`.

- **`INSTALL.md`** updated with new "Full pipeline — install referenced skills for design roles" section. Includes per-skill table + "When to actually install these" decision matrix (greenfield consumer / B2B / internal tool / iteration).

### Why dedicated design stages

The pipeline previously assumed UI specs would arrive from somewhere — `product-manager` produces requirements (the *what*), but neither requirements nor research produce IA/flows/wireframes/tokens (the *how*). Without dedicated design roles, `frontend-engineer` makes visual decisions at implementation time, which is the wrong cognitive context (focus on code correctness, not design coherence). Result: generic AI-aesthetic interfaces that look obviously LLM-generated.

For products where UX = differentiation moat (operator-first tools, prosumer apps, AI-native workflows, anything consumer-facing), this is the difference between shippable and shippable-by-a-top-company.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing `mvp` / `full` / `single-thread` / `audit` / `audit-dd` runs continue unchanged when design roles are not opted in. Opt into design stages by inserting `ux-designer` and/or `ui-designer` in the pipeline per the [pipelines/full.md](references/pipelines/full.md) "Design stages — when to include" decision matrix.

### Inline-only rationale

Both `ux-designer` and `ui-designer` run inline by default — their artifacts (IA / wireframes / tokens / reference prototype) are inherited by `frontend-engineer` as the foundation for implementation. Fragmenting them across subagent contexts risks design-token-to-implementation mismatches that produce visual inconsistency in the shipped UI. Dispatch only with explicit `--isolate` when running an audit-only design review with no implementation downstream.

## [1.2.1] - 2026-05-20

### Added

Skill ecosystem integration for `audit-dd` pipeline (gap closed from v1.2.0 — roles referenced skills in prose but `tool_surface` didn't permit the `Skill` tool, and there was no install verification).

- **`Skill` tool** added to all 6 audit-dd role `tool_surface.allow` lists (financial-analyst, market-analyst, customer-health-analyst, ip-contracts-reviewer, culture-team-dd, investment-thesis-author). Roles can now invoke skills at runtime.
- **`## Recommended skills` section** in each of the 6 role playbooks — explicit skill-name → when-to-invoke → what-it-gives mapping per role. Highest-leverage skills called out (e.g. `30x-seo-ai-visibility` for market-analyst's AI-displacement assessment; `data-storyteller` for investment-thesis-author's memo synthesis).
- **`skills-manifest.json`** at repo root — declarative list of required / recommended / optional skills per pipeline. Includes per-skill `purpose` + `fallback` so users know what's lost if a skill is missing.
- **`bin/check-skills.sh`** — verification script. Reads manifest, checks `~/.claude/skills/<name>/SKILL.md` for each, reports installed / missing. JSON output (`--json`) for CI gating. Exit codes: 0 = all recommended present, 1 = required missing, 2 = recommended missing (pipeline runs with fallbacks).
- **INSTALL.md** updated with new "Audit-DD pipeline — install referenced skills" section. Documents that team-bootstrap does NOT auto-fetch skills (no canonical marketplace registry across users); provides install paths via `/plugin install`, manual git clone, or scp from another machine. Includes per-skill table with fallback behavior.

### Why no auto-fetch

Skills live in disparate sources: some come from `addyosmani/agent-skills`, some from 30x.dev / Anthropic bundles, some are personal / community packs. License terms vary; canonical URLs aren't tracked across installs. Auto-fetching would either pin upstream sources (fragile when they move) or vendor copies in this repo (license risk). Manifest + verification is the safer default; users opt-in to fetching.

### Migration

All 6 audit-dd roles bump to `version: 1.1.0`. Backwards compatible — fallback paths preserve the v1.0.0 behavior (WebSearch/WebFetch only) when skills aren't installed.

## [1.2.0] - 2026-05-20

### Added

Commercial / financial due-diligence support. Six new roles + one new pipeline targeting the **`audit-dd`** use case (pre-fundraise / M&A / board prep), distinct from the existing technical `audit` pipeline.

- **`audit-dd` pipeline** ([references/pipelines/audit-dd.md](references/pipelines/audit-dd.md)) — six-role read-only DD run; output is an investor-grade memo (1-pager + 10-page deep dive), not a backlog. Composes with `audit` (run technical audit first, then DD on top).
- **`financial-analyst` role** — ARR build with cohort retention, unit economics (LTV/CAC, CAC payback, Burn Multiple, Magic Number, Rule of 40, NRR), valuation triangulation against 2026 SaaS / AI comps (Bull/Base/Bear).
- **`market-analyst` role** — TAM/SAM/SOM triangulated top-down × bottoms-up, 5-vector moat scoring, **AI-search displacement risk** assessment (can ChatGPT/Perplexity/Claude/Gemini answer the JTBD directly?).
- **`customer-health-analyst` role** — cohort retention curves (logo + GRR + NRR all separate, never aggregated), concentration table (top-customer > 20% = red flag), AI-product-specific signals (API usage retention, model-call cohort behavior, prompt-engineering education curve).
- **`ip-contracts-reviewer` role** — OSS license audit (AGPL / SSPL / Elastic-2.0 contamination detection), **foundation-model TOS** verification (OpenAI / Anthropic / Google — terms change quarterly), customer-contract red flags (AI accuracy warranties, training-data rights, uncapped indemnities), data residency (GDPR + Schrems II SCC, CCPA / CPRA, India DPDPA, China PIPL).
- **`culture-team-dd` role** — org depth + bus factor, retention signals, compensation posture (Levels.fyi / Pave / Carta benchmarks), public sentiment (Glassdoor / LinkedIn / Blind — ethically gathered), founder dynamics.
- **`investment-thesis-author` role** — terminal synthesizer; produces 1-page memo + 10-page deep dive + invest/pass/conditional verdict with probability-weighted MOIC and explicit Bull/Base/Bear scenario weights.
- Schema updates: `audit-dd` added to `compatible_pipelines` enum; six new role consts in `role-output.schema.json` `oneOf` with role-specific required fields (e.g. `investment_recommendation`, `probability_weighted_moic`).
- `role-matrix.md` + `subagent-mapping.md` updated to surface the new DD team and inline-only constraints.

### Migration

Backwards compatible — no breaking changes to existing roles or pipelines. Existing audit / mvp / full / single-thread runs continue unchanged. Opt into the new commercial DD by invoking `/team-bootstrap audit-dd <spec>`.

## [1.0.0] - 2026-05-10

Initial productized release. Distribution structure, full P0 + P1 implementation, top-level docs.

### Added

- **Subagent dispatch model** ([references/subagent-dispatch.md](references/subagent-dispatch.md)) — when roles run inline vs. as Task-tool subagents.
- **Shared blackboard** ([references/shared-blackboard.md](references/shared-blackboard.md)) — full run document available to every role.
- **Irreversibility taxonomy** ([references/irreversibility.md](references/irreversibility.md)) — four-class action gating replaces role-level approval booleans.
- **Tracing spec** ([references/tracing.md](references/tracing.md)) — OpenTelemetry GenAI semantic conventions, run/role/tool span hierarchy, replay format.
- **Role versioning** ([references/versioning.md](references/versioning.md)) — semver per role, eval-gate convention.
- **Memory model** ([references/memory.md](references/memory.md)) — three-tier (persistent / per-run / per-role), checkpoint and resume.
- **AGENTS.md contract** ([references/agents-md-contract.md](references/agents-md-contract.md)) — required fields, per-role consumption.
- **MCP integration** ([references/mcp-integration.md](references/mcp-integration.md)) — tool-surface mapping to MCP servers.
- **Tool surface** in every role frontmatter — allow/deny lists, MCP servers, permission mode.
- **Verification loops** in `backend-engineer` and `frontend-engineer` — explicit edit→verify→repair with bounded attempts.
- **Single-thread pipeline** ([references/pipelines/single-thread.md](references/pipelines/single-thread.md)) — recommended default.
- **Role frontmatter schema** ([references/schemas/role-frontmatter.schema.json](references/schemas/role-frontmatter.schema.json)).
- Top-level docs: [README.md](README.md), [INSTALL.md](INSTALL.md), [USAGE.md](USAGE.md), [ARCHITECTURE.md](ARCHITECTURE.md).
- Plugin manifest at [.claude-plugin/plugin.json](.claude-plugin/plugin.json).
- Examples: [examples/AGENTS.md.template](examples/AGENTS.md.template), [examples/quickstart-spec.md](examples/quickstart-spec.md).
- Eval suite skeleton at [evals/](evals/).

### Changed

- `next_role` in role templates uses `<determined-by-pipeline>` placeholder; orchestrator resolves from active pipeline.
- `role-output.schema.json` — root `oneOf` discriminator on `role`; `unevaluatedProperties: false` per role; per-role required fields for 12 roles (release_decision, severity_counts, verdict, ci_status, etc.).
- [failure-policy.md](references/failure-policy.md) — irreversibility classes drive approval gates instead of role-level booleans.
- [orchestrator.md](references/orchestrator.md) — incorporates shared-blackboard load step and subagent-dispatch decision point.
- [trace-evals.md](references/trace-evals.md) — cross-links to tracing.md (capture) and versioning.md (regression gate).
- [SKILL.md](SKILL.md) — points to README/USAGE/ARCHITECTURE as primary entry; retains handoff contract reference.

### Migration from pre-1.0

- Hardcoded `next_role` values were replaced with placeholders. No action needed if you used the bundled orchestrator.
- Role files now require frontmatter (`version`, `tool_surface`, `permission_mode`). Custom roles must be updated.
- Per-role required handoff fields are enforced. Custom handoffs that omit them will fail validation.
- `manual_approval_requested` at role level still works but is deprecated. Use `irreversibility_class` per action ([references/irreversibility.md](references/irreversibility.md)).

## Pre-1.0

Earlier versions used hardcoded `next_role` per role and a JSON Schema with `$defs` only (no root discriminator). See git history for details.
