///|
fn decision_triple(value : Value) -> Value {
  record([
    ("allowed", get(value, "allowed")),
    ("retry_after", get(value, "retry_after")),
    ("tokens", get(value, "tokens")),
    ("remaining", get(value, "remaining")),
  ])
}

///|
test "bucket replay resumes from exported state" {
  // Full run of five events; the same run split after three must answer
  // the last two decisions and land on the same final_state.
  let full = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":1},{\"at\":2},{\"at\":2}]}",
      ),
    ),
  )
  let prefix = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":1}]}",
      ),
    ),
  )
  let resumed = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"initial_state\":" +
        get(prefix, "final_state").to_json().stringify() +
        ",\"events\":[{\"at\":2},{\"at\":2}]}",
      ),
    ),
  )
  let full_decisions = decisions_of(full)
  let resumed_decisions = decisions_of(resumed)
  assert_eq(resumed_decisions.length(), 2)
  for i in 0..<2 {
    assert_eq(
      decision_triple(resumed_decisions[i]),
      decision_triple(full_decisions[i + 3]),
    )
  }
  assert_eq(get(resumed, "final_state"), get(full, "final_state"))
  // The exported state is the arithmetic anyone can redo by hand: two
  // admitted at t=0, one refilled and admitted at t=1, so tokens 0 at last=1.
  assert_eq(
    get(prefix, "final_state"),
    from_json(
      @json.parse(
        "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"tokens\":0,\"last\":1}",
      ),
    ),
  )
}

///|
test "sliding window entries resume across the window edge" {
  // Prefix fills the window at t=0; the resumed run at t=1 sees both
  // entries expired (they sit at 0, outside (0, 1]) and admits twice.
  let prefix = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"sliding_window\",\"limit\":2,\"window_seconds\":1,\"events\":[{\"at\":0},{\"at\":0}]}",
      ),
    ),
  )
  let resumed = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"sliding_window\",\"limit\":2,\"window_seconds\":1,\"initial_state\":" +
        get(prefix, "final_state").to_json().stringify() +
        ",\"events\":[{\"at\":1},{\"at\":1}]}",
      ),
    ),
  )
  assert_eq(get(resumed, "allowed"), Number(2))
  assert_eq(get(resumed, "denied"), Number(0))
}

///|
test "counter ring state round trips" {
  // limit 2, window 1, slices 2: events at 0 and 2.5 land in sub-windows 0
  // and 5, whose slots are 0 and 1 - the ring arrays travel as they are.
  let prefix = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":2,\"events\":[{\"at\":0},{\"at\":2.5},{\"at\":2.5}]}",
      ),
    ),
  )
  let state = get(prefix, "final_state")
  assert_eq(get(state, "counts"), from_json(@json.parse("[1,2]")))
  assert_eq(get(state, "origins"), from_json(@json.parse("[0,5]")))
  let resumed = run(
    from_json(
      @json.parse(
        "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":2,\"initial_state\":" +
        state.to_json().stringify() +
        ",\"events\":[{\"at\":3}]}",
      ),
    ),
  )
  // At t=3 sub-windows 6..7 are summed: slot 1 still remembers sub-window 5.
  assert_eq(get(resumed, "allowed"), Number(0))
}

///|
test "compose member states resume in order" {
  // Both limiters refuse the third event (the window is full, the bucket
  // empty), so nothing is committed - yet the bucket's folded refill of
  // 0.5 tokens travels in its state, and the resumed run at t=2.5 starts
  // from exactly that arithmetic.
  let prefix = run(
    from_json(
      @json.parse(
        "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":2},{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2}],\"events\":[{\"at\":0},{\"at\":0},{\"at\":0.5}]}",
      ),
    ),
  )
  let state = get(prefix, "final_state")
  assert_eq(get(state, "algorithm"), String("compose"))
  let members = match get(state, "limiters") {
    Array(items) => items
    _ => abort("limiters missing")
  }
  assert_eq(members.length(), 2)
  assert_eq(get(members[0], "algorithm"), String("fixed_window"))
  assert_eq(get(members[1], "algorithm"), String("token_bucket"))
  assert_eq(get(members[0], "count"), Number(2))
  assert_eq(get(members[1], "tokens"), Number(0.5))
  let resumed = run(
    from_json(
      @json.parse(
        "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":2},{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2}],\"initial_state\":" +
        state.to_json().stringify() +
        ",\"events\":[{\"at\":2.5},{\"at\":2.5}]}",
      ),
    ),
  )
  let decisions = decisions_of(resumed)
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(resumed, "allowed"), Number(2))
}

///|
test "state operation probes a resumed limiter" {
  // A bucket resumed at tokens 0, last 1, rate 1: at t=1.5 it holds 0.5.
  let report = run(
    from_json(
      @json.parse(
        "{\"operation\":\"state\",\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"at\":1.5,\"initial_state\":{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"tokens\":0,\"last\":1}}",
      ),
    ),
  )
  assert_eq(get(report, "free"), Number(0.5))
  assert_eq(get(report, "capacity"), Number(2))
}

///|
test "initial_state is validated, not trusted" {
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
          "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"initial_state\":{\"algorithm\":\"gcra\",\"rate\":1,\"burst\":2,\"tat\":0},\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("initial_state algorithm does not match: gcra"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"algorithm\":\"token_bucket\",\"rate\":2,\"burst\":2,\"initial_state\":{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"tokens\":0,\"last\":0},\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("initial_state rate does not match the request"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"initial_state\":{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":2,\"tokens\":3,\"last\":0},\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("initial_state tokens must be within 0..burst"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":4,\"initial_state\":{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":4,\"counts\":[0,0,0],\"origins\":[-1,-1,-1,-1]},\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("initial_state ring arrays must match slices"),
  )
  assert_eq(
    error_of(
      from_json(
        @json.parse(
          "{\"operation\":\"compose\",\"limiters\":[{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1},{\"algorithm\":\"fixed_window\",\"limit\":2,\"window_seconds\":1}],\"initial_state\":{\"algorithm\":\"compose\",\"limiters\":[{\"algorithm\":\"token_bucket\",\"rate\":1,\"burst\":1,\"tokens\":1,\"last\":0}]},\"events\":[{\"at\":0}]}",
        ),
      ),
    ),
    String("initial_state limiters must match the request"),
  )
}
