# Gate taxonomy (l2p)

Domain reference for the `l2p` audit pipeline. Cited by `gatekeeper` and `gap-backlog-author`.

A gate is a discrete pass/fail threshold between funnel stages. A user clears it or leaks out. Each gate has a *qualifying criterion* — the exact, checkable condition that lets a user pass. Vague criteria ("gets onboarded") are the enemy; write criteria you could turn into an analytics event.

| Gate | Guards the transition | Qualifying criterion (pattern) | Typical leak |
|------|-----------------------|-------------------------------|--------------|
| **Attention** | Reach -> Land | User clicks through from the source surface | Weak hook, wrong audience, poor SERP/citation snippet |
| **Comprehension** | Land -> Comprehend | User can state what the product does after one screen | Jargon, buried value prop, unclear ICP |
| **Credibility / Trust** | Comprehend -> intent | User sees enough proof to believe the claim | Missing social proof, unbacked guarantees, stale logos |
| **Commitment** | Comprehend -> Sign-up | User completes auth / gives identity | Forced signup too early, heavy form, no SSO |
| **Onboarding / Setup** | Sign-up -> Activate | User reaches a usable state (>=1 configured item) within the time-to-value budget | Empty state, no guided first action, config friction |
| **Activation** | Onboarding -> first value | User completes the core job of the top use case once | Aha buried, value not delivered, dead-end path |
| **Payment** | Activate -> Convert | Checkout succeeds on the user's actual device/browser/locale | Per-environment checkout bugs, surprise pricing, currency/locale failures |
| **Retention / Habit** | Convert -> Retain | User returns for a second meaningful session | No re-engagement trigger, no reason to return |

## How to write a gate up
For each gate the `gatekeeper` states: definition, entry criterion, qualifying criterion (concrete), current pass rate (measured `I###` or `ESTIMATE`), failure modes (each tied to a `FND##` or a broken map link), the one event that would make the pass rate observable, the owner, and the single highest-leverage fix.

## Payment gate is special
It fails silently and differently per environment. Always cross-reference the funnel audit's cross-environment checks. "Checkout works" is never a global statement — it is per (device x browser x locale). Mobile Safari, in particular, is a default suspect for checkout regressions.

## Gates vs. funnel
The funnel describes the *flow* and its friction. The gates describe the *thresholds* on that flow and their pass rates. Reporting them separately is deliberate: the funnel tells you where the journey is rough; the gates tell you exactly where users are disqualified and by what criterion.
