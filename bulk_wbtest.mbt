///|
test "bulk admits floor of capacity over weight" {
  let result = run(
    from_json(
      @json.parse(
        "{\"operation\":\"bulk\",\"rate\":1,\"burst\":5,\"at\":0,\"weight\":2,\"count\":4}",
      ),
    ),
  )
  assert_eq(get(result, "admitted"), Number(2))
  assert_eq(get(result, "denied"), Number(2))
  assert_eq(get(result, "retry_after"), Number(1))
  assert_eq(get(result, "remaining_tokens"), Number(1))
}

///|
test "bulk all admitted when capacity covers the count" {
  let result = run(
    from_json(
      @json.parse(
        "{\"operation\":\"bulk\",\"rate\":1,\"burst\":10,\"at\":0,\"weight\":2,\"count\":5}",
      ),
    ),
  )
  assert_eq(get(result, "admitted"), Number(5))
  assert_eq(get(result, "denied"), Number(0))
  assert_eq(get(result, "retry_after"), Null)
  assert_eq(get(result, "remaining_tokens"), Number(0))
}

///|
test "bulk refuses overweight and non-token-bucket algorithms" {
  let overweight = from_json(
    @json.parse(
      "{\"operation\":\"bulk\",\"rate\":1,\"burst\":1,\"at\":0,\"weight\":2,\"count\":1}",
    ),
  )
  let failed = String(
    match run(overweight) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("weight exceeds burst and can never be admitted"))
  let gcra = from_json(
    @json.parse(
      "{\"operation\":\"bulk\",\"algorithm\":\"gcra\",\"rate\":1,\"burst\":5,\"at\":0,\"count\":1}",
    ),
  )
  let failed2 = String(
    match run(gcra) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed2, String("bulk is only supported by token_bucket in 0.2.0"))
}
