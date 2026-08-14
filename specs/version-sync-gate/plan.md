# Plan — version-sync-gate

> Step-4 deliverable. Single source of truth; `tasks.md` derives from this.

## Clarifications resolved (Step 3)

- **OQ-1** → `check-version-sync.sh` is a **`verify-batch` gate, marker-gated** like its peers. An
  always-on Stop hook / CI check is deferred (OQ-3) — keep this milestone one gate.
- **OQ-2** → `VersionFiles:` entry syntax: `path` (whole trimmed file) or `path:dotted.key`; array
  elements addressed as `plugins[].version`. Applies only to non-plugin projects.
- **OQ-3** → committed-manifest CI check deferred to a separate follow-on.
- **OQ-4** → on divergence, report **every** location + value and the **plurality** value; never auto-fix
  (report truth — the human bumps). No web-verify needed (no external SDK/API; jq-free string parsing).

## Architecture

No new architectural surface — a new gate slotted into the existing `verify-batch` gate list, in the
exact shape of `check-tdd` / `check-diff-coverage`:

- Sources [`bin/delivery-lib.sh`](../../bin/delivery-lib.sh) for `resolve_marker` / `field_bool`.
- **Marker-gated**: no active `intends_code` marker ⇒ exit 0 (skip), like every peer gate.
- **jq-free** field reads (anchored grep/sed), consistent with `delivery-lib.sh`.
- **Default plugin set** when `.claude-plugin/plugin.json` exists: `VERSION`, `plugin.json.version`,
  `marketplace.json.metadata.version`, and each `marketplace.json.plugins[].version`.
- **Contract override**: else parse AGENTS.md `VersionFiles:` (generic projects).
- **Skip + WARN** when neither resolves — never a false block (P6/P10, `quality-gate` parity).
- Wired into [`bin/verify-batch.sh`](../../bin/verify-batch.sh) after the existing gates.

Fitness: the gate must itself stay version-neutral (no version field of its own) and must pass on this
now-consistent repo (AC-8). `architecture_sound: true` — it is a peer of four shipped gates, same
substrate, no boundary crossed, no new dependency.

## Batch decomposition (mvp; vertical, risk-first)

- **B1 — `kind:code`, `risk_rank:feature`** — the gate itself: `bin/check-version-sync.sh`
  (default plugin set + `VersionFiles:` override + skip/WARN) with `--self-test`, wired into
  `verify-batch.sh`. This is the load-bearing code; it ships first.
- **B2 — `kind:doc`, `risk_rank:doc`** — `references/agents-md-contract.md` (`VersionFiles:`),
  `references/enforcement.md` (the layer), `CHANGELOG`, and the **version bump** to the next MINOR
  (new gate = new doctrine surface) across `VERSION` + both `.claude-plugin` manifests — which B1's own
  gate then verifies stay in sync. Doc-last; earns no delivery credit.

`risk_rank` order feature → doc is non-increasing; first batch is `kind:code` (satisfies check-delivery).

## Compliance matrix

| AC | Constitution | Verification |
|---|---|---|
| AC-1/2/3 | P8, P10 | self-test fixtures: drift → exit 1, agree → exit 0, per-`plugins[]` |
| AC-4 | P7 | `VersionFiles:` contract path, generic project fixture |
| AC-5 | P6, P10 | no version files → skip + WARN (no false block) |
| AC-6 | P3 | marker-less → skip fixture |
| AC-7/8 | P8, P10 | shellcheck + gate-integrity + wired-into-verify-batch, real-repo pass + drifted-tree fail |

## Risks

Per [spec.md](spec.md) R1–R4 (jq-free misparse → read only known fields; over-broad default → gated on
`.claude-plugin/plugin.json` presence; marker-gated drift on manual bump → OQ-1/OQ-3 future; gate stays
version-neutral → AC-8).

## Version-bump verdict (Step 1)

Asset **MINOR** (2.17.0 → 2.18.0) — a new enforcement gate (new doctrine surface). Constitution
**unchanged** (P8/P10 already govern; no new principle/exception/invariant).
