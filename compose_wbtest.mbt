///|
test "compose admits only when every limiter allows" {
  // Transactional admission: at t=0.5 the fixed window alone would allow a
  // second event, but the bucket denies it, so NOTHING is consumed. At
  // t=5.5 the bucket has refilled and the window still holds only the one
  // committed event, so the third event passes. A compose that burned the
  // allowing limiter's budget on denials would refuse the third event.
  let request = from_json(
    @json.parse(
      "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":10},{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1}],\"events\":[{\"at\":0},{\"at\":0.5},{\"at\":5.5}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(false))
  assert_eq(get(decisions[2], "allowed"), Bool(true))
  assert_eq(get(report, "allowed"), Number(2))
  assert_eq(get(report, "denied"), Number(1))
  assert_eq(get(report, "limiters"), Number(2))
  assert_eq(
    get(report, "algorithms"),
    from_json(@json.parse("[\"fixed_window\",\"token_bucket\"]")),
  )
}

///|
test "compose reports the longest refusal and smallest remaining" {
  // sliding_window limit 3 window 4 + token_bucket rate 1 burst 2. The
  // fourth event is refused by both: the window needs 3s (its oldest entry
  // expires), the bucket 1s; the answer names 3s. Free capacity reports
  // the smaller of the two (the bucket's 1 at t=0, not the window's 2).
  let request = from_json(
    @json.parse(
      "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"sliding_window\",\"limit\":3,\"window_seconds\":4},{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2}],\"events\":[{\"at\":0},{\"at\":0},{\"at\":1},{\"at\":1}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "remaining"), Number(1))
  assert_eq(get(decisions[3], "allowed"), Bool(false))
  assert_eq(get(decisions[3], "retry_after"), Number(3))
}

///|
test "compose with one limiter matches the plain algorithm" {
  let events = "[{\"at\":0},{\"at\":0},{\"at\":1},{\"at\":1},{\"at\":2}]"
  let composed = run(
    from_json(
      @json.parse(
        "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"gcra\",\"rate\":1,\"burst\":2}],\"events\":" +
        events +
        "}",
      ),
    ),
  )
  let plain = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"gcra\",\"rate\":1,\"burst\":2,\"events\":" +
        events +
        "}",
      ),
    ),
  )
  let composed_decisions = match get(composed, "decisions") {
    Array(items) => items
    _ => abort("compose decisions missing")
  }
  let plain_decisions = match get(plain, "decisions") {
    Array(items) => items
    _ => abort("plain decisions missing")
  }
  assert_eq(composed_decisions.length(), plain_decisions.length())
  for i in 0..<composed_decisions.length() {
    assert_eq(
      get(composed_decisions[i], "allowed"),
      get(plain_decisions[i], "allowed"),
    )
    assert_eq(
      get(composed_decisions[i], "retry_after"),
      get(plain_decisions[i], "retry_after"),
    )
    assert_eq(
      get(composed_decisions[i], "remaining"),
      get(plain_decisions[i], "tokens"),
    )
  }
}

///|
test "compose refuses fractional weights when a window limiter counts" {
  let request = from_json(
    @json.parse(
      "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2},{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":1}],\"events\":[{\"at\":0,\"weight\":0.5}]}",
    ),
  )
  let failed = String(
    match run(request) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("window algorithms need whole-number weights: 0.5"))
}

///|
test "compose validates limiter list and specs" {
  fn error_of(request : Value) -> Value {
    let failed = String(
      match run(request) {
        _ => "no error raised"
      },
    ) catch {
      InputError(message) => String(message)
    }
    failed
  }
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"operation\":\"compose\",\"limiters\":[],\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("limiters must list 1..8 limiters"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"wat\",\"limit\":2,\"window_seconds\":1}],\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("unsupported limiter algorithm: wat"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1}],\"events\":[{\"at\":0,\"weight\":2}]}",
        ),
      ),
    ),
    String("event weight exceeds burst and can never be admitted: 2"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":1,\"wat\":1}],\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("unknown field: wat"),
  )
}
