# Changelog

## 0.1.0 — 2026-10-31

Registry version: 0.1.0.

Token bucket with continuous refill and exact retry-after; GCRA stated as the
theoretical-arrival-time invariant and proven equivalent to the bucket bitwise
on dyadic schedules; fixed window with the boundary burst demonstrated against
the exact sliding window; seeded jittered exponential backoff (none/full/equal/
decorrelated over SplitMix64); a JSON CLI and library boundary; white-box
laws, an independent Python oracle (fixtures, random schedules, bit-exact
jitter tables), machine-checked statistics and a four-backend deny-warn
ladder.
