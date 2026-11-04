# Changelog

## 0.4.0 — 2026-11-04

Registry version: 0.4.0. Five algorithms (token bucket, GCRA, leaky bucket,
fixed window, sliding window); the state and bulk operations; jittered
exponential backoff with seeded SplitMix64; 37 test declarations across four
backends; 34 CLI fixtures; the independent Python oracle with fuzz; a 31-case
malformed-input sweep; 17 design notes and 25 boundary statements.

## 0.2.0 — 2026-11-03

Registry version: 0.2.0. The state operation reports free capacity at an
instant without admitting; the bulk operation answers batch admission on the
token bucket in one arithmetic step; a 22-case malformed-input sweep and the
bulk oracle extension join the ladder.

## 0.1.0 — 2026-10-31## 0.1.0 — 2026-10-31

Registry version: 0.1.0.

Token bucket with continuous refill and exact retry-after; GCRA stated as the
theoretical-arrival-time invariant and proven equivalent to the bucket bitwise
on dyadic schedules; fixed window with the boundary burst demonstrated against
the exact sliding window; seeded jittered exponential backoff (none/full/equal/
decorrelated over SplitMix64); a JSON CLI and library boundary; white-box
laws, an independent Python oracle (fixtures, random schedules, bit-exact
jitter tables), machine-checked statistics and a four-backend deny-warn
ladder.
