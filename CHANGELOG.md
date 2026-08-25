# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.34.0] — 2026-08-25

### Sizing reads what the spec says, not only which files it names (ADR-0019)

v2.33.x sized a milestone from the **paths** its tasks name. A spec about exactly-once distributed
payout settlement — consensus, split-brain reconciliation, irreversible money movement — sized to
`single-thread`, because it touched two files in one directory. Its `tasks.md` already declared
`⚠ architecture-reviewer` and `⚠ regression-guardian`; those were discarded too.

**Added — prose complexity.** `spec.md` and `plan.md` are scanned for five vocabularies:
security/auth · money/irreversible · data/schema · distributed/concurrency · infra/deploy. The
distributed/concurrency category is the one no path pattern can express. A hit lifts the tier and is
named in `reasons` as `prose:<category>`.

**Added — declared roles.** `⚠ <role>` markers in `tasks.md` are unioned into the required review set
per work-stream, through the existing `required_roles_for_batch` path — so a declaration reaches
`check-role-dispatch`, not just the report. Same trust model as `risk_rank` (ADR-0006): forgeable,
therefore lift-only. `⚠ code-reviewer` on an auth batch cannot shrink the set the paths earned.

**Two false positives found and closed while building this**, both by running the scan over this
repository's own specs: `ledger` matched the plugin's **batch ledger** (removed from the money
vocabulary), and markdown headings were scanned, so the stock template's `## Migration shape` lifted
**every** milestone using it (headings and `<placeholders>` are now stripped). Both pinned by fixtures.

Residual limit, stated plainly: this is vocabulary matching, not comprehension. A spec that describes
something hard in words no list contains still sizes on its paths — and the `⚠ <role>` marker is the
escape hatch that is now honoured.

## [2.33.1] — 2026-08-25

### Fixed — the tier is read by position, not by keyword search

v2.33.0 fixed one symptom of a wider defect and left the cause in place. The hook selected the
pipeline by grepping the **whole prompt** for `single-thread`/`full`/`mvp`, so any prompt merely
*containing* one of those words selected it:

```
/deliver "give the user full control over billing"   → full   (20 roles, from a sentence)
/deliver "make the mvp checkout flow work"           → mvp
```

v2.33.0 addressed only the spec-slug case (`specs/full-text-search`) by excising the path before the
grep, which did nothing for a tier word appearing in prose.

`commands/deliver.md` has always specified *"First whitespace-delimited token = `PIPELINE`"*. The hook
now implements that: it anchors on the command name and reads the single token that follows. Anchoring
on the command also removes any need to parse the JSON envelope — a tier word in `cwd`
(`/Users/x/full-stack-app`) can no longer be read as a tier, which a whole-payload grep could not
guarantee. The path-excision patch is deleted rather than layered over.

Explicit `mvp`/`full` still pin the tier; analysis pipelines still never arm a code run.

## [2.33.0] — 2026-08-25

### Spec-sourced role planning (ADR-0018)

The harness now decides which roles run by **evaluating the spec**, instead of taking the tier from the
first argument token before any spec exists.

**Fixed — passing a spec path bought the 20-role pipeline.** A path is never the literal word `mvp` or
`full`, and the unrecognized-token fallback was `full`. Every `/deliver specs/<slug>/spec.md` selected
twenty roles, mechanically. The fallback is now `auto` — the harness sizes it — and explicit
`mvp`/`full` still pin the tier.

**Fixed — the tier was decided by substring luck.** The tier was grepped from the whole prompt, so
`specs/full-text-search` bought the full pipeline. The spec path is now excised before the match.

**Fixed — Phase A re-drafted milestones that already existed.** It ran all eight steps, `speckit-specify`
included, against specs already on disk. It now splits on `spec_present`: Mode 2 runs the checking steps
(`speckit-analyze`, `architecture-reviewer`) and skips the producing ones, re-opening only the step a
reported gap actually needs.

**Fixed — two pre-existing sizing fail-opens**, both of which also affected diff-sourced sizing:
`api/routes.ts`, `models/user.py` and `.github/workflows/ci.yml` at the repository root did not escalate,
because three risk categories matched only the nested directory form; and an all-doc change tripped the
layer thresholds, buying `mvp` at two documentation files and `full` at three.

**Added** — `bin/size-from-spec.sh`, which turns an on-disk milestone into a tier and a per-work-stream
role plan by delegating to `select-pipeline.sh`'s existing classifier. New marker fields: `spec_path`,
`spec_present`, `spec_artifacts`, `tier_source`, `sizing`, `role_plan`. `check-preflight` reports
spec-artifact drift (WARN this release).

Authority order: the spec-sourced plan is a **floor**, the diff may **lift** it and never lower it, and
the ≥1 independent-reviewer invariant is untouched by either.

## [2.32.0] - 2026-08-21

> **review-loop escalation** (issue #22) — every gate here is closure-time, so the *shape* of review
> effort was invisible. A run could spend six architecture-review rounds in Phase A with **zero** closed
> batches (~900k tokens, no code), or sink 16+ dispatches into one batch while a sibling closed on 4,
> and nothing noticed until a human read `dispatch.jsonl` by hand.

### Added
- **`review_loop_signals`** — three predicates over data already recorded (`dispatch.jsonl` +
  `batches.jsonl`), surfaced in `verify-batch` output:
  - **P1** ≥3 dispatches of one role while zero `kind:code` batches have closed (and the run
    `intends_code`) — the Phase-A loop;
  - **P2** ≥8 review dispatches on a single **unclosed** batch — two full four-role fan-outs;
  - **P3** `total/closed > 8` once ≥2 closures exist — the aggregate P1 and P2 both miss, because N
    batches each costing a healthy-looking amount never trip a per-subject threshold.
  P3 is a **ratio, not a raw total**: a large milestone legitimately has many batches, so punishing
  scale would be wrong — it reports the absolute count too, since a ratio hides scale.

### Notes
- **All three are non-blocking** and run *after* `stamp_batch_closed`, so they can never gate a
  closure. Blocking a dispatch would push the orchestrator to review inline — the spec-169 collapse
  that got `attempt-budget-protocol` rejected. Reporting *is* the intervention.
- Surfaced in `verify-batch` output rather than a hook: a `PreToolUse` hook's exit-0 stderr is not
  surfaced by the harness (the open design question in #22, settled empirically).
- Verified against live data in a product repo: a batch closed on 4 dispatches stays silent; one with
  22 and still open escalates.
- Dispatch count is a **proxy** — the plugin cannot observe tokens or wall-clock (ADR-0008). It reports
  counts and the measured per-dispatch range, never a fabricated cost.

## [2.31.0] - 2026-08-21

> **harness-owned-pipeline-sizing** (ADR-0017, issue #27) — `full` stops meaning "four roles on every
> batch" and starts meaning **the harness sizes each batch**. The largest cost lever was set once, by
> hand, before any batch existed. Under-provisioning blocks; over-provisioning is reported, never
> blocked (blocking it pushes review inline — the spec-169 collapse).

### Added
- **`select-pipeline --batch <id>`** — sizes ONE batch from its own diff window (its `commit_shas`,
  else the in-flight window via `current_batch_base`) lifted by its declared `risk_rank`.
- **`required_roles_for_batch` / `record_required_roles` / `required_roles_recorded`** — the harness
  computes the review role set per batch, records it on the ledger entry, and reads it back.

### Changed
- **`select-pipeline` is two-directional**: it now reports **over**-provisioning, which used to print
  "right-sized" and say nothing.
- **`check-role-dispatch` enforces the sized set** when one is recorded (hard, regardless of
  `role_floor_mode`) and **announces** the sized set when none is — so the feature is live on every run
  without upgrading a non-adopter to hard per-role enforcement. Surplus dispatches are reported.
- **`check-review-ack` reads the same set** (N3 — the two gates must not drift).
- **Doctrine** (`commands/deliver.md`): `full` delegates sizing to the harness; reviewers flag only gaps
  affecting correctness or the stated requirements — the missing exit condition behind multi-round
  review loops.

### Invariants (unchanged)
- ≥1 independent reviewer per code batch — never sized away.
- A required role that was not dispatched fails closed.
- Legacy runs with no recorded set behave byte-for-byte as before.

### Notes
- Reaches live hooks only after a **plugin reinstall at 2.31.0**.

## [2.30.1] - 2026-08-21

### Fixed
- **Run marker was written non-atomically — a concurrent gate read could SILENTLY FAIL OPEN** (#25).
  `printf … > "$marker"` truncates then writes; 19 scripts read the marker and every fail-closed gate
  keys on `field_bool intends_code`, so a read landing in that window saw an empty marker, concluded
  "no active delivery run", and allowed. Reproduced: an empty marker makes `delivery-stop-hook` exit 0
  on a run with undelivered code. Writes now go to a temp file **beside** the marker and `mv` over it —
  `rename(2)` is atomic, so a reader sees the old marker or the new one, never a partial one (mirrors
  the ledger writer at `verify-batch.sh:114`). A failed write now leaves the previous marker intact.
  v2.29.0 had widened this window by making the Stop hook a marker *writer*.
- **`record_marker_list` accepted a non-array payload and corrupted the marker** — found by the #25
  concurrency test. The `\{*\}` check validated only the outer wrapper, so a malformed value spliced
  in verbatim and left the marker unparseable. The payload is now required to be a JSON array;
  a rejected write leaves the marker untouched.

## [2.30.0] - 2026-08-21

> **Gate execution cost** (ADR-0016, issue #23) — the economic twin of ADR-0015. A healthy `full`
> delivery of one spec measured **203 min** wall-clock, **97** of them in a single review+closure gap:
> no gate was wrong, the harness was **re-running identical work** and **serialising work with no data
> dependency**. Nothing here weakens a gate — every change removes duplicate execution or ordering.

### Added
- **`CoverageFrom: test`** (optional `AGENTS.md` field) — declares that the `Test:` run already emits
  the `CoverageFile:` artifact, so `check-diff-coverage` **reads it and runs no coverage command**:
  one instrumented suite run serves both gates instead of two. Additive — omitting it is byte-for-byte
  the previous behaviour, and an *unrecognised* value falls back to running `Coverage:` rather than
  silently taking the cheaper path.

### Changed
- **Expensive-gate result cache** — `check-mutation` and `check-diff-coverage` reuse their own previous
  output when the code under test is provably unchanged. The key covers the gate id, the declared
  command, the committed window, uncommitted tracked changes, and the **content** of every
  dirty/untracked non-ignored path. No marker (CI), no repo, no baseline, or a pathologically dirty
  tree ⇒ **execute**. Verdicts are always re-derived from the payload, so cached and fresh runs cannot
  drift.
- **The four review roles now fan out in parallel** (`commands/deliver.md`) — they read the same closed
  diff and consume none of each other's output; `roles_covered` (set-union) and
  `reviewer_dispatch_count` (count) were verified order-independent first. Each gate stays hard.
- **Re-verification after remediation is scoped to the fix diff**, not the whole batch window.

### Fixed
- **Stale-coverage fail-open** — a coverage artifact older than the code it describes could pass the
  gate silently. Reuse now fails **loud** on a stale, missing, or unlocatable artifact.

### Notes
- Reaches live hooks only after a **plugin reinstall at 2.30.0**.
- A fail-open was found *during* this work and closed: the first cut of the cache keyed on git-tracked
  state only, and this repo's own `check-mutation --self-test` caught a stale hit for a tool reading an
  untracked fixture. Untracked content is now in the key.

## [2.29.0] - 2026-08-20

> **harness-robustness** (ADR-0015) — the gates are correct on a clean greenfield but were fragile on a
> live, multi-session, real repo: they emitted *false blocking signals* from their own infrastructure
> (shell-glob, SIGPIPE-under-pipefail, JSON-whitespace, version-skew, stale markers), and the Stop-hook
> amplified each into a full-context idle turn. Two invariants: **no gate blocks on its own fragility**,
> and **a repeated identical block costs one turn, not twenty.** Sourced from two agent-written delivery
> retros. 7 of 9 work-streams delivered (WS-7 + several extras deferred — see ADR-0015).

### Fixed
- **WS-1 — glob-free `resolve_marker`/`resolve_ledger` (`bin/delivery-lib.sh`).** `ls -t .runs/*/RUN` did
  not expand under `set -f` (noglob, set by `delivery-stop-hook.sh` around its untrusted `closed_ids`
  loop) → empty marker → reviewer floor falsely "not met" → the Stop-hook false-blocked in a loop.
  Fixed with a guarded-`set +f` `_newest_run_file` (keeps `ls -t` recency). **Root of the worst loop.**
- **WS-2 — Stop-hook block de-dup (`bin/delivery-stop-hook.sh`).** A repeated identical block emits one
  terse line but **always exits 2** (fingerprint = run + block-counters + ledger content-hash in
  `reported_blocks`); a ledger change re-fires the full block. Never block→allow.
- **WS-3 — `check-completeness --final` SIGPIPE FP.** `printf … | _ac_in_tests` SIGPIPEd (141) under
  `pipefail` on a large test-file list → an asserted AC falsely reported unasserted. Fixed with a herestring.
- **WS-4 — `field_in_obj` reads pretty-printed markers (`bin/delivery-lib.sh`).** Matched only compact
  `"obj":{`; `json.dump(indent=2)` made nested `precond`/`preflight`/`enforcement` reads return empty →
  fail-closed gates silently skipped. Now whitespace/newline-tolerant.
- **WS-5 — preflight rejects a tracked `.runs/` (`bin/check-preflight.sh`).** A target repo that commits
  session markers makes `rm` Sisyphean (git restores them → re-block cascade); HARD-fails with the
  `git rm -r --cached .runs/` remediation.
- **WS-6 — plugin version-skew probe (`bin/check-preflight.sh`).** WARNs when `$CLAUDE_PLUGIN_ROOT` (live
  hooks) and the invoked bin resolve to different VERSIONs (the 2.19.1-vs-2.28.0 skew that made
  `review-types.txt` diverge and dispatches go unrecognized).
- **WS-8 — gate-integrity governed waiver (`bin/check-gate-integrity.sh`).** A run-level
  `gate_integrity_waiver` (ack/by/reason/expires) clears pre-existing green-by-skip / continue-on-error
  findings outside the batch delta **without silencing them** (findings still printed); expiry forces
  re-review; CI (no marker) still blocks.

### Notes
- The **live hooks run from the cached plugin root** — these fixes reach the live Stop/UserPromptSubmit
  hooks only after a **reinstall at 2.29.0**. `run-tests.sh` verifies the committed `bin/` directly.
- **Deferred (ADR-0015):** WS-7 characterization red-first; WS-2 race/staleness/optional evidence-stamp;
  WS-3 repo-wide SIGPIPE sweep-lint; WS-5 orphan-prune/re-arm; WS-8 full per-finding delta-scoping.

## [2.28.0] - 2026-08-20

> **pipeline-integrity-hardening** — closes the four confirmed bypass gaps the 2026-08-20 audit
> (`specs/pipeline-execution-integrity/findings.md` (local dev artifact, gitignored) A–D)
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

- **WS-E — post-delivery review hardening: closed four fail-opens the milestone's own review found (ADR-0014).**
  The independent delivery review found three of the four batches' review-fixes had relaxed into *fail-open* —
  the failure mode this milestone forbids. All fixed fail-closed, each with a fail-closed-direction test:
  - **guard-git.sh (E1)** — quoted subcommands (`git "commit"`, `git 'commit'`, `git com"m"it`, `"git" commit`)
    reached exit 0: the R5 debris allow-rule treated a quoted token as split-debris. Fixed with a **quote-aware**
    segment splitter + **de-obfuscation** (strip quotes before classifying); clean-unrecognized now fails closed.
  - **check-seam-ack.sh (E2)** — a `git status` error (corrupt index) made the dirty-tree probe emit nothing →
    read as clean → fail-open. Now **fails closed** on a git-status error.
  - **check-preflight.sh (E3)** — the toolchain probe false-HARD-failed legit projects (env-prefixed `Test:`,
    venv/PnP binaries, lockfile-without-node_modules). Now strips the `ENV=` prefix, resolves `node_modules/.bin`
    + venvs, and the lockfile↔deps check is a **WARN**.
  - **delivery-stop-hook.sh (E4)** — the run-close reviewer floor is now **per-batch** (every closed code batch
    needs its own dispatch), not "one anywhere in the run".
  - Disclosure: guard-git header now names the allow-listed mutations (`cherry-pick`/`revert`/`am`/`rebase`) that
    can land on the default branch (#6); `control-surface.txt` corrected to say verify-batch runs the *working
    tree* (#8). Retained limits (#2 forgeability ceiling, #7 `Prepare:` convention, #9 B3b scope) reaffirmed.

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

## Earlier releases

Entries for majors that are no longer current are archived one file per major, so this file stays the size of the *live* series:

- [1.x and earlier](docs/changelog/v1.md)
