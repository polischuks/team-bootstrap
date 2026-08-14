# Tasks — version-sync-gate

> Derived from [plan.md](plan.md). Every AC maps to ≥1 task.

## B1 — the gate (`kind:code`, `risk_rank:feature`) — CLOSED (a6d852a)

- [x] **T001** — `bin/check-version-sync.sh`: resolve the version-location set (default plugin set when
  `.claude-plugin/plugin.json` exists; else AGENTS.md `VersionFiles:`; else skip+WARN). *(AC-5)*
- [x] **T002** — read `VERSION`, `plugin.json.version`, `marketplace.json.metadata.version`, each
  `marketplace.json.plugins[].version` jq-free; compare for exact equality. *(AC-1, AC-3)*
- [x] **T003** — divergence → exit 1 naming each location + value + plurality; all equal → exit 0. *(AC-1, AC-2, AC-4)*
- [x] **T004** — marker-gated: no active `intends_code` marker ⇒ exit 0 skip. *(AC-6)*
- [x] **T005** — `--self-test` covering AC-1…AC-5 (drift, agree, per-plugins[], VersionFiles agree/disagree, skip+WARN). *(AC-7)*
- [x] **T006** — wire into `bin/verify-batch.sh`; `shellcheck` clean; `check-gate-integrity` clean; self-tests unregressed; verify-batch on this repo passes with the new gate. *(AC-7, AC-8)*

## B2 — docs + version bump (`kind:doc`, `risk_rank:doc`)

- [ ] **T007** — `references/agents-md-contract.md`: add `VersionFiles:` (syntax per OQ-2).
- [ ] **T008** — `references/enforcement.md`: add the version-sync layer.
- [ ] **T009** — `CHANGELOG` `[2.18.0]`; bump `VERSION` + `plugin.json` + `marketplace.json` (metadata + plugins[]) to 2.18.0 — which B1's gate then verifies stay in sync.
- [ ] **T010** — ADR-0004 (version-sync gate); final sweep (shellcheck, self-tests, links).

## Coverage check

Every AC (1–8) is covered by ≥1 task. No orphan ACs; no task without an AC.
