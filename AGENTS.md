# AGENTS.md — team-bootstrap delivery contract

Machine-read by the harness gates (`bin/quality-gate.sh`, `bin/check-tdd.sh`,
`bin/check-enforcement.sh`, …). Commands are the backticked token on each `Label:` line.

## Test / quality commands

- Test: `bin/run-tests.sh`
- TestGlobs: `bin/*.test.sh tests/*.test.sh`
- Lint: `shellcheck --severity=error bin/*.sh`
- Prepare: `N/A`
  <!-- pure-bash project: no dependency install step. The Phase-0 readiness gate (check-preflight, WS-B)
       resolves the Test: binary (bash) on PATH; there is no lockfile to provision. -->

> **Coverage / Mutation — intentionally NOT declared.** There is no bash coverage or mutation tool
> on this host (`bashcov`/`kcov`/`bats` absent), and a declared-but-toolless `Coverage:`/`Mutation:`
> command is exactly the *vacuous gate* this project exists to forbid — `check-enforcement` would clear
> the gap while `check-diff-coverage`/`check-mutation` silently WARN-skip. Instead, those two
> enforcement dimensions stay **honestly recorded as gaps** and are covered by a **governed, expiring
> enforcement waiver** in the run marker (dated, scoped, re-acknowledged each milestone — never a
> perpetual free pass). See [references/enforcement.md](references/enforcement.md). Substantive
> coverage/mutation enforcement is for *target* projects that ship those runners.

## Notes

- `Test:` runs every `bin/*.sh --self-test` and every `tests/*.test.sh`; non-zero on any failure.
  This gives the red-first gate (`bin/tdd-red.sh` → `bin/check-tdd.sh`) a runnable suite on
  team-bootstrap's own delivery runs.
- All `bin/*.sh` carry an embedded `--self-test`; CI additionally runs `shellcheck --severity=error`.
- **Phase-0 gate:** `bin/check-preflight.sh` is the setup-readiness gate `/deliver` runs before Phase A
  (setup-readiness, vs `check-preconditions.sh`'s end-of-Phase-A deliverability). Its E2E: on a fully
  scaffolded repo it exits 0; on a bare `git init` dir it exits 1 with the named scaffold gaps. It records
  a `preflight` verdict that `check-delivery.sh` enforces at batch-announce time.
