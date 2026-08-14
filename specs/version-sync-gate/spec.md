# Spec — version-sync-gate

> Twice this session a release shipped with `VERSION` bumped but the plugin manifests stale
> (`v2.12.1`, `v2.17.0`: `plugin.json`/`marketplace.json` left at the previous version). The effect is
> silent and outward-facing: `claude plugin update` offers no update, and an install self-reports the
> wrong version. This milestone makes version drift a machine-caught failure, in the same marker-gated,
> git-grounded `verify-batch` style as the other gates. Delivered via `/deliver`.

## Overview

A new gate — **`bin/check-version-sync.sh`** — fails when the project's declared version-bearing fields
**disagree**. For the team-bootstrap plugin the canonical set is four fields that must be byte-equal:

- `VERSION` (trimmed),
- `.claude-plugin/plugin.json` → `version`,
- `.claude-plugin/marketplace.json` → `metadata.version`,
- `.claude-plugin/marketplace.json` → each `plugins[].version`.

It parses JSON the same jq-free grep/sed way as `delivery-lib.sh`, fails naming the divergent files and
values, and — like every gate — **skips + warns** on a project with no recognized version files (never a
false block). Wired into `verify-batch.sh` so a release-bump batch that touches one file and forgets the
others cannot close.

## In scope

- **`bin/check-version-sync.sh`** (new `verify-batch` gate):
  - Resolve the version-location set: the **default plugin set** above when `.claude-plugin/plugin.json`
    exists, else the optional AGENTS.md **`VersionFiles:`** contract (a list of `path` or `path:key`
    entries), else skip.
  - Read every field, compare for **exact equality**. Any divergence ⇒ exit 1, printing each location and
    its value and the majority/expected value. All equal ⇒ exit 0.
  - Graceful skip (exit 0 + WARN) when no version locations are resolvable.
- Wire into [`bin/verify-batch.sh`](../../bin/verify-batch.sh)'s gate list.
- Extend the AGENTS.md contract ([references/agents-md-contract.md](../../references/agents-md-contract.md))
  with `VersionFiles:` (optional; the plugin default needs no config).
- Ship `--self-test`; `shellcheck --severity=error` clean; docs in
  [references/enforcement.md](../../references/enforcement.md); version bump per P8.

## Out of scope

- **Deciding *what* the version should be** — the gate enforces that the declared fields **agree**, not
  that they equal any particular value or a git tag. (Tag ↔ manifest agreement is a separate future gate.)
- **SemVer validity / bump-correctness** — not checked here.
- **Auto-discovering every ecosystem's version file** (package.json, pyproject.toml, Cargo.toml, …) — the
  default set is the team-bootstrap plugin layout; other projects opt in via `VersionFiles:`.
- **A full JSON parser** — the known fields are read with the repo's existing grep/sed convention; deeply
  nested or exotic JSON is out of scope (documented limit).
- **Marker independence** — like the other gates it is marker-gated ⇒ in-session; CI has no `.runs/` marker
  (a committed-manifest CI check is a separate, cheap follow-on — see OQ-3).

## User stories

- **US1** — As the founder, I want a batch that bumps `VERSION` but forgets `plugin.json`/`marketplace.json`
  (or vice-versa) to **fail at close**, so a release can never ship self-reporting a stale version again.
- **US2** — As a plugin author, I want the check to work with **zero config** on the standard plugin layout,
  and to be overridable via `VersionFiles:` for a non-standard project.
- **US3** — As an engineer on a project with no version files, I want the gate to **skip with a warning**,
  never a false block.

## Acceptance criteria

- **AC-1** (US1) — With the four plugin version fields present and **any one** differing (e.g. `VERSION`
  2.17.0 while `plugin.json` 2.16.0), `check-version-sync.sh` → exit **1**, naming each location and value.
  *(Fixture: the exact v2.17.0 drift reproduced → fail.)*
- **AC-2** (US1, US2) — All four equal → exit **0**. *(Fixture.)*
- **AC-3** (US2) — A `marketplace.json` with **multiple** `plugins[]`, one entry's `version` differing from
  the rest → exit 1. *(Fixture: per-entry check, not just the first.)*
- **AC-4** (US2) — With no `.claude-plugin/` but an AGENTS.md `VersionFiles:` listing 2 files that agree →
  pass; disagree → fail. *(Fixture: generic project via the contract.)*
- **AC-5** (US3) — No `.claude-plugin/plugin.json` and no `VersionFiles:` → exit **0** with a WARN
  ("no version locations to check"). Never a false block.
- **AC-6** — Marker-gated: no active `intends_code` marker ⇒ exit 0 (skip), identical to the peer gates.
  *(Fixture: marker-less → skip.)* — pending OQ-1.
- **AC-7** — `--self-test` covers AC-1…AC-5; `check-gate-integrity.sh` clean (not green-by-skip);
  `shellcheck --severity=error bin/*.sh` clean; existing gate self-tests unregressed.
- **AC-8** — Wired into `verify-batch.sh`; running `verify-batch.sh` on this repo (now version-consistent)
  passes, and on a deliberately-drifted tree fails.

## Pre-resolutions (from this conversation — founder rulings)

- **F1** — This is a **consistency** gate (fields must agree), not a value/bump-correctness gate. The
  drift it targets is the concrete `v2.12.1`/`v2.17.0` failure: `VERSION` bumped, manifests stale.
- **F2** — **Zero-config on the plugin layout.** The default set is the four plugin fields; `VersionFiles:`
  is only for non-standard projects. No AGENTS.md entry is required for team-bootstrap itself.
- **F3** — **Never false-block.** No recognized version files ⇒ skip + WARN, exactly like `quality-gate`
  with no `Typecheck:`.
- **F4** — Same substrate: a `verify-batch` gate, jq-free JSON reads (grep/sed, as `delivery-lib.sh`),
  self-tested, portable (P7).

## Open questions (for `/deliver` Step 3 — clarify)

- **OQ-1** — Marker-gated (in-session only, like peers) **or** also an always-on Stop hook? A stale manifest
  is bad regardless of a delivery run. RECOMMENDED: verify-batch gate **and** cheap enough to also register
  on Stop for the plugin repo (opt-in). · web-verify: no.
- **OQ-2** — `VersionFiles:` entry syntax for a JSON key path. RECOMMENDED: `path` (whole trimmed file) or
  `path:dotted.key` (e.g. `package.json:version`); arrays addressed as `plugins[].version`. · web-verify: no.
- **OQ-3** — Add a committed-manifest **CI** check (version-sync on PR, independent of the marker) so a
  drifted release is caught even without an in-session run? RECOMMENDED: yes, a one-line CI step, separate
  follow-on. · web-verify: no.
- **OQ-4** — On divergence, which value is "expected" in the message? RECOMMENDED: report all values +
  the plurality value; do not auto-fix (report truth, human bumps). · web-verify: no.

## Principles compliance matrix

| AC | Constitution clause | Verification approach |
|---|---|---|
| AC-1, AC-2, AC-3 | **P8, P10** (versioned gate; fail-closed) | divergence across declared fields blocks the batch |
| AC-5 | **P6, P10** (report truth; declared ⇒ exercised) | absent version files ⇒ skip **with WARN**, no silent pass, no false block |
| AC-4 | **P7** (portable substrate) | generic projects configured by contract, not bundled tooling |
| AC-6 | **P3** (harness-enforced) | gate runs from `verify-batch`, marker-gated like peers |
| AC-7, AC-8 | **P8, P10** (versioned; declared ⇒ exercised) | self-test + gate-integrity + shellcheck; wired + demonstrably fires |

## Risks

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | jq-free JSON reads misparse an exotic manifest → false divergence | M | M | Read only the known fields with anchored grep/sed; document the limit; `VersionFiles:` lets a project point at exact keys |
| R2 | Over-broad default set false-blocks a project that intentionally versions components separately | L | M | Default set applies only when `.claude-plugin/plugin.json` exists (a plugin); everyone else opts in via `VersionFiles:` |
| R3 | Marker-gated ⇒ a direct manual bump (not via `/deliver`) still drifts | M | M | OQ-1/OQ-3: optional Stop hook + CI check; at minimum the gate catches drift on the next delivery batch |
| R4 | The gate itself must stay version-consistent | L | L | It has no version field; covered by AC-8 running on this repo |

## Dependencies

- Delivered artifacts: [`bin/verify-batch.sh`](../../bin/verify-batch.sh) gate list,
  [`bin/delivery-lib.sh`](../../bin/delivery-lib.sh) (`resolve_marker`, `field_str`, field-extraction
  convention), [`bin/quality-gate.sh`](../../bin/quality-gate.sh) (AGENTS.md `Label:` extraction).
- AGENTS.md contract ([references/agents-md-contract.md](../../references/agents-md-contract.md)) — `VersionFiles:`.
- Constitution **P8/P10/P6/P7** governing; **P8** version-bump gate.
- Delivery: this milestone is built via `/deliver` (single small gate — likely `mvp`/`single-thread` class;
  confirm with `select-pipeline.sh`).
