# Reproducible-Environment Posture

> **What the plugin can and cannot do.** team-bootstrap **cannot force** a container, restricted network
> egress, or immutable managed settings — those are **user/org configuration** (devcontainer, MDM/managed
> settings, CI runners), outside a Claude Code plugin's reach (constitution P7). What it *does*: **(1) record**
> a provenance fingerprint of the build environment onto the delivery record (so "works on my machine" is at
> least a *known* fact), and **(2) recommend** the posture below. Every recommendation here is a **you/your-org
> enable it** step, not a plugin guarantee.

## Why this matters

A milestone can pass every gate and still have been built in an environment nobody can reproduce: an unknown
bash/OS, a dirty working tree, no egress limits, credentials mounted into an agent running `--dangerously-skip-
permissions`. The gates verify the *work*; this page addresses the *environment the work happened in* — the
layer above the code.

## What the plugin records (audit-only) — `repro_env`

On an armed delivery run, [`bin/check-preconditions.sh`](../bin/check-preconditions.sh) stamps a flat
`repro_env` array into the run marker (via the shipped `record_marker_list`):

```
"repro_env":["container:none","os:Darwin-arm64","bash:3.2","git:2.50","dirty:1","egress:unverified","sandbox:unknown"]
```

- `container:` — `docker` / `podman` / `k8s` / `codespaces` / `devcontainer` / `none`. Detected from
  `/.dockerenv`, `/run/.containerenv`, `/proc/1/cgroup`, and the `CODESPACES`/`REMOTE_CONTAINERS`/`DEVCONTAINER`
  env hints. **Linux-centric**: on macOS bare-metal the positive signal is unavailable, so it reports `none`
  ("not detected here", never "definitely bare-metal").
- `os:`/`bash:`/`git:`/`dirty:` — toolchain/OS fingerprint + `git status --porcelain` line count (provenance).
- `egress:unverified` **always** — egress restriction is **not observable** in jq-free bash without a
  side-effectful outbound probe (slow, non-deterministic, forbidden in a fast gate). Recorded honestly as
  unverified, never guessed.
- `sandbox:unknown` **always** — the sandbox config is not readable from a bash hook.

**This is an audit record, not a gate.** `check-delivery`/`verify-batch` never read `repro_env`; a weak posture
(no container, dirty tree) **still closes clean** — the fidelity default is your *real* repo (below). Disable
the stamp with `TEAM_BOOTSTRAP_REPRO_ENV=off`.

## Recommended posture (you/your org configure this — the plugin cannot)

### 1. A reference devcontainer

Pin the toolchain so a delivery doesn't depend on the client's machine. See
[`.devcontainer/devcontainer.json`](../.devcontainer/devcontainer.json) in this repo as a starting example.

```jsonc
// .devcontainer/devcontainer.json — EXAMPLE (repo/org config, NOT plugin enforcement)
{
  "name": "team-bootstrap",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/anthropics/devcontainer-features/claude-code:latest": {}
  },
  "postCreateCommand": "bash .devcontainer/init-firewall.sh",
  "remoteUser": "vscode"          // non-root; do NOT mount host credentials
}
```

> The plugin cannot require a devcontainer — there is no `plugin.json` field for it. This is your repo's config.

### 2. Default-deny egress allowlist (`init-firewall.sh`)

Restrict the agent's network to what delivery actually needs. Needs `NET_ADMIN`/`NET_RAW` (a container/host
capability, not a plugin lever):

```bash
# init-firewall.sh — EXAMPLE default-deny egress allowlist (needs NET_ADMIN; you enable it)
iptables -P OUTPUT DROP
for host in github.com api.anthropic.com registry.npmjs.org; do
  for ip in $(dig +short "$host"); do iptables -A OUTPUT -d "$ip" -j ACCEPT; done
done
iptables -A OUTPUT -o lo -j ACCEPT
```

> **Caveat (finding #4):** the sandbox proxy **does not terminate TLS**, so a broad allowlist entry like
> `github.com` is **domain-frontable** — an allowlist reduces, but does not eliminate, exfil risk. Scope it as
> tightly as delivery allows.

### 3. Managed-settings floor (org)

The strong floor is **managed settings** (MDM-deployed, user-immutable) — an org lever, not a plugin one:

```jsonc
// managed-settings.json — EXAMPLE org config (immutable; the plugin CANNOT set this)
{
  "sandbox": { "failIfUnavailable": true },        // refuse to run if the sandbox isn't available
  "egressAllowlist": ["github.com", "api.anthropic.com"],
  "credentialIsolation": true                        // do not expose ~/.ssh, ~/.claude, cloud creds
}
```

### 4. Credential isolation under `--dangerously-skip-permissions`

Fire-all / unattended runs (`--dangerously-skip-permissions`) remove the human-in-the-loop that otherwise
catches an exfil attempt. Do **not** mount `~/.ssh`, `~/.claude`, or cloud credentials into such a run; run
non-root; combine with the egress allowlist above.

## Fidelity vs. reproducibility (why gates default to your real repo)

A fresh per-run container maximizes reproducibility — but it runs a **clean checkout**, which **masks bugs that
only reproduce on the user's actual (dirty, half-configured) state**. That contradicts closure fidelity. So
team-bootstrap's gates deliberately default to your **real** repo; the container is the **opt-in escalation**
tier for when you need a clean-room, not a mandate. `repro_env` *records* whether you're in one — it does not
push you into one.

## Cloud escalation tier (named, not shipped)

For fully-isolated ephemeral execution, hosted sandboxes (e2b, Modal, Daytona) are the escalation beyond a local
devcontainer. team-bootstrap does not bundle a runtime (P7); this is the tier to reach for when a devcontainer
isn't isolation enough.

## Cross-vendor convention (not invented here)

- **Codex** — setup online, then agent runs **offline** in an isolated microVM.
- **GitHub Copilot** — ephemeral container + restrictive firewall + `copilot-setup-steps.yml`.
- **Cursor** — `.cursor/environment.json`.
- **Dev Containers** — the portable `devcontainer.json` spec.

Every one of these is **environment config the tool recommends and the user/org enables** — the same honest
boundary this page draws.
