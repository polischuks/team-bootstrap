# AGENTS.md — team-bootstrap delivery contract

Machine-read by the harness gates (`bin/quality-gate.sh`, `bin/check-tdd.sh`,
`bin/check-enforcement.sh`, …). Commands are the backticked token on each `Label:` line.

## Test / quality commands

- Test: `bin/run-tests.sh`
- TestGlobs: `bin/*.test.sh tests/*.test.sh`
- Lint: `shellcheck --severity=error bin/*.sh`
- Prepare: `N/A`
- Runtime: `bash`, `python3`
  <!-- No dependency INSTALL step: nothing is vendored and there is no lockfile to provision, so the
       Phase-0 readiness gate (check-preflight, WS-B) has nothing to resolve beyond the Test: binary.
       But the suite is not pure bash and has not been for some time: seven bin/*.sh shell out to
       python3 for the jobs a regex cannot do (JSON parsing in record-dispatch and check-role-verdict,
       skip-call classification in check-gate-integrity). check-gate-integrity now fails CLOSED when
       python3 is missing rather than reporting OK while blind, which turns an undeclared dependency
       into a red suite — so it is declared here instead of discovered on a host without it. -->

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
  This gives the red-first gate (`bin/check-tdd.sh --record-red` → `bin/check-tdd.sh`) a runnable suite on
  team-bootstrap's own delivery runs.
- All `bin/*.sh` carry an embedded `--self-test`; CI additionally runs `shellcheck --severity=error`.
- **Phase-0 gate:** `bin/check-preflight.sh` is the setup-readiness gate `/deliver` runs before Phase A
  (setup-readiness, vs `check-preconditions.sh`'s end-of-Phase-A deliverability). Its E2E: on a fully
  scaffolded repo it exits 0; on a bare `git init` dir it exits 1 with the named scaffold gaps. It records
  a `preflight` verdict that `check-delivery.sh` enforces at batch-announce time.
