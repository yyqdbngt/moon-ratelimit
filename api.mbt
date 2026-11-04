///|
/// The standard JSON boundary: one request object in, one report object out.
/// Failures raise InputError with a plain message.
pub fn execute(request : Json) -> Json raise {
  run(from_json(request)).to_json()
}

///|
/// The typed boundary over the same requests.
pub fn run(request : Value) -> Value raise InputError {
  let operation = optional_str(get(request, "operation"), "limit")
  match operation {
    "limit" => limit_with(request)
    "compose" => compose_with(request)
    "backoff" => backoff_with(request)
    "state" => state_with(request)
    "bulk" => bulk_with(request)
    _ => raise InputError("unsupported ratelimit operation: " + operation)
  }
}
