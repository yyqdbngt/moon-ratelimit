///|
/// One parsed event of a replay schedule.
priv struct Event {
  at : Double
  weight : Double
}

///|
fn parse_events(raw : Array[Value]) -> Array[Event] raise InputError {
  let events : Array[Event] = []
  for entry in raw {
    fields_only(entry, ["at", "weight"])
    let at = num(required(entry, "at"))
    if at < 0.0 {
      raise InputError("event time must be nonnegative")
    }
    let weight = optional_num(get(entry, "weight"), 1.0)
    if weight <= 0.0 {
      raise InputError("event weight must be positive")
    }
    match events.last() {
      Some(previous) =>
        if at < previous.at {
          raise InputError("event times must be nondecreasing")
        }
      None => ()
    }
    events.push({ at, weight, })
  }
  if events.is_empty() {
    raise InputError("events must name at least one event")
  }
  events
}

///|
/// Shared request validation and event parsing for the limit operation.
/// Events are required before any algorithm is consulted, so the default
/// routing (no operation field) is observable as a limit validation error.
fn limit_with(request : Value) -> Value raise InputError {
  fields_only(request, [
    "operation", "algorithm", "rate", "burst", "limit", "window_seconds", "events",
  ])
  let events = parse_events(arr(required(request, "events")))
  let algorithm = optional_str(get(request, "algorithm"), "token_bucket")
  match algorithm {
    "token_bucket" => limit_token_bucket(request, events)
    "gcra" => limit_gcra(request, events)
    _ => raise InputError("unsupported limiter algorithm: " + algorithm)
  }
}

///|
fn limit_gcra(request : Value, events : Array[Event]) -> Value raise InputError {
  let rate = num(required(request, "rate"))
  let capacity = num(required(request, "burst"))
  if rate <= 0.0 {
    raise InputError("rate must be positive")
  }
  if capacity <= 0.0 {
    raise InputError("burst must be positive")
  }
  let limiter = gcra(rate, capacity)
  let decisions : Array[Value] = []
  let mut allowed = 0
  let mut allowed_weight = 0.0
  for event in events {
    if event.weight > capacity {
      raise InputError(
        "event weight exceeds burst and can never be admitted: " +
        event.weight.to_string(),
      )
    }
    let admission = limiter.check(event.at, event.weight)
    if admission.allowed {
      allowed += 1
      allowed_weight += event.weight
    }
    decisions.push(decision_value(event, admission))
  }
  record([
    ("algorithm", String("gcra")),
    ("rate", Number(rate)),
    ("burst", Number(capacity)),
    ("decisions", Array(decisions)),
    ("events", Number(events.length().to_double())),
    ("allowed", Number(allowed.to_double())),
    ("denied", Number((events.length() - allowed).to_double())),
    ("allowed_weight", Number(allowed_weight)),
  ])
}

///|
fn decision_value(event : Event, admission : Admission) -> Value {
  record([
    ("at", Number(event.at)),
    ("allowed", Bool(admission.allowed)),
    (
      "retry_after",
      match admission.retry_after {
        Some(seconds) => Number(seconds)
        None => Null
      },
    ),
    ("tokens", Number(admission.tokens)),
  ])
}

///|
fn limit_token_bucket(
  request : Value,
  events : Array[Event],
) -> Value raise InputError {
  let rate = num(required(request, "rate"))
  let capacity = num(required(request, "burst"))
  if rate <= 0.0 {
    raise InputError("rate must be positive")
  }
  if capacity <= 0.0 {
    raise InputError("burst must be positive")
  }
  let bucket = token_bucket(rate, capacity)
  let decisions : Array[Value] = []
  let mut allowed = 0
  let mut allowed_weight = 0.0
  for event in events {
    if event.weight > capacity {
      raise InputError(
        "event weight exceeds burst and can never be admitted: " +
        event.weight.to_string(),
      )
    }
    let admission = bucket.check(event.at, event.weight)
    if admission.allowed {
      allowed += 1
      allowed_weight += event.weight
    }
    decisions.push(decision_value(event, admission))
  }
  record([
    ("algorithm", String("token_bucket")),
    ("rate", Number(rate)),
    ("burst", Number(capacity)),
    ("decisions", Array(decisions)),
    ("events", Number(events.length().to_double())),
    ("allowed", Number(allowed.to_double())),
    ("denied", Number((events.length() - allowed).to_double())),
    ("allowed_weight", Number(allowed_weight)),
  ])
}
