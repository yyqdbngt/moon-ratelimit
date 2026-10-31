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
