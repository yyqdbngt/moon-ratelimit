///|
fn delays_of(report : Value) -> Array[Double] raise {
  match get(report, "delays_ms") {
    Array(items) =>
      items.map(fn(item) {
        match item {
          Number(n) => n
          _ => abort("delay not a number")
        }
      })
    _ => raise InputError("delays missing")
  }
}

///|
test "pure exponential backoff is geometric and capped" {
  let request = from_json(
    @json.parse(
      "{\"operation\":\"backoff\",\"base_ms\":100,\"multiplier\":2,\"max_ms\":800,\"attempts\":6}",
    ),
  )
  let report = run(request)
  let delays = delays_of(report)
  assert_eq(delays.length(), 6)
  assert_eq(delays[0], 100.0)
  assert_eq(delays[1], 200.0)
  assert_eq(delays[2], 400.0)
  assert_eq(delays[3], 800.0)
  assert_eq(delays[4], 800.0)
  assert_eq(delays[5], 800.0)
  assert_eq(get(report, "capped_attempts"), Number(3))
}

///|
test "the same seed reproduces the same jitter table exactly" {
  let body = "{\"operation\":\"backoff\",\"base_ms\":50,\"max_ms\":5000,\"jitter\":\"full\",\"attempts\":8,\"seed\":20261031}"
  let first = delays_of(run(from_json(@json.parse(body))))
  let second = delays_of(run(from_json(@json.parse(body))))
  for i in 0..<first.length() {
    assert_eq(first[i], second[i])
  }
  // Every full-jitter sleep lies in [0, pure] and never above the cap.
  let pure = delays_of(
    run(
      from_json(
        @json.parse(
          "{\"operation\":\"backoff\",\"base_ms\":50,\"max_ms\":5000,\"attempts\":8}",
        ),
      ),
    ),
  )
  for i in 0..<first.length() {
    if first[i] > pure[i] {
      abort("full jitter exceeded the pure delay at " + i.to_string())
    }
  }
}

///|
test "equal jitter keeps half the exponential, decorrelated stays in band" {
  let equal = delays_of(
    run(
      from_json(
        @json.parse(
          "{\"operation\":\"backoff\",\"base_ms\":100,\"multiplier\":2,\"max_ms\":6400,\"jitter\":\"equal\",\"attempts\":7,\"seed\":7}",
        ),
      ),
    ),
  )
  let pure = delays_of(
    run(
      from_json(
        @json.parse(
          "{\"operation\":\"backoff\",\"base_ms\":100,\"multiplier\":2,\"max_ms\":6400,\"attempts\":7}",
        ),
      ),
    ),
  )
  for i in 0..<equal.length() {
    let half = pure[i] / 2.0
    if equal[i] < half || equal[i] > pure[i] {
      abort("equal jitter left [pure/2, pure] at " + i.to_string())
    }
  }
  let decorrelated = delays_of(
    run(
      from_json(
        @json.parse(
          "{\"operation\":\"backoff\",\"base_ms\":100,\"max_ms\":6400,\"jitter\":\"decorrelated\",\"attempts\":7,\"seed\":7}",
        ),
      ),
    ),
  )
  let mut previous = 100.0
  for i in 0..<decorrelated.length() {
    let ceiling = if previous * 3.0 > 6400.0 { 6400.0 } else { previous * 3.0 }
    if decorrelated[i] < 100.0 || decorrelated[i] > ceiling {
      abort("decorrelated jitter left [base, 3*previous] at " + i.to_string())
    }
    previous = decorrelated[i]
  }
}

///|
test "backoff validation refuses the shapes it cannot honour" {
  let bad_multiplier = from_json(
    @json.parse(
      "{\"operation\":\"backoff\",\"base_ms\":100,\"multiplier\":1,\"attempts\":3}",
    ),
  )
  let refused = String(
    match run(bad_multiplier) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(refused, String("multiplier must lie within (1, 10)"))
  let bad_jitter = from_json(
    @json.parse(
      "{\"operation\":\"backoff\",\"base_ms\":100,\"attempts\":3,\"jitter\":\"smooth\"}",
    ),
  )
  let refused2 = String(
    match run(bad_jitter) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(refused2, String("unsupported jitter: smooth"))
}
