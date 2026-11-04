# Request and result guide

Every request is one JSON object; every answer is one JSON object. Times are
seconds (finite doubles, nonnegative, nondecreasing across events); weights are
admission costs. Failures return `{"error": "<message>"}`.

## limit

Replays an event schedule through one limiter and reports every decision.
Time is passed in, never read: a replay is deterministic and reproducible on
every backend.

```json
{
  "algorithm": "token_bucket",
  "rate": 1,
  "burst": 2,
  "events": [{"at": 0}, {"at": 0}, {"at": 0}]
}
```

| Algorithm | Parameters | Weight | Notes |
|---|---|---|---|
| token_bucket | rate (tokens/s), burst (capacity) | continuous, ≤ burst | refills continuously, caps at burst |
| gcra | rate, burst | continuous, ≤ burst | equivalent to the bucket by law, not by hope |
| fixed_window | limit, window_seconds | whole, ≤ limit | counts per wall-clock window; the boundary flaw below |
| sliding_window | limit, window_seconds | whole, ≤ limit | exact trailing window (now - window, now] |

Decision fields: `at`, `allowed`, `retry_after` (seconds; null when allowed;
the exact moment a same-weight request fits), and `tokens` (buckets; free
tokens after the event) or `remaining` (windows; free slots after the event).
Reports end with `events`/`allowed`/`denied`/`allowed_weight` and echo the
parameters.

A weight above the burst or limit is refused up front as never admissible
rather than answered with an infinite retry. The fixed window admits up to
2x the limit across a boundary (pinned by test against the sliding window on
the same schedule); choose the sliding window when that matters.

## backoff

Computes a retry delay table.

```json
{
  "operation": "backoff",
  "base_ms": 100,
  "multiplier": 2,
  "max_ms": 800,
  "jitter": "none",
  "attempts": 6,
  "seed": 0
}
```

| Field | Contract |
|---|---|
| base_ms | whole 1..3600000 |
| multiplier | within (1, 10); default 2 |
| max_ms | whole base_ms..3600000; default 30000 |
| jitter | none / full / equal / decorrelated; default none |
| attempts | whole 1..64 |
| seed | whole 0..2^53-1; default 0 |

Jitter shapes: none is the pure geometric table capped at max_ms; full draws
in [0, pure]; equal keeps half the exponential and draws the rest;
decorrelated redraws between base and 3x the previous sleep (AWS shapes). The
generator is SplitMix64 seeded from the request - the same seed reproduces the
same table bit for bit - and is not a cryptographic primitive. The report
carries `delays_ms` and `capped_attempts`.

## Exit codes

Success exits 0; a refused request exits 1 with one `{"error"}` object; a
usage mistake (wrong argument shape) exits 2.

## state

Reports the limiter's free capacity at an instant without admitting.

```json
{"operation": "state", "algorithm": "token_bucket", "rate": 1, "burst": 5, "at": 10}
```

Returns `algorithm`, `at`, `free` and `capacity`. On a fresh limiter `free`
equals `capacity`; the operation shares the same validation as limit.

## bulk

Batch admission on the token bucket: how many of a repeated weight fit now.

```json
{"operation": "bulk", "rate": 1, "burst": 5, "at": 0, "weight": 2, "count": 4}
```

Returns `admitted` (floor of capacity/weight, capped at count), `denied`,
`retry_after` (seconds until the next admission; null when all admitted) and
`remaining_tokens`. `weight` must not exceed `burst`; `count` is 1..1000.

## leaky_bucket

The queue-side dual of the token bucket: capacity units of queue draining at `rate` per second. An event pours `weight` units in; denied when it would overflow.

```json
{"algorithm": "leaky_bucket", "rate": 1, "burst": 2, "events": [{"at": 0}, {"at": 0}, {"at": 3}]}
```

## sliding_window_counter

The bounded-memory approximation of the exact sliding window: the window is
divided into `slices` sub-windows (2..1000, default 10) kept as ring slots.
Admission sums the `slices` sub-windows ending at the current one, which
covers (now - window, now] with an error of at most one sub-window's count.
Each slot records the sub-window it was last written for, so a reused slot
reads as zero instead of leaking a count from one full ring earlier; there is
no aging pass. A refusal's retry_after is the distance to the next sub-window
boundary, the earliest moment the summed range can shift.

```json
{"algorithm": "sliding_window_counter", "limit": 2, "window_seconds": 1, "slices": 4,
 "events": [{"at": 0}, {"at": 0}, {"at": 0.3}]}
```

## compose

Several limiters, one schedule, transactional admission: an event is
admitted only when every limiter would admit it, and then every limiter
consumes it; a refusal by one limiter burns nothing anywhere. A denied
event reports the longest of the refusals (the event must outwait the
slowest limiter) and the smallest remaining capacity across limiters. A
compose of one limiter answers exactly what running that algorithm alone
answers, which the fuzz checks schedule by schedule.

```json
{"operation": "compose",
 "limiters": [{"algorithm": "fixed_window", "limit": 2, "window_seconds": 2},
              {"algorithm": "token_bucket", "rate": 1, "burst": 2}],
 "events": [{"at": 0}, {"at": 0}, {"at": 0.5}, {"at": 2.5}, {"at": 2.5}]}
```

`limiters` lists 1..8 specs, each an `algorithm` plus that algorithm's
parameters (`slices` included for the counter). A schedule mixing window
limiters with buckets carries whole-number weights only, because windows
count events. The state and bulk operations stay single-algorithm.

## Resumable replays

Every limit and compose report ends with a `final_state` object: the
algorithm with its parameters plus the fields decide and commit read -
bucket tokens and last refill time, GCRA's theoretical arrival time, the
fixed window's index and count, the sliding window's remembered entries,
the counter's ring arrays, or one state object per limiter for compose.
Sending it back as `initial_state` continues the replay exactly where it
stopped, and the parameters inside the state must equal the request's, so
a resumed replay cannot quietly run different law.

The property this buys is checked as an algebraic law: a schedule split
at any event, resumed from the prefix's final_state, answers the
unbroken replay's remaining decisions bit for bit and lands on the same
final_state - for every algorithm and for compose, over random schedules.
The state operation also accepts `initial_state` and reports the resumed
limiter's free capacity at an instant, which is a zero-weight decide.

```json
{"algorithm": "token_bucket", "rate": 1, "burst": 2,
 "initial_state": {"algorithm": "token_bucket", "rate": 1, "burst": 2,
                   "tokens": 0, "last": 1},
 "events": [{"at": 2}, {"at": 2}]}
```

Malformed states are refused by name - wrong algorithm tag, parameter
mismatch against the request, tokens or counts outside their ranges,
ring arrays that do not match `slices`, entries out of order.

## All algorithms

Six algorithms share one request shape: token_bucket, gcra, leaky_bucket, fixed_window, sliding_window and sliding_window_counter. Each takes its own parameters (rate and burst for the buckets, limit and window_seconds for the windows, plus slices for the counter) and returns per-event decisions with allowed, retry_after and free capacity.

## Validation summary

Rate and burst must be positive; limit must be a positive whole number; window_seconds must be positive; slices must be a whole number 2..1000; weights are continuous on buckets and whole on windows; events must be nondecreasing in time; and every unknown field is rejected by name.
