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
