# Changelog

## 0.7.0 — 2026-11-04

Resumable replays. Every limit and compose report ends with a final_state
object: the algorithm, its parameters, and exactly the fields decide and
commit read - bucket tokens and last, GCRA's tat, the fixed window's index
and count, the sliding window's remembered entries, the counter's ring
arrays, or one state per limiter for compose. Sending it back as
initial_state continues the replay where it stopped; the parameters inside
the state must equal the request's, so a resumed replay cannot quietly run
different law, and malformed states are refused by name (wrong algorithm
tag, parameter mismatch, out-of-range tokens or counts, ring arrays not
matching slices, entries out of order). The property is verified as an
algebraic law by the oracle fuzz: a schedule split at any event, resumed
from the prefix's final_state, answers the unbroken replay's remaining
decisions bit for bit and lands on the identical final_state - every
algorithm, every iteration, plus compose; the exact final_state equality
also proves the state's doubles survive the JSON round trip. The state
operation now accepts initial_state and covers all six algorithms,
probing free capacity with a zero-weight decide. Six white-box tests,
four fixtures, one pinned example and eight malformed-state cases (51
total) join the ladder.

## 0.6.0 — 2026-11-04

The compose operation: one schedule replayed against 1..8 limiters with
transactional admission. Every algorithm was re-expressed as a pure decide
(no state change) plus a commit that applies the event exactly as the
single-algorithm path always has - including the time folds on denial, so
bitwise behavior is unchanged and the single-limiter paths now share the
same two steps compose uses. An event is admitted only when every limiter
would admit it, then every limiter consumes it; a refusal by one limiter
burns nothing anywhere. Denied events report the longest of the refusals
and the smallest remaining capacity across limiters; a compose of one
limiter answers exactly what running the algorithm alone answers, which
the oracle fuzz checks schedule by schedule. White-box tests pin the
transactional no-consume property on a schedule where a greedy compose
would differ, and the longest-refusal/smallest-remaining answers. Eight
compose malformed-input cases join the sweep (44 total).

## 0.5.0 — 2026-11-04

Sixth algorithm: the sliding window counter, a bounded-memory approximation
of the exact sliding window over `slices` ring slots. Each slot records the
sub-window it was last written for, so a reused slot reads as zero instead of
leaking a count from one full ring earlier - no aging pass, no aliasing; a
white-box regression test replays a schedule that crosses a full ring and a
refusal's retry_after points at the next sub-window boundary. The Python
oracle gained a matching implementation plus random dyadic fuzz across the
slices choices; the malformed-input sweep gained four counter cases (35
total). The fixture suite was also tightened: every case now carries a pinned
expected answer (the three seeded backoff cases previously relied on the
oracle alone), five examples gained pinned answers, and two stale hand-counted
summaries (bucket rate point five, gcra burst two serial) were corrected to
what the engine and the independently written oracle both compute.

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
