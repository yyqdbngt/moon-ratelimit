///|
test "sliding window counter admits up to the window limit" {
  // With the corrected sum-across-slices semantics, the third event at
  // t=0.3 is also denied because the t=0 events are still in the window.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":4,\"events\":[{\"at\":0},{\"at\":0},{\"at\":0},{\"at\":0.3}]}",
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
  assert_eq(get(report, "allowed"), Number(2))
}

///|
test "sliding window counter frees capacity after aging" {
  // limit=2, window=1, slices=2 (slice_width=0.5).
  // Two events at t=0 fill the window; at t=1 the window is (0,1] so the
  // t=0 events are at the boundary and the first slice ages out.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":2,\"events\":[{\"at\":0},{\"at\":0},{\"at\":1},{\"at\":1}]}",
    ),
  )
  let report = run(request)
  assert_eq(get(report, "allowed"), Number(4))
}

///|
test "sliding window counter slices validation" {
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":1,\"events\":[{\"at\":0}]}",
    ),
  )
  let failed = String(
    match run(request) {
      _ => "no error raised"
    },
  ) catch {
    InputError(message) => String(message)
  }
  assert_eq(failed, String("slices must be a whole number 2..1000"))
}

///|
test "sliding window counter reuses ring slots without leaking" {
  // limit=2, window=1, slices=2 (slice_width=0.5). The t=2.5 events land
  // in sub-window 5, whose slot aliases sub-window 3 - one full ring
  // ahead of sub-window 0, where the t=0 event lives. A slot that still
  // remembers sub-window 0 must read as zero for sub-windows 4..5, so
  // all three t=2.5-capacity events behave as if t=0 never happened.
  let request = from_json(
    @json.parse(
      "{\"algorithm\":\"sliding_window_counter\",\"limit\":2,\"window_seconds\":1,\"slices\":2,\"events\":[{\"at\":0},{\"at\":2.5},{\"at\":2.5},{\"at\":2.5},{\"at\":3}]}",
    ),
  )
  let report = run(request)
  let decisions = match get(report, "decisions") {
    Array(items) => items
    _ => abort("decisions missing")
  }
  assert_eq(get(decisions[0], "allowed"), Bool(true))
  assert_eq(get(decisions[1], "allowed"), Bool(true))
  assert_eq(get(decisions[2], "allowed"), Bool(true))
  assert_eq(get(decisions[3], "allowed"), Bool(false))
  assert_eq(get(decisions[4], "allowed"), Bool(false))
  // Refusal points at the next sub-window boundary, not a fixed delay.
  assert_eq(get(decisions[3], "retry_after"), Number(0.5))
  assert_eq(get(report, "allowed"), Number(3))
  assert_eq(get(report, "denied"), Number(2))
}
