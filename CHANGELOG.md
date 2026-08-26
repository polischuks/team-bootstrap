# Changelog

All notable changes to team-bootstrap. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

## Earlier releases

Entries for majors that are no longer current are archived one file per major, so this file stays the size of the *live* series:

- [2.x](docs/changelog/v2.md)
- [1.x and earlier](docs/changelog/v1.md)
