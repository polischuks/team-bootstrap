# 0004 — Version consistency is a harness gate, not a release-checklist item

- **Status:** Accepted
- **Date:** 2026-08-14
- **Constitution clause(s):** P8, P10, P6, P7

## Context

The plugin's version is declared in four places that must agree: `VERSION`, `.claude-plugin/plugin.json`
`version`, and `marketplace.json` `metadata.version` + each `plugins[].version`. A release that bumps one
and forgets the others is **silent and outward-facing**: the installed plugin self-reports the old
version and `claude plugin update` offers no update.

This is not hypothetical — the framework shipped it **twice** in one development stretch:

- **v2.12.1** — `VERSION` bumped, `plugin.json` left at `2.11.0` (caught only when a plugin install
  self-reported the wrong version).
- **v2.17.0** — the `/deliver` release batch bumped `VERSION` → 2.17.0 but left both `.claude-plugin`
  manifests at `2.16.0`; caught only by a post-release `claude plugin update` that saw no new version.

Both were "remembered to bump the version" failures — the exact class prose checklists don't stop
(~70% adherence), and neither the code-clean gates nor `check-delivery` look at version fields.

## Decision

Make version drift a **machine-caught failure** in the same substrate as the other delivery gates:
[`bin/check-version-sync.sh`](../../bin/check-version-sync.sh), a `verify-batch` gate that collects every
declared version field and **fails when they disagree**.

- **Default (a plugin):** `VERSION` + `plugin.json.version` + every `"version"` in `marketplace.json`.
- **Otherwise:** an AGENTS.md `VersionFiles:` list (`path` or `path:key`) — for non-plugin projects (P7).
- **Neither:** skip + WARN — never a false block (P6/P10, `quality-gate` parity).
- Divergence prints every location + value and the plurality value; **no auto-fix** — the human bumps
  (report truth). jq-free (grep/sed), marker-gated ⇒ in-session.

## Consequences

- A release-bump batch that touches one file and forgets the others **cannot close** — the drift that hit
  v2.12.1/v2.17.0 is now structurally impossible in a delivery run.
- The gate has **no version field of its own**, so it cannot drift; it dogfooded its own milestone (B2's
  bump to 2.18.0 closed only because all four fields agreed).

## Alternatives considered

- **A release checklist / prose in `deliver.md`** — rejected: this is precisely the ~70%-adherence prose
  that failed twice.
- **An always-on Stop hook + a committed-manifest CI check** — deferred (OQ-1/OQ-3): a manual bump outside
  a delivery run still drifts until the next batch. Cheap follow-ons, not this milestone.
