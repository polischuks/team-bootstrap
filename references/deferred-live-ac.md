# Deferred-live acceptance criteria (issue #100)

Some acceptance criteria can only be exercised against a **live / P5-gated** resource — a real network
fetch, a gated external call — and cannot be asserted in an ordinary offline test run. Two gates would
otherwise trap such an AC in an unsatisfiable pair:

- [`check-gate-integrity.sh`](../bin/check-gate-integrity.sh) flags a bare `pytest.skip("AC-4 live")`
  as **green-by-skip** (a gate/invariant test that passes only because it is skipped);
- [`check-completeness.sh --final`](../bin/check-completeness.sh) still requires every `AC-N` in
  `spec.md` to be **referenced by a test** — so the AC cannot simply be dropped.

The sanctioned way out is a **governed, expiring deferral** — the same shape as the other governed
waivers (`gate_integrity_waiver`, `preflight`, `role_verdict_waiver`): a marker in the test **plus** a
governed record in the run marker. It is *not* a blanket exemption — an unmarked or ungoverned skip
still trips.

## How to defer a live/P5-gated AC

**1. Mark the deferred test.** Put a `DeferredLiveAC:` marker (naming the AC) on the skip line or the
line immediately above it:

```python
def test_live_fetch():
    # DeferredLiveAC: AC-4 — live/P5-gated, deferred to a live run
    pytest.skip("AC-4 deferred to a live run")
```

Accepted spellings (case-insensitive): `DeferredLiveAC`, `deferred_live`, `deferred-live` (so
`@pytest.mark.deferred_live` works too). The marker must sit on the skip line or the line directly
above it — exactly like the inline `gate-integrity: sanctioned` marker.

**2. Record the governed waiver.** From the active delivery run:

```
bin/check-gate-integrity.sh --waive-deferred-live <by> "<reason>" <YYYY-MM-DD-expiry>
```

This writes `deferred_live_waiver` (`{"ack":true,"by":…,"reason":…,"expires":…}`) into the run marker
via the shared `record_governed_waiver` / `governed_waiver_ok` machinery. The expiry is mandatory and
must be in the future — it forces re-review, so a deferral cannot silently become permanent. The
waiver is a single run-level record; one waiver covers the run's deferred-live ACs (the `reason`
explains which and why).

## What each gate then does

- **`check-gate-integrity`** does **not** count a `DeferredLiveAC`-marked skip as green-by-skip *while
  a valid `deferred_live_waiver` is recorded*. Only the marked skip lines are cleared; an unmarked skip
  in the same file is still a finding. With no governed waiver (or in CI, where there is no run marker)
  the marker is inert and the skip still trips.
- **`check-completeness --final`** counts the AC as **referenced**: the deferral marker in a
  spec-associated test *is* the AC's reference, again only under a valid `deferred_live_waiver`. Without
  it, a deferral with no running assertion nearby is not counted and the AC fails `--final`.

## Honest limits

A deferred-live AC is **not verified** — it is verified-later, on a governed clock. The deferral
records that a live assertion is owed and when the deferral expires; it does not prove the behaviour.
Run the live suite before the expiry, drop the deferral, and let the real assertion satisfy both gates.
