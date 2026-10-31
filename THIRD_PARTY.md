# Source and dependency attribution

The module depends on nothing outside `moonbitlang/core`. No third-party code
is included; the algorithm references are publications, not sources:

- Token bucket and GCRA: ATM Forum Traffic Management 4.0/4.1 (GCRA as the
  scheduling form of a bucket); the equivalence form used here is the
  standard TAT invariant.
- Jitter shapes: "Exponential Backoff and Jitter", AWS Architecture Blog,
  2015 (full, equal, decorrelated).
- SplitMix64: Guy L. Steele Jr., "SplitMix64 (2014) ....", as republished in
  Lemire's tests and the Rust rand_chacha docs.

AI programming assistance was used for drafting and verification tooling;
every claim this repository makes is backed by a check that runs in CI.
