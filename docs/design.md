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

## Rate parameter space

The rate parameter is any positive finite double. Rates below one (fractional tokens per second) are exercised by the fuzz suite; the bucket and GCRA both compute in doubles and agree bitwise on dyadic rates.

## Window semantics detail

The sliding window holds the half-open interval (now - window, now]: an event exactly at now - window has aged out. The fixed window counts per wall-clock bucket with no carry-over across boundaries, which admits up to 2x the limit through a boundary straddle.

## Backoff jitter contracts

Full jitter draws anywhere in [0, pure]; equal jitter keeps half the exponential and draws the rest; decorrelated redraws between base and 3x the previous sleep. All shapes share the same geometric growth and cap; only the draw differs.

## Decision reporting

Every limit decision reports at, allowed, retry_after and the free capacity (tokens for buckets, remaining for windows). retry_after is null when the decision is to allow and the exact seconds until a same-weight request would fit otherwise.

## Bulk arithmetic

bulk admits floor(capacity / weight) events in one step, capped at the requested count. The remainder gets retry_after = (weight - remaining) / rate. The arithmetic is exact on dyadic parameters.

## Oracle independence

The Python oracle shares no code with the MoonBit. GCRA and the leaky bucket are separately implemented; agreement on 40 random schedules per iteration is the check. The oracle also verifies bit-exact jitter tables by reproducing SplitMix64 with exact 64-bit masking.

## Determinism

Every operation is a pure function of (state, now, weight). Time is injected, never read; the same request always produces the same answer on every backend.

## Backoff table determinism

The seeded SplitMix64 reproduces the same jitter table bit for bit from the seed in the request. Seeds are 0..2^53-1; the generator is named as non-cryptographic wherever it appears.

## Cross-backend agreement

The library compiles for js, wasm, wasm-gc and native. Serializer tests pin the exact number spellings and escapes so a report written on one backend parses identically on another.
