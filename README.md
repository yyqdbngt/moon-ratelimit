# Moon RateLimit

Deterministic rate-limiting and resilience primitives, implemented in MoonBit with verified decision laws.

- Repository: [https://github.com/yyqdbngt/moon-ratelimit](https://github.com/yyqdbngt/moon-ratelimit)
- Package: `123123213weqw/moon_ratelimit@0.4.0`
- License: Apache-2.0

## Implemented

Token buckets with continuous refill and exact retry-after; GCRA stated as a
theoretical-arrival-time invariant and proven equivalent to the bucket
bitwise on dyadic schedules; fixed windows (with their boundary burst
demonstrated, not hidden) and exact sliding windows over (now - window, now];
a bounded-memory sliding window counter that approximates the exact window
from `slices` ring slots, where each slot records the sub-window it was last
written for so a reused slot cannot leak a count from one full ring earlier
(no aging pass, no aliasing), with refusal retry-after pointing at the next
sub-window boundary; compose, the transactional AND of 1..8 limiters - every
limiter's pure decision is computed first and all of them consume only when
every one allowed, so a denial by one limiter burns nothing in another, and
every algorithm is now expressed as a pure decide plus a commit that the
single-limiter paths and compose share; resumable replays - every report
carries a final_state object (parameters plus the fields decide and commit
read) that can be sent back as initial_state to continue where the replay
stopped, with split-invariance checked as an algebraic law (a schedule cut
at any event, resumed, answers the unbroken replay's suffix bit for bit)
and the state operation probing a resumed limiter's free capacity;
jittered exponential backoff and a leaky bucket (the queue-side dual) in the three AWS shapes over a seeded
SplitMix64, reproducible bit for bit. Every decision is a pure function of
(state, now, weight): time is injected, never read.

## Build and run

Use MoonBit and Node.js.

```sh
moon build --target js
node _build/js/debug/build/cmd/main/main.js examples/token-bucket.json
node _build/js/debug/build/cmd/main/main.js - < examples/gcra.json
```

Pass `-` to read a UTF-8 JSON request from stdin (16 MiB cap). Success prints
one JSON object; refusals print `{"error": ...}` and exit 1; usage mistakes
exit 2. [`examples/`](examples/README.md) holds one runnable request per
capability with pinned answers.

## Library use

```moonbit
import {
  "123123213weqw/moon_ratelimit" @ratelimit,
  "moonbitlang/core/json",
}

fn example(request : Json) -> Json raise {
  @ratelimit.execute(request)
}
```

`execute(Json) -> Json raise` is the standard boundary; `run(Value)` is the
typed form. See [docs/usage.md](docs/usage.md) for every field.

## Tests

```sh
sh scripts/verify.sh          # four backends, fixtures, oracle, stats
SKIP_NATIVE=1 sh scripts/verify.sh
```

19 MoonBit test declarations across four backends with `--deny-warn`; 8 CLI
fixture cases; 4 pinned examples; an independent Python oracle that re-derives
every answer (57 checks: fixtures, random dyadic schedules, bit-exact jitter
tables); machine-checked statistics in [PROJECT_STATS.md](PROJECT_STATS.md).
See [the project proposal](docs/proposal.md) (Chinese) and
[boundaries](docs/boundaries.md).
