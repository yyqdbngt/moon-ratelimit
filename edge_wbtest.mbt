///|
test "token bucket zero elapsed time admits from initial fill" {
  // Two events at the same instant: the second gets whatever is left from
  // the first with no refill between.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":0},{\"at\":0}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[3], "allowed"), Bool(false))
}

///|
test "gcra zero elapsed time behaves identically to the bucket" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"gcra\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":0},{\"at\":0}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[3], "allowed"), Bool(false))
}

///|
test "very small rate and very large burst" {
  // rate 0.001/s with burst 1000: two events 1000s apart each cost 1,
  // and the refill (0.001 * 1000 = 1 token) allows the second.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":0.001,\"burst\":1000,\"events\":[{\"at\":0},{\"at\":1000}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "allowed"), Number(2))
}

///|
test "fractional weight on the bucket" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0,\"weight\":0.5},{\"at\":0,\"weight\":0.5},{\"at\":0,\"weight\":0.5}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[2], "retry_after"), Number(0.5))
}

///|
test "fixed window zero-width window_seconds refused" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"fixed_window\",\"limit\":1,\"window_seconds\":0,\"events\":[{\"at\":0}]}",
    ),
  )
  let failed = String(
    match run(request) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("window_seconds must be positive"))
}

///|
test "sliding window exactly at the boundary ages out" {
  // Window (at - window, at]: an event exactly at at-window is OUTSIDE.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window\",\"limit\":1,\"window_seconds\":1,\"events\":[{\"at\":0},{\"at\":1}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(report, "allowed"), Number(2))
}

///|
test "backoff base equals max" {
  // base_ms = max_ms means every delay equals the base: no growth.
  let request = from_json(
    @json.parse(
      "{\"operation\":\"backoff\",\"base_ms\":500,\"multiplier\":2,\"max_ms\":500,\"attempts\":5}",
    ),
  )
  let report = run(request)
  let delays = match get(report, "delays_ms") {
    Array(items) => items
    _ => abort("delays missing")
  }
  for delay in delays {
    assert_eq(delay, Number(500))
  }
  assert_eq(get(report, "capped_attempts"), Number(5))
}

///|
test "bulk with unit weight equals count admitted up to burst" {
  let request = from_json(
    @json.parse(
      "{\"operation\":\"bulk\",\"rate\":1,\"burst\":3,\"at\":0,\"weight\":1,\"count\":5}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "admitted"), Number(3))
  assert_eq(get(report, "denied"), Number(2))
  assert_eq(get(report, "retry_after"), Number(1))
}

///|
test "token bucket very long idle then burst" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":5,\"events\":[{"at":0,"weight":1},{"at":1000,"weight":1},{"at":1000,"weight":1},{"at":1000,"weight":1},{"at":1000,"weight":1},{"at":1000,"weight":1},{"at":1000,"weight":1}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "verdict"), String("linearizable"))
}

///|
test "gcra same-instant saturation" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"gcra\",\"rate\":2,\"burst\":3,\"events\":[{"at":0,"weight":1},{"at":0,"weight":1},{"at":0,"weight":1},{"at":0,"weight":1},{"at":0,"weight":1}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "verdict"), String("linearizable"))
}

///|
test "fixed window zero time" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"fixed_window\",\"rate\":1,\"burst\":1,\"events\":[{"at":0,"weight":1}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "verdict"), String("linearizable"))
}

///|
test "sliding window consecutive windows" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window\",\"rate\":1,\"burst\":2,\"events\":[{"at":0,"weight":1},{"at":0.5,"weight":1},{"at":1.5,"weight":1},{"at":2.5,"weight":1}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "verdict"), String("linearizable"))
}
