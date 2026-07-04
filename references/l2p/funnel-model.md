# Funnel model & scoring (l2p)

Domain reference for the `l2p` audit pipeline. Cited by `funnel-auditor` and `gap-backlog-author`.

## The seven stages
Adapt names to the product, but every audit maps to these seven transitions. Each stage has one intended user action and one gate guarding the exit (see [gate-taxonomy.md](gate-taxonomy.md)).

1. **Reach** — the user encounters the product (ad, search, AI citation, referral). Exit action: click through to the landing.
2. **Land** — first paint of the landing. Exit action: stay past the fold instead of bouncing. Watch first-paint speed and above-the-fold clarity.
3. **Comprehend** — the user understands what this is and whether it's for them. Exit action: read enough to form intent.
4. **Sign-up** — the user commits an identity (account, email, auth). Exit action: complete auth.
5. **Activate** — the user reaches first delivered value ("aha"). Exit action: complete the one thing the top use case is about. This is the most important and most under-instrumented stage.
6. **Convert / Pay** — the user pays or crosses the primary business threshold. Exit action: successful checkout. Fails per-environment (device/browser/locale) — never audit this stage on one environment only.
7. **Retain** — the user comes back and forms a habit. Exit action: a second meaningful session.

## Instrumentation-first
For every stage, the first question is not "how big is the drop-off" but "can we even see the drop-off here". An unmeasured stage is a finding in itself. A drop-off number without a backing event is a HYPOTHESIS, not data.

## ICE scoring (the single ranking metric)
Every finding gets three 1-5 scores:
- **Impact** — how much conversion moves if fixed.
- **Confidence** — how sure we are the problem is real and the fix works (evidence-backed = high; hypothesis = low). This axis is why ICE is the chosen metric for l2p: it directly encodes the grounding/evidence discipline.
- **Ease** — how cheap the fix is (5 = trivial, 1 = major build).

`ICE = Impact x Confidence x Ease` (max 125). Sort all findings by ICE descending. The final backlog leads with the top of this list. Ties broken by Impact. Do not substitute other rankings (e.g. severity × reach × effort) — the pipeline standardizes on ICE so scores compose across `funnel-auditor` findings and `gap-backlog-author` tasks.
