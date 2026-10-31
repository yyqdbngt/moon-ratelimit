# Moon RateLimit

Deterministic rate-limiting and resilience primitives, implemented in MoonBit with verified decision laws.

- Repository: [https://github.com/yyqdbngt/moon-ratelimit](https://github.com/yyqdbngt/moon-ratelimit)
- Package: `yyqdbngt/moon_ratelimit@0.1.0`
- License: Apache-2.0

## Implemented

In progress: the JSON boundary, the semantic value layer, and the verification
ladder. Token bucket, GCRA, sliding/fixed windows and jittered backoff arrive
one verified commit at a time; every algorithm ships with decision laws that an
independent oracle re-derives.

## Build and test

```sh
moon test --target js
moon test --target wasm
moon test --target wasm-gc
moon test --target native
moon fmt --check
```
