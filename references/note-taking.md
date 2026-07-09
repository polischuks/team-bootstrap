# Structured note-taking (context engineering)

Beyond compaction and distilled subagent returns, **structured note-taking** is the third
context-engineering lever: the agent persists progress, decisions, and open questions to a durable
note outside the context window, then reads it back after compaction. It excels for iterative
development with clear milestones — exactly the long `/deliver` / `full` runs
([Anthropic — Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), Sept 2025).

## What team-bootstrap already does

- **Compaction** — orchestrator Step 7 summarizes and reinitializes near the context limit.
- **Distilled subagent returns** — subagents explore widely but return a condensed summary
  (the enforced subagent return budget), keeping detail isolated in the subagent
  ([subagent-dispatch.md](subagent-dispatch.md)).

## The added lever: a run-notes file

For long runs the orchestrator maintains `./.runs/<run_id>-notes.md` (gitignored) — a **living
decision + progress log**, distinct from the full blackboard:

- **Decisions & their rationale** (mirrors ADRs, but per-run and lightweight).
- **What's done / in-flight / blocked** per task or batch.
- **Open questions / carry-forward** items and cross-batch wiring to remember.
- **Drift catches** surfaced during the run.

Rules:

- Append to it at each role/batch boundary; it is the first thing re-read after a compaction so no
  decision is silently lost.
- Keep it terse — it is a note, not the transcript. Full outputs live in the blackboard/artifacts.
- It is **not** a substitute for the typed handoffs or the blackboard; it is the survivable memory
  that lets a compacted or resumed run stay coherent.

Which lever when: compaction for back-and-forth flow; **note-taking for milestone-driven iterative
work**; subagents for parallel exploration ([Anthropic — Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)).
