///|
test "an unknown operation is refused by name" {
  let request = from_json(@json.parse("{\"operation\":\"drain\"}"))
  let failed : Value = String(
    match run(request) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("unsupported ratelimit operation: drain"))
}

///|
test "the default operation is limit" {
  // An events-less request is a validation error from limit itself, which is
  // how the default routing is observable before any algorithm exists.
  let request = from_json(@json.parse("{}"))
  let failed : Value = String(
    match run(request) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("missing field: events"))
}

///|
test "a full bucket admits the burst and nothing beyond it" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":0}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[0], "tokens"), Number(1))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "tokens"), Number(0))
  assert_eq(get(decisions[2], "allowed"), Bool(false))
  assert_eq(get(decisions[2], "retry_after"), Number(1))
  assert_eq(get(report, "allowed"), Number(2))
  assert_eq(get(report, "denied"), Number(1))
}

///|
test "a denial names the exact moment the request fits again" {
  // rate 2/s, burst 1: spend the token at t=0, ask again at t=0.25 when only
  // half a token exists - the retry is possible exactly 0.25s later.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":2,\"burst\":1,\"events\":[{\"at\":0},{\"at\":0.25}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[1], "allowed"), Bool(false))
  assert_eq(get(decisions[1], "retry_after"), Number(0.25))
  // The third event lands exactly at that moment and is admitted.
  let request2 = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":2,\"burst\":1,\"events\":[{\"at\":0},{\"at\":0.25},{\"at\":0.5}]}",
    ),
  )
  let report2 = run(request2)
  let decisions2 = match get(report2, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions2[2], "allowed"), Bool(true))
}

///|
test "idle time refills to the capacity and no further" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":5,\"burst\":3,\"events\":[{\"at\":0},{\"at\":100},{\"at\":100}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  // After 100 idle seconds the bucket is full: the cap holds at 3 before the
  // event consumes one (500 tokens would have accrued without it), so the
  // second event leaves 2 and the third 1.
  assert_eq(get(decisions[1], "tokens"), Number(2))
  assert_eq(get(decisions[2], "tokens"), Number(1))
}

///|
test "weights consume proportionally and refusals scale with them" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":4,\"events\":[{\"at\":0,\"weight\":3},{\"at\":0.5,\"weight\":2}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "tokens"), Number(1))
  // At t=0.5 the bucket holds 1.5 of the needed 2: the deficit is 0.5 tokens
  // at 1 token/s.
  assert_eq(get(decisions[1], "allowed"), Bool(false))
  assert_eq(get(decisions[1], "retry_after"), Number(0.5))
}

///|
test "validation refuses impossible weights and empty schedules" {
  let overweight = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1,\"events\":[{\"at\":0,\"weight\":2}]}",
    ),
  )
  let refused = String(
    match run(overweight) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(
    refused,
    String("event weight exceeds burst and can never be admitted: 2"),
  )
  let empty = from_json(
    @json.parse(
      "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1,\"events\":[]}",
    ),
  )
  let refused2 = String(
    match run(empty) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(refused2, String("events must name at least one event"))
}
