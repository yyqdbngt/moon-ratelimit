///|
fn decisions_of(report : Value) -> Array[Value] raise {
  match get(report, "decisions") {
    Array(items) => items
    _ => raise InputError("decisions missing")
  }
}

///|
test "a fixed window resets at its boundary and names the boundary on refusal" {
  // limit 2 per 1s: the first window admits 0.9 and 0.95; 1.05 lands in a
  // in a fresh window and are admitted; 1.125 is refused until t=2 (dyadic, so the boundary arithmetic is exact).
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":1,\"events\":[{\"at\":0.9},{\"at\":0.95},{\"at\":1.05},{\"at\":1.1},{\"at\":1.125}]}",
    ),
  )
  let report = run(request)
  let decisions = decisions_of(report)
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(true))
  assert_eq(get(decisions[3], "allowed"), Bool(true))
  assert_eq(get(decisions[4], "allowed"), Bool(false))
  assert_eq(get(decisions[4], "retry_after"), Number(0.875))
  assert_eq(get(report, "allowed"), Number(4))
}

///|
test "the fixed window boundary burst is real, and the sliding window refuses it" {
  // Four arrivals inside one trailing second that straddles a boundary: the
  // fixed window admits all four - the documented 2x flaw - while the exact
  // sliding window holds the line at two.
  let schedule = "\"events\":[{\"at\":0.95},{\"at\":0.99},{\"at\":1.01},{\"at\":1.05}]"
  let fixed = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":1," +
        schedule +
        "}",
      ),
    ),
  )
  assert_eq(get(fixed, "allowed"), Number(4))
  let sliding = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"sliding_window\",\"limit\":2,\"window_seconds\":1," +
        schedule +
        "}",
      ),
    ),
  )
  assert_eq(get(sliding, "allowed"), Number(2))
  let decisions = decisions_of(sliding)
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[3], "allowed"), Bool(false))
}

///|
test "the sliding window admits exactly when the oldest event ages out" {
  // Window (now-1, now]: the t=0 event leaves the window AT 1.0, so a
  // same-weight arrival is already admitted then, not a moment earlier.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window\",\"limit\":2,\"window_seconds\":1,\"events\":[{\"at\":0},{\"at\":0.25},{\"at\":0.75},{\"at\":0.99},{\"at\":1.0}]}",
    ),
  )
  let report = run(request)
  let decisions = decisions_of(report)
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[2], "retry_after"), Number(0.25))
  assert_eq(get(decisions[3], "allowed"), Bool(false))
  assert_eq(get(decisions[4], "allowed"), Bool(true))
}

///|
test "sliding window weights free exactly their share on expiry" {
  // limit 4 over 2s: weights of 2 stack to the limit, the third is refused
  // until the t=0 weight expires at 2.0, and the 2.5 arrival fits.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window\",\"limit\":4,\"window_seconds\":2,\"events\":[{\"at\":0,\"weight\":2},{\"at\":1,\"weight\":2},{\"at\":1.5,\"weight\":2},{\"at\":2.5,\"weight\":2}]}",
    ),
  )
  let report = run(request)
  let decisions = decisions_of(report)
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[2], "retry_after"), Number(0.5))
  assert_eq(get(decisions[3], "allowed"), Bool(true))
}

///|
test "window weights must be whole and within the limit" {
  let fractional = from_json(
    @json.parse(
      "{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":1,\"events\":[{\"at\":0,\"weight\":0.5}]}",
    ),
  )
  let refused = String(
    match run(fractional) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(refused, String("window algorithms need whole-number weights: 0.5"))
  let overweight = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window\",\"limit\":2,\"window_seconds\":1,\"events\":[{\"at\":0,\"weight\":3}]}",
    ),
  )
  let refused2 = String(
    match run(overweight) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(
    refused2,
    String("event weight exceeds limit and can never be admitted: 3"),
  )
}
