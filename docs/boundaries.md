# Version 0.1.0 boundaries

Pure decision library: time is injected with every call, so nothing reads a
clock, sleeps, or retries on its own. Wiring a real timer loop is the
caller's; the library guarantees the decisions that loop should honor.

Single-instance, in-memory, no coordination: nothing here limits across
processes; a distributed limiter needs a shared store and is out of scope.

Float arithmetic: token bucket and GCRA compute in doubles. On dyadic
parameters (the tested case - eighths of a second, quarter-token rates,
integer capacities) both paths are exact and the equivalence is bitwise;
with non-dyadic values the two round differently at the admission boundary,
which the equivalence tests document rather than hide.

Window semantics: the sliding window holds (now - window, now] - an event
ages out exactly at now - window. Weights are whole numbers on windows and
continuous on buckets. The fixed window's boundary burst (up to 2x across a
boundary) is demonstrated by test, not hidden.

SplitMix64 is deterministic and non-cryptographic; a seeded jitter table is
reproducible by design, which is the point and the limit.

The CLI is JS-only; the library supports js, wasm, wasm-gc and native.

- The leaky bucket is the queue-side dual of the token bucket with the same validation contract; both are exact in doubles on dyadic parameters.

- Fractional weights are continuous on the buckets (a weight of 0.5 against a capacity of 1 admits two events) and must be whole numbers on the windows; the refusal names the offending weight.

- The state and bulk operations describe a fresh limiter and do not model prior admissions; callers wanting stateful introspection should replay the full schedule through limit.

- All algorithms compute in doubles. On dyadic parameters (integer capacities, rates that are exact powers of two, eighth-second intervals) every path is exact. Non-dyadic values may differ in the last ulp.

- The CLI reads one JSON request from a file or stdin (16 MiB cap). Errors are one JSON object on stdout with exit 1; usage mistakes exit 2. The library boundary is execute(Json)/run(Value).

- Weight is continuous on the buckets (fractional weights are legal) and must be a whole number on the windows; the refusal names the offending weight.

- Events must be nondecreasing in time; equal instants are legal (the same-instant tests pin the semantics). Going backwards is refused.

- The bulk operation currently supports only the token bucket; extending it to other algorithms requires defining what batch admission means for each.
