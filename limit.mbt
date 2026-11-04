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
    "operation", "algorithm", "rate", "burst", "limit", "window_seconds", "slices",
    "events", "initial_state",
  ])
  let events = parse_events(arr(required(request, "events")))
  let algorithm = optional_str(get(request, "algorithm"), "token_bucket")
  match algorithm {
    "token_bucket" => limit_token_bucket(request, events)
    "gcra" => limit_gcra(request, events)
    "fixed_window" => limit_fixed_window(request, events)
    "sliding_window" => limit_sliding_window(request, events)
    "leaky_bucket" => limit_leaky_bucket(request, events)
    "sliding_window_counter" => limit_sliding_window_counter(request, events)
    _ => raise InputError("unsupported limiter algorithm: " + algorithm)
  }
}

///|
/// Reports the limiter's free capacity at a given instant without admitting
/// anything. Works for every algorithm, fresh or resumed from an
/// `initial_state`: the probe is a zero-weight decide, pure by construction.
fn state_with(request : Value) -> Value raise InputError {
  fields_only(request, [
    "operation", "algorithm", "rate", "burst", "limit", "window_seconds", "slices",
    "at", "initial_state",
  ])
  let at = num(required(request, "at"))
  if at < 0.0 {
    raise InputError("at must be nonnegative")
  }
  let initial = get(request, "initial_state")
  let algorithm = optional_str(get(request, "algorithm"), "token_bucket")
  fn bucket_params() -> (Double, Double) raise InputError {
    let rate = num(required(request, "rate"))
    let capacity = num(required(request, "burst"))
    if rate <= 0.0 {
      raise InputError("rate must be positive")
    }
    if capacity <= 0.0 {
      raise InputError("burst must be positive")
    }
    (rate, capacity)
  }
  fn window_params() -> (Int32, Double) raise InputError {
    let limit = read_window_limit(request)
    let window = read_window_seconds(request)
    (limit, window)
  }
  let answer = match algorithm {
    "token_bucket" => {
      let (rate, capacity) = bucket_params()
      let limiter = match initial {
        Null => token_bucket(rate, capacity)
        state => token_bucket_from_state(state, rate, capacity)
      }
      (limiter.decide(at, 0.0).tokens, capacity)
    }
    "gcra" => {
      let (rate, capacity) = bucket_params()
      let limiter = match initial {
        Null => gcra(rate, capacity)
        state => gcra_from_state(state, rate, capacity)
      }
      (limiter.decide(at, 0.0).tokens, capacity)
    }
    "leaky_bucket" => {
      let (rate, capacity) = bucket_params()
      let limiter = match initial {
        Null => leaky_bucket(rate, capacity)
        state => leaky_bucket_from_state(state, rate, capacity)
      }
      (limiter.decide(at, 0.0).tokens, capacity)
    }
    "fixed_window" => {
      let (limit, window) = window_params()
      let limiter = match initial {
        Null => fixed_window(limit, window)
        state => fixed_window_from_state(state, limit, window)
      }
      (limiter.decide(at, 0).tokens, limit.to_double())
    }
    "sliding_window" => {
      let (limit, window) = window_params()
      let limiter = match initial {
        Null => sliding_window(limit, window)
        state => sliding_window_from_state(state, limit, window)
      }
      (limiter.decide(at, 0).tokens, limit.to_double())
    }
    "sliding_window_counter" => {
      let (limit, window) = window_params()
      let slices = optional_num(get(request, "slices"), 10.0)
      if slices < 2.0 || slices.floor() != slices || slices > 1000.0 {
        raise InputError("slices must be a whole number 2..1000")
      }
      let limiter = match initial {
        Null => sliding_window_counter(limit, window, slices.to_int())
        state =>
          sliding_window_counter_from_state(
            state,
            limit,
            window,
            slices.to_int(),
          )
      }
      (limiter.decide(at, 0).tokens, limit.to_double())
    }
    _ => raise InputError("unsupported limiter algorithm: " + algorithm)
  }
  record([
    ("algorithm", String(algorithm)),
    ("at", Number(at)),
    ("free", Number(answer.0)),
    ("capacity", Number(answer.1)),
  ])
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
  let limiter = match get(request, "initial_state") {
    Null => gcra(rate, capacity)
    state => gcra_from_state(state, rate, capacity)
  }
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
    ("final_state", limiter.to_state()),
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
  let bucket = match get(request, "initial_state") {
    Null => token_bucket(rate, capacity)
    state => token_bucket_from_state(state, rate, capacity)
  }
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
    ("final_state", bucket.to_state()),
  ])
}

///|
/// Windows count events, so weights must be whole numbers there; buckets take
/// continuous weights. The refusal names the offending weight.
fn integer_weight(event : Event) -> Int32 raise InputError {
  if event.weight.floor() != event.weight || event.weight > 2147483647.0 {
    raise InputError(
      "window algorithms need whole-number weights: " + event.weight.to_string(),
    )
  }
  event.weight.to_int()
}

///|
fn window_decision(
  event : Event,
  allowed : Bool,
  retry_after : Double?,
  remaining : Double,
) -> Value {
  record([
    ("at", Number(event.at)),
    ("allowed", Bool(allowed)),
    (
      "retry_after",
      match retry_after {
        Some(seconds) => Number(seconds)
        None => Null
      },
    ),
    ("remaining", Number(remaining)),
  ])
}

///|
fn read_window_limit(request : Value) -> Int32 raise InputError {
  let limit = num(required(request, "limit"))
  if limit < 1.0 || limit.floor() != limit || limit > 2147483647.0 {
    raise InputError("limit must be a positive whole number")
  }
  limit.to_int()
}

///|
fn read_window_seconds(request : Value) -> Double raise InputError {
  let window = num(required(request, "window_seconds"))
  if window <= 0.0 {
    raise InputError("window_seconds must be positive")
  }
  window
}

///|
fn replay_window(
  events : Array[Event],
  weights : Array[Int32],
  check : (Double, Int32) -> Admission,
  name : String,
) -> Value {
  let decisions : Array[Value] = []
  let mut allowed = 0
  let mut allowed_weight = 0.0
  for i, event in events {
    let admission = check(event.at, weights[i])
    if admission.allowed {
      allowed += 1
      allowed_weight += event.weight
    }
    decisions.push(
      window_decision(
        event,
        admission.allowed,
        admission.retry_after,
        admission.tokens,
      ),
    )
  }
  record([
    ("algorithm", String(name)),
    ("events", Number(events.length().to_double())),
    ("allowed", Number(allowed.to_double())),
    ("denied", Number((events.length() - allowed).to_double())),
    ("allowed_weight", Number(allowed_weight)),
    ("decisions", Array(decisions)),
  ])
}

///|
fn limit_fixed_window(
  request : Value,
  events : Array[Event],
) -> Value raise InputError {
  let limit = read_window_limit(request)
  let window = read_window_seconds(request)
  let weights : Array[Int32] = []
  for event in events {
    weights.push(integer_weight(event))
  }
  let limiter = match get(request, "initial_state") {
    Null => fixed_window(limit, window)
    state => fixed_window_from_state(state, limit, window)
  }
  let report = replay_window(
    events,
    weights,
    (now, weight) => limiter.check(now, weight),
    "fixed_window",
  )
  let fields = obj(report).copy()
  fields["limit"] = Number(limit.to_double())
  fields["window_seconds"] = Number(window)
  fields["final_state"] = limiter.to_state()
  Object(fields)
}

///|
fn limit_sliding_window(
  request : Value,
  events : Array[Event],
) -> Value raise InputError {
  let limit = read_window_limit(request)
  let window = read_window_seconds(request)
  let weights : Array[Int32] = []
  for event in events {
    weights.push(integer_weight(event))
    if event.weight > limit.to_double() {
      raise InputError(
        "event weight exceeds limit and can never be admitted: " +
        event.weight.to_string(),
      )
    }
  }
  let limiter = match get(request, "initial_state") {
    Null => sliding_window(limit, window)
    state => sliding_window_from_state(state, limit, window)
  }
  let report = replay_window(
    events,
    weights,
    (now, weight) => limiter.check(now, weight),
    "sliding_window",
  )
  let fields = obj(report).copy()
  fields["limit"] = Number(limit.to_double())
  fields["window_seconds"] = Number(window)
  fields["final_state"] = limiter.to_state()
  Object(fields)
}

///|
fn bulk_with(request : Value) -> Value raise InputError {
  fields_only(request, [
    "operation", "algorithm", "rate", "burst", "at", "weight", "count",
  ])
  let algorithm = optional_str(get(request, "algorithm"), "token_bucket")
  if algorithm != "token_bucket" {
    raise InputError("bulk is only supported by token_bucket in 0.2.0")
  }
  let rate = num(required(request, "rate"))
  let capacity = num(required(request, "burst"))
  if rate <= 0.0 {
    raise InputError("rate must be positive")
  }
  if capacity <= 0.0 {
    raise InputError("burst must be positive")
  }
  let at = num(required(request, "at"))
  if at < 0.0 {
    raise InputError("at must be nonnegative")
  }
  let weight = optional_num(get(request, "weight"), 1.0)
  if weight <= 0.0 {
    raise InputError("weight must be positive")
  }
  if weight > capacity {
    raise InputError("weight exceeds burst and can never be admitted")
  }
  let count = num(required(request, "count"))
  if count < 1.0 || count.floor() != count || count > 1000.0 {
    raise InputError("count must be a whole number 1..1000")
  }
  // A fresh bucket holds capacity tokens; each admission costs weight.
  let admitted = (capacity / weight).floor()
  let admitted = if admitted < 0.0 { 0.0 } else { admitted }
  let admitted = if admitted > count { count } else { admitted }
  let remainder = count - admitted
  let retry_after = if remainder == 0.0 {
    Null
  } else {
    Number((weight - (capacity - admitted * weight)) / rate)
  }
  record([
    ("algorithm", String("token_bucket")),
    ("at", Number(at)),
    ("weight", Number(weight)),
    ("count", Number(count)),
    ("admitted", Number(admitted)),
    ("denied", Number(remainder)),
    ("retry_after", retry_after),
    ("remaining_tokens", Number(capacity - admitted * weight)),
  ])
}

///|
fn limit_leaky_bucket(
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
  let limiter = match get(request, "initial_state") {
    Null => leaky_bucket(rate, capacity)
    state => leaky_bucket_from_state(state, rate, capacity)
  }
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
    ("algorithm", String("leaky_bucket")),
    ("rate", Number(rate)),
    ("burst", Number(capacity)),
    ("decisions", Array(decisions)),
    ("events", Number(events.length().to_double())),
    ("allowed", Number(allowed.to_double())),
    ("denied", Number((events.length() - allowed).to_double())),
    ("allowed_weight", Number(allowed_weight)),
    ("final_state", limiter.to_state()),
  ])
}

///|
fn limit_sliding_window_counter(
  request : Value,
  events : Array[Event],
) -> Value raise InputError {
  let limit = read_window_limit(request)
  let window = read_window_seconds(request)
  let slices = optional_num(get(request, "slices"), 10.0)
  if slices < 2.0 || slices.floor() != slices || slices > 1000.0 {
    raise InputError("slices must be a whole number 2..1000")
  }
  let weights : Array[Int32] = []
  for event in events {
    weights.push(integer_weight(event))
    if event.weight > limit.to_double() {
      raise InputError(
        "event weight exceeds limit and can never be admitted: " +
        event.weight.to_string(),
      )
    }
  }
  let limiter = match get(request, "initial_state") {
    Null => sliding_window_counter(limit, window, slices.to_int())
    state =>
      sliding_window_counter_from_state(state, limit, window, slices.to_int())
  }
  let report = replay_window(
    events,
    weights,
    (now, weight) => limiter.check(now, weight),
    "sliding_window_counter",
  )
  let fields = obj(report).copy()
  fields["limit"] = Number(limit.to_double())
  fields["window_seconds"] = Number(window)
  fields["slices"] = Number(slices)
  fields["final_state"] = limiter.to_state()
  Object(fields)
}
