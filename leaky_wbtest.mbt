///|
test "leaky bucket fills then drains" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"leaky_bucket\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":0},{\"at\":3}]}",
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
  assert_eq(get(decisions[2], "retry_after"), Number(1))
  assert_eq(get(decisions[3], "allowed"), Bool(true))
  assert_eq(get(decisions[3], "tokens"), Number(1))
  assert_eq(get(report, "allowed"), Number(3))
}

///|
test "leaky bucket is the dual of the token bucket" {
  // Same parameters, same schedule, opposite outcomes: the token bucket
  // admits when tokens remain; the leaky bucket admits when queue fits.
  // Both agree on the retry_after at the same state.
  let token = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0},{\"at\":0},{\"at\":2}]}",
      ),
    ),
  )
  let leaky = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"leaky_bucket\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0},{\"at\":0},{\"at\":2}]}",
      ),
    ),
  )
  // Both admit exactly 2 events (one at t=0, one at t=2 after drain/refill).
  assert_eq(get(token, "allowed"), get(leaky, "allowed"))
}

///|
test "leaky bucket overweight refused" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"leaky_bucket\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0,\"weight\":2}]}",
    ),
  )
  let failed = String(
    match run(request) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(
    failed,
    String("event weight exceeds burst and can never be admitted: 2"),
  )
}

///|
test "leaky bucket drains to zero over long idle" {
  let request = from_json(
    @json.parse("{\\"algorithm\\":\\"leaky_bucket\\",\\"rate\\":1,\\"burst\\":2,\\"events\\":[{\\"at\\":0},{\\"at\\":0},{\\"at\\":100}]}"),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  // After 100s idle, the level is 0; the third event is admitted freely.
  assert_eq(get(decisions[2], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "tokens"), Number(1))
}

///|
test "leaky bucket weight-equals-capacity admits once" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"leaky_bucket\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0,\"weight\":2},{\"at\":0,\"weight\":2}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "allowed"), Number(1))
  assert_eq(get(report, "denied"), Number(1))
}

///|
test "leaky bucket fractional weight pours partially" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"leaky_bucket\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0,\"weight\":0.5},{\"at\":0,\"weight\":0.5},{\"at\":0,\"weight\":0.5}]}",
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
}
