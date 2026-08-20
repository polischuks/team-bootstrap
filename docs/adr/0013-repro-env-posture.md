# 0013 — Reproducible-env posture: the plugin recommends + detects, it does not force

- **Status:** Accepted
- **Date:** 2026-08-19
- **Constitution clause(s):** P3, P7, P11
- **Related:** [0010](0010-preflight-setup-gate.md) (setup-readiness), [0011](0011-branch-protection-gate.md)
  (P5 at the harness), [0012](0012-control-surface-protection.md) (control-surface seam),
  [irreversibility.md](../../references/irreversibility.md), [repro-env-posture.md](../../references/repro-env-posture.md)

## Context

The founder's requirement #2 — "provision a container with the plugin's required tools so delivery doesn't
depend on the client environment" — and audit findings #4/#6 (egress/credential exfil under fire-all; the
managed-settings floor) all point at the layer *above* the code: the environment a milestone is built in. A
delivery can pass every gate and still have run on an unknown bash/OS, a dirty tree, with unrestricted egress
and credentials mounted into a `--dangerously-skip-permissions` agent — the classic "works on my machine" hole,
one level up.

But a Claude Code **plugin cannot force** a container, restricted egress, or immutable managed settings — those
are user/org configuration (devcontainer.json, MDM/`managed-settings.json`, `init-firewall.sh` needing
`NET_ADMIN`, CI runners), squarely in the P7 "org tooling outside the plugin" space. Overreaching into a "you
must be in a container" gate would be both infeasible (`plugin.json` has no such field) and **wrong** — it would
false-block every local maintainer, contradicting the fidelity default (gates run against the user's *real*
repo; findings §2/§5).

An earlier draft proposed a standalone `bin/check-repro-env.sh` recorder. Independent review found it
**architecturally sound but unconsumed** — `check-delivery` never reads `repro_env`, so a standalone script is
"machinery whose only reader is a human eyeball on the marker." The verdict: `DEGRADE-TO-DOC-ONLY` — ship the
posture doc (the real value) and, if anything, fold the fingerprint into an *already-consumed* gate rather than
stand up a new artifact.

## Decision

Two honest, in-reach contributions:

1. **Record provenance (audit-only), folded into the already-consumed `check-preconditions`.** On an armed
   `intends_code` run, [`bin/check-preconditions.sh`](../../bin/check-preconditions.sh) stamps a flat `repro_env`
   array (`container:` / `os:` / `bash:` / `git:` / `dirty:` + the honest non-observables `egress:unverified`,
   `sandbox:unknown`) via the shipped `record_marker_list`. It is **exit-preserving** — a pure addition that
   never touches the gate's exit codes and never blocks — and **audit-only**: `check-delivery`/`verify-batch`
   never read `repro_env`. Container signals take injectable `REPRO_*` overrides (testable without root/Docker);
   a `TEAM_BOOTSTRAP_REPRO_ENV=off` kill-switch skips it. **No new `bin/` artifact** (round-1: a standalone
   recorder would be unconsumed).
2. **Recommend the posture (doc + example).** [`references/repro-env-posture.md`](../../references/repro-env-posture.md)
   ships the reference devcontainer + default-deny `init-firewall` egress allowlist + managed-settings floor
   (`failIfUnavailable`, egress allowlist, credential isolation) + the fire-all credential-exfil warning
   (incl. the no-TLS-termination/domain-fronting caveat) + the fidelity-vs-reproducibility tension. Each carries
   a **"the plugin cannot force this — you/your org enable it"** note. A `.devcontainer/devcontainer.json`
   example ships as adoptable repo config, not enforcement.

## Disclosed limits (P11)

- **`egress:unverified` always** — egress restriction is not observable in jq-free bash without a
  side-effectful outbound probe (slow, non-deterministic, forbidden in a fast gate). Hard enforcement is
  managed-settings/`init-firewall` (org).
- **`sandbox:unknown` always** — the sandbox config is not readable from a bash hook.
- **Container detection is Linux-centric + one-directional** — on macOS bare-metal (verified) the positive
  signal is unavailable, so it reports `none` ("not detected here", never "definitely bare-metal").
- **The examples are user/org config the plugin cannot force** — devcontainer, firewall, managed settings.
- **Why audit-only, not a gate** — a hard "must be in a container" block would false-fail every local
  maintainer; the fidelity default is the user's real repo, and the container is an opt-in escalation tier.

## Consequences

The build environment of a milestone becomes a **recorded fact** on the closure record instead of unknown, and
the recommended reproducible-env posture is **documented** rather than absent — the two things in reach.
Enforcement (container/egress/managed-settings) remains the org's job, now honestly named as such. No new
constitution invariant (P7 posture + P3 provenance); asset **MINOR → 2.27.0**. Capstone of the
`pipeline-execution-integrity` program — the "documentation + posture" tier the other five items escalate to.
