///|
/// Shared request validation and event parsing for the limit operation.
/// Events are required before any algorithm is consulted, so the default
/// routing (no operation field) is observable as a limit validation error.
/// Algorithms are added one commit at a time; each names itself on refusal.
fn limit_with(request : Value) -> Value raise InputError {
  fields_only(request, [
    "operation", "algorithm", "rate", "burst", "limit", "window_seconds", "events",
  ])
  ignore(arr(required(request, "events")))
  let algorithm = optional_str(get(request, "algorithm"), "token_bucket")
  match algorithm {
    _ => raise InputError("unsupported limiter algorithm: " + algorithm)
  }
}
