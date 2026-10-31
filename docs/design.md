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
