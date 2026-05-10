# Quickstart spec — Add `/api/health` endpoint

A minimal example task brief showing the inputs team-bootstrap expects and the outputs it produces. Use this to verify your install and to model real specs after.

## Goal

Add a public `GET /api/health` endpoint to the API that returns the application's liveness state.

## Acceptance criteria

1. `GET /api/health` returns HTTP 200 with JSON: `{"status": "ok", "version": "<package version>", "uptime_seconds": <integer>}`.
2. Endpoint does not require authentication.
3. Endpoint must respond in under 50ms p99 (no DB calls; in-memory only).
4. Unit test covers the happy path.
5. Endpoint is registered in the same router as other public endpoints (see existing `packages/api/src/routes/public.ts`).

## Out of scope

- Liveness vs readiness distinction (no DB connectivity check). A separate `/api/ready` endpoint will follow.
- Metrics or tracing for this endpoint.
- Frontend changes.

## Technical notes

- Project structure: monorepo, see your project's `AGENTS.md` (template at [AGENTS.md.template](AGENTS.md.template)).
- Existing pattern: [packages/api/src/routes/public.ts](packages/api/src/routes/public.ts) defines the router; follow its style.
- Uptime: use `process.uptime()` rounded to integer seconds.
- Version: read from `packages/api/package.json` at startup; cache the value.

## Suggested invocation

For a one-off, low-risk change like this — single-thread:

```text
/team-bootstrap single-thread "Use examples/quickstart-spec.md"
```

For audit-trail demonstration (overkill for this task, but useful for verifying the install) — MVP:

```text
/team-bootstrap mvp "Use examples/quickstart-spec.md"
```

## Expected output

A run document at `./runs/<run_id>.md` with:

- Run metadata
- Phase 1 (plan): outline of files to touch (`packages/api/src/routes/public.ts`, new test file)
- Phase 2 (implement): code changes + verification (typecheck, lint, unit tests pass)
- Phase 3 (verify): release_decision: go, no blockers

For `mvp`: 7 separate role sections, each with its handoff. Same outcome, more audit trail.

## What this spec exercises

- Tool surface: implementation roles need `Edit`, `Write`, `Bash`; reviewer roles need `Read`, `Grep`, `Bash`.
- Verification loop: typecheck, lint, unit tests must all pass.
- AGENTS.md consumption: roles read `Build & Run`, `Test`, `Code Style`.
- Trace capture: every LLM call and tool call recorded with run ID.
- Schema validation: each handoff validated against [references/schemas/role-output.schema.json](../references/schemas/role-output.schema.json).
