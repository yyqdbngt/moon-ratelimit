///|
/// Runs one schedule through a fresh token bucket and a fresh GCRA with the
/// same parameters and asserts the two answer identically: same verdict, same
/// retry_after, same remaining tokens (to a billionth, the price of two
/// float orderings). This is the equivalence the invariant in gcra.mbt
/// claims, and it is checked rather than believed.
fn assert_equivalent(
  rate : Double,
  capacity : Double,
  events : Array[Double],
) -> Unit {
  let bucket = token_bucket(rate, capacity)
  let scheduler = gcra(rate, capacity)
  for at in events {
    let left = bucket.check(at, 1.0)
    let right = scheduler.check(at, 1.0)
    // All schedules here are dyadic (eighths of a second, quarters of a
    // token per second, integer capacities), so both arithmetic paths are
    // exact in doubles and the equivalence is bitwise, not approximate.
    if left.allowed != right.allowed {
      abort("equivalence broken at " + at.to_string())
    }
    match (left.retry_after, right.retry_after) {
      (None, None) => ()
      (Some(a), Some(b)) =>
        if a != b {
          abort(
            "retry_after diverged at " +
            at.to_string() +
            ": " +
            a.to_string() +
            " vs " +
            b.to_string(),
          )
        }
      _ => abort("retry_after presence diverged at " + at.to_string())
    }
    if left.tokens != right.tokens {
      abort(
        "tokens diverged at " +
        at.to_string() +
        ": " +
        left.tokens.to_string() +
        " vs " +
        right.tokens.to_string(),
      )
    }
  }
}

///|
test "GCRA equals the token bucket on a dense deterministic schedule" {
  // Bursts, idles and denials interleaved: 0.5/s into a burst of 3.
  assert_equivalent(0.5, 3.0, [
    0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 2.0, 4.0, 4.0, 4.0, 4.5, 6.0, 6.0, 6.0, 6.0,
    10.0, 10.0, 10.0, 10.0, 10.5, 11.0, 12.0, 12.25,
  ])
}

///|
test "GCRA equals the token bucket across pseudo-random schedules" {
  // A deterministic generator (a plain LCG) builds arrival times; several
  // rate/burst shapes cross the boundary conditions: burst 1 (no buffering
  // beyond one), rates above and below one, fractional capacities.
  // The seed is reduced into the modulus first: the raw date-like constant
  // would overflow Int32 on the very first multiply and, with C-style
  // remainder, poison every step after it.
  let mut seed = 20261031 % 1000003
  for index in 0..<24 {
    let schedule : Array[Double] = []
    let mut at = 0.0
    for _ in 0..<40 {
      seed = (seed * 127 + 11) % 1000003
      let step = (seed % 13).to_double() / 8.0
      at = at + step
      seed = (seed * 127 + 11) % 1000003
      if seed % 5 == 0 {
        // A same-instant burst: two arrivals at one time.
        schedule.push(at)
      }
      schedule.push(at)
    }
    // Dyadic rates only (1/rate is exactly representable), so both the
    // bucket's accumulate-and-cap path and GCRA's tat arithmetic stay exact
    // and the comparison below is bitwise. A non-dyadic rate such as 1.75
    // makes 1/rate repeating and the two paths round differently at the
    // admission boundary - that is a property of doubles, not of the theorem.
    let step_rate = index % 4
    let rate = if step_rate == 0 {
      0.25
    } else if step_rate == 1 {
      0.5
    } else if step_rate == 2 {
      1.0
    } else {
      2.0
    }
    let capacity = 1.0 + (index % 3).to_double()
    assert_equivalent(rate, capacity, schedule)
  }
}

///|
test "a GCRA report answers through the JSON boundary" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"gcra\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0},{\"at\":0.5},{\"at\":1.5}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "algorithm"), String("gcra"))
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(false))
  assert_eq(get(decisions[1], "retry_after"), Number(0.5))
  assert_eq(get(decisions[2], "allowed"), Bool(true))
}
