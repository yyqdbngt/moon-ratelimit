///|
test "state reports free capacity for every algorithm" {
  let bucket = run(
    from_json(
      @json.parse(
        "{\"operation\":\"state\",\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":5,\"at\":10}",
      ),
    ),
  )
  assert_eq(get(bucket, "free"), Number(5))
  assert_eq(get(bucket, "capacity"), Number(5))
  let window = run(
    from_json(
      @json.parse(
        "{\"operation\":\"state\",\"algorithm\":\"sliding_window\",\"limit\":3,\"window_seconds\":2,\"at\":1}",
      ),
    ),
  )
  assert_eq(get(window, "free"), Number(3))
}

///|
test "state refuses negative time and missing parameters" {
  let negative = from_json(
    @json.parse(
      "{\"operation\":\"state\",\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1,\"at\":-1}",
    ),
  )
  let failed = String(
    match run(negative) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("at must be nonnegative"))
  let missing = from_json(
    @json.parse(
      "{\"operation\":\"state\",\"algorithm\":\"token_bucket\",\"at\":1}",
    ),
  )
  let failed2 = String(
    match run(missing) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed2, String("missing field: rate"))
}
