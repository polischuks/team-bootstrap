# ADR-0021 — Containment posture: open permissions, gated irreversibility, no sandbox

- **Status:** Accepted
- **Date:** 2026-08-26
- **Milestone:** `specs/020-live-roles-and-harness-wiring` (AC-34)
- **Supersedes:** nothing. Records a choice the project had made implicitly since v1.

## Context

The harness literature (arXiv:2606.10106) gives a four-condition test, of which **T4** — at least one
control mechanism whose effectiveness does not depend on the model's cooperation — is the one a policy
layer can own. It also sets the bar sharply: a log line does not satisfy T4, because it does not change
what executes.

OpenHands is the reference implementation of the strongest available form: **sandboxed execution**.
Every action runs in an isolated container, so the control holds whatever the model decides to do.

team-bootstrap has never chosen a position on that axis in writing. `SECURITY.md` described what the
project executes, and `references/irreversibility.md` described what it gates, but the question
*"open permissions or containment, and why"* was answered only by what the code happened to do. An
unstated posture is one nobody can disagree with, which is a bad property for a security decision.

## Decision

**No sandbox. Open permissions, with irreversibility gated at the harness boundary.**

The controls that satisfy T4 here are:

1. **Blocking hooks.** `guard-git.sh` on `PreToolUse[Bash]` refuses a default-branch write and escalates
   a published-history rewrite to a human via `permissionDecision: "ask"`. `quality-gate.sh` and
   `delivery-stop-hook.sh` on `Stop` refuse completion. All exit **2** — the only blocking exit code.
2. **Closure from git state** (ADR-0002). A batch closes against commits reachable from HEAD and after
   the run baseline. The model cannot assert its way past this; it is read from the repository.
3. **Tool-surface denial per role.** Every review role denies `Write`/`Edit` in its playbook, enforced
   structurally by `bin/check-role-triples.sh` and asserted by the anti-builder invariant in
   `references/review-types.txt`.
4. **Permissions**, where a prohibition must be hard. A hook `if:` filter is best-effort and fail-open
   by vendor design; `permissions` is the mechanism for a real prohibition.

## Why not a sandbox

Not because containment is worse — it is stronger, and the ADR should say so plainly.

- **It is not this layer's to give.** T1 and T2 belong to Claude Code. A policy layer cannot isolate an
  execution environment it does not own, and simulating one in prose would be exactly the substitution
  this project's design rule forbids. If Claude Code gains a sandbox, adopting it is a configuration
  change, not a redesign.
- **The target workflow is editing the user's own repository with the user's own credentials.** A
  sandbox that cannot reach the working tree does not run the gates; one that can reach it provides
  isolation from the network and the wider filesystem, not from the thing actually at risk.
- **The bounded risk is different from the one a sandbox addresses.** The real trust boundary here is
  that gates `eval` commands read from the *target repository's* `AGENTS.md` (`quality-gate.sh`,
  `check-tdd.sh`, `check-diff-coverage.sh`, `check-mutation.sh`). That is a supply-chain risk of
  opening a session in an untrusted repository, and it is addressed by reading `AGENTS.md` before
  opening the session — which `SECURITY.md` states — not by a container.

## Consequences

- **Accepted:** a repository whose `AGENTS.md` the user has not read can execute arbitrary commands
  through the `Stop` hook without a prompt. This is stated in `SECURITY.md` as the trust boundary; it
  is not mitigated, it is disclosed.
- **Accepted:** the posture is weaker than OpenHands' on the T4 axis, and this ADR says so rather than
  claiming parity.
- **Available now:** an organisation that wants a harder floor deploys managed policy settings with
  `allowManagedHooksOnly` plus `permissions` (see `INSTALL.md`) — user-unoverridable, and the strongest
  containment this layer can reach without owning the runtime.
- **Revisit when:** Claude Code ships a first-class sandboxed execution mode, or the project acquires a
  runtime of its own (which P7 currently forbids).
