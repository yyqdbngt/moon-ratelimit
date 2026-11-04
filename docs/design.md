# Implemented architecture

## Core

Four limiters behind one replay entry point: token bucket (continuous refill,
injected time), GCRA (theoretical arrival time, the invariant
tokens(now) == capacity - rate * max(0, tat - now) stated where the state
lives), fixed window (per-wall-clock counting) and exact sliding window
(half-open trailing interval). Backoff computes seeded jitter tables over
SplitMix64. Everything is a pure function of (state, now, weight); there is
no clock, no IO and no global state.

## Verification

White-box laws pin each algorithm's arithmetic, including the GCRA-bucket
equivalence as a bitwise law on dyadic schedules. An independent Python
oracle re-derives every answer from the request alone and agrees on the
fixtures, on random dyadic schedules and on bit-exact jitter tables. The CLI
fixtures and the four shipped examples run through the real binary, the
examples against pinned answers; PROJECT_STATS.md is machine-recounted; the
ladder runs four backends with --deny-warn.

## Bulk and state

The bulk operation answers "how many of this weight fit right now" in one
arithmetic step (admitted = floor(capacity / weight), capped at the requested
count) and names the exact retry_after for the remainder. The state operation
reports free capacity at an instant without admitting; on a fresh limiter
the answer is always the full capacity. Both share the validation contract
with limit; bulk currently supports only the token bucket.


## The queue-side dual

The leaky bucket is the token bucket seen from the queue side: both share the same rate and capacity. The token bucket admits when enough tokens have accumulated; the leaky bucket admits when the queue can absorb the pour. The duality test runs the same schedule through both and asserts identical admission counts.

## Verification architecture

Five layers cover every algorithm: white-box laws (MoonBit tests), CLI
fixtures (through the compiled binary), an independent Python oracle (same
algorithms separately written), a malformed-input sweep, and machine-checked
statistics. The oracle's GCRA and leaky-bucket implementations share no code
with the MoonBit; agreement on random schedules is the check.
