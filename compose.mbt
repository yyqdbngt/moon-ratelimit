///|
/// Any one limiter, tagged for dispatch. Compose drives every limiter's
/// pure `decide` first and applies `commit` to all of them only when every
/// one allowed, so a denial by one limiter cannot burn budget in another.
priv enum Limiter {
  Bucket(TokenBucket)
  Gcra(Gcra)
  Leaky(LeakyBucket)
  Fixed(FixedWindow)
  Sliding(SlidingWindow)
  Counter(SlidingWindowCounter)
}

///|
/// The decision of one limiter for (now, weight), computed against
/// time-advanced state without changing anything.
fn Limiter::decide(self : Limiter, now : Double, weight : Double) -> Admission {
  match self {
    Bucket(limiter) => limiter.decide(now, weight)
    Gcra(limiter) => limiter.decide(now, weight)
    Leaky(limiter) => limiter.decide(now, weight)
    Fixed(limiter) => limiter.decide(now, weight.to_int())
    Sliding(limiter) => limiter.decide(now, weight.to_int())
    Counter(limiter) => limiter.decide(now, weight.to_int())
  }
}

///|
/// Applies one event to one limiter, allowed or denied, performing exactly
/// the state fold the single-algorithm path performs for that outcome.
fn Limiter::commit(
  self : Limiter,
  now : Double,
  weight : Double,
  allowed : Bool,
) -> Unit {
  match self {
    Bucket(limiter) => limiter.commit(now, weight, allowed)
    Gcra(limiter) => limiter.commit(now, weight, allowed)
    Leaky(limiter) => limiter.commit(now, weight, allowed)
    Fixed(limiter) => limiter.commit(now, weight.to_int(), allowed)
    Sliding(limiter) => limiter.commit(now, weight.to_int(), allowed)
    Counter(limiter) => limiter.commit(now, weight.to_int(), allowed)
  }
}

///|
/// One compose spec after parsing: the limiter itself plus what request
/// validation needs - the report name, the largest weight it could ever
/// admit, whether it counts events (whole-number weights), and the word the
/// never-admissible refusal uses ("burst" or "limit"), so a single-limiter
/// compose refuses with the same message as the algorithm run alone.
priv struct ComposeLimiter {
  limiter : Limiter
  name : String
  cap : Double
  cap_kind : String
  whole : Bool
}

///|
fn parse_compose_limiter(
  spec : Value,
  state : Value,
) -> ComposeLimiter raise InputError {
  fields_only(spec, [
    "algorithm", "rate", "burst", "limit", "window_seconds", "slices",
  ])
  let algorithm = optional_str(get(spec, "algorithm"), "token_bucket")
  match algorithm {
    "token_bucket" => {
      let rate = num(required(spec, "rate"))
      let capacity = num(required(spec, "burst"))
      if rate <= 0.0 {
        raise InputError("rate must be positive")
      }
      if capacity <= 0.0 {
        raise InputError("burst must be positive")
      }
      {
        limiter: Bucket(
          match state {
            Null => token_bucket(rate, capacity)
            _ => token_bucket_from_state(state, rate, capacity)
          },
        ),
        name: algorithm,
        cap: capacity,
        cap_kind: "burst",
        whole: false,
      }
    }
    "gcra" => {
      let rate = num(required(spec, "rate"))
      let capacity = num(required(spec, "burst"))
      if rate <= 0.0 {
        raise InputError("rate must be positive")
      }
      if capacity <= 0.0 {
        raise InputError("burst must be positive")
      }
      {
        limiter: Gcra(
          match state {
            Null => gcra(rate, capacity)
            _ => gcra_from_state(state, rate, capacity)
          },
        ),
        name: algorithm,
        cap: capacity,
        cap_kind: "burst",
        whole: false,
      }
    }
    "leaky_bucket" => {
      let rate = num(required(spec, "rate"))
      let capacity = num(required(spec, "burst"))
      if rate <= 0.0 {
        raise InputError("rate must be positive")
      }
      if capacity <= 0.0 {
        raise InputError("burst must be positive")
      }
      {
        limiter: Leaky(
          match state {
            Null => leaky_bucket(rate, capacity)
            _ => leaky_bucket_from_state(state, rate, capacity)
          },
        ),
        name: algorithm,
        cap: capacity,
        cap_kind: "burst",
        whole: false,
      }
    }
    "fixed_window" => {
      let limit = read_window_limit(spec)
      let window = read_window_seconds(spec)
      {
        limiter: Fixed(
          match state {
            Null => fixed_window(limit, window)
            _ => fixed_window_from_state(state, limit, window)
          },
        ),
        name: algorithm,
        cap: limit.to_double(),
        cap_kind: "limit",
        whole: true,
      }
    }
    "sliding_window" => {
      let limit = read_window_limit(spec)
      let window = read_window_seconds(spec)
      {
        limiter: Sliding(
          match state {
            Null => sliding_window(limit, window)
            _ => sliding_window_from_state(state, limit, window)
          },
        ),
        name: algorithm,
        cap: limit.to_double(),
        cap_kind: "limit",
        whole: true,
      }
    }
    "sliding_window_counter" => {
      let limit = read_window_limit(spec)
      let window = read_window_seconds(spec)
      let slices = optional_num(get(spec, "slices"), 10.0)
      if slices < 2.0 || slices.floor() != slices || slices > 1000.0 {
        raise InputError("slices must be a whole number 2..1000")
      }
      {
        limiter: Counter(
          match state {
            Null => sliding_window_counter(limit, window, slices.to_int())
            _ =>
              sliding_window_counter_from_state(
                state,
                limit,
                window,
                slices.to_int(),
              )
          },
        ),
        name: algorithm,
        cap: limit.to_double(),
        cap_kind: "limit",
        whole: true,
      }
    }
    _ => raise InputError("unsupported limiter algorithm: " + algorithm)
  }
}

///|
/// The compose operation: one schedule replayed against several limiters
/// with transactional admission. An event is admitted only when every
/// limiter would admit it, and then every limiter consumes it; a denial by
/// any limiter consumes nothing anywhere. The per-event retry_after is the
/// longest of the refusals (the event must outwait the slowest limiter) and
/// the reported remaining capacity is the smallest across limiters (the
/// most binding one).
fn compose_with(request : Value) -> Value raise InputError {
  fields_only(request, ["operation", "limiters", "events", "initial_state"])
  let events = parse_events(arr(required(request, "events")))
  let raw = arr(required(request, "limiters"))
  if raw.length() < 1 || raw.length() > 8 {
    raise InputError("limiters must list 1..8 limiters")
  }
  // A resumed compose names one state object per limiter, in order.
  let initial = get(request, "initial_state")
  let states : Array[Value] = match initial {
    Null => Array::make(raw.length(), Null)
    _ => {
      fields_only(initial, ["algorithm", "limiters"])
      state_name(initial, "compose")
      let listed = arr(required(initial, "limiters"))
      if listed.length() != raw.length() {
        raise InputError("initial_state limiters must match the request")
      }
      listed
    }
  }
  let limiters : Array[ComposeLimiter] = []
  for i, spec in raw {
    limiters.push(parse_compose_limiter(spec, states[i]))
  }
  // Window limiters count events, so a schedule mixing kinds carries
  // whole-number weights only; every weight must also fit every limiter.
  let mut needs_whole = false
  for entry in limiters {
    if entry.whole {
      needs_whole = true
    }
  }
  for event in events {
    if needs_whole {
      let _ = integer_weight(event)
    }
    for entry in limiters {
      if event.weight > entry.cap {
        raise InputError(
          "event weight exceeds " +
          entry.cap_kind +
          " and can never be admitted: " +
          event.weight.to_string(),
        )
      }
    }
  }
  let decisions : Array[Value] = []
  let mut allowed = 0
  let mut allowed_weight = 0.0
  for event in events {
    let mut all_allowed = true
    let mut retry : Double? = None
    let mut least = event.weight
    let mut first = true
    for entry in limiters {
      let admission = entry.limiter.decide(event.at, event.weight)
      if !admission.allowed {
        all_allowed = false
      }
      match (retry, admission.retry_after) {
        (Some(held), Some(next)) => if next > held { retry = Some(next) }
        (None, Some(next)) => retry = Some(next)
        _ => ()
      }
      if first || admission.tokens < least {
        least = admission.tokens
        first = false
      }
    }
    for entry in limiters {
      entry.limiter.commit(event.at, event.weight, all_allowed)
    }
    if all_allowed {
      allowed += 1
      allowed_weight += event.weight
      decisions.push(window_decision(event, true, None, least))
    } else {
      decisions.push(window_decision(event, false, retry, least))
    }
  }
  let names : Array[String] = []
  for entry in limiters {
    names.push(entry.name)
  }
  let member_states : Array[Value] = []
  for entry in limiters {
    member_states.push(entry.limiter.to_state())
  }
  record([
    ("algorithm", String("compose")),
    ("limiters", Number(limiters.length().to_double())),
    ("algorithms", strings(names)),
    ("events", Number(events.length().to_double())),
    ("allowed", Number(allowed.to_double())),
    ("denied", Number((events.length() - allowed).to_double())),
    ("allowed_weight", Number(allowed_weight)),
    ("decisions", Array(decisions)),
    (
      "final_state",
      record([
        ("algorithm", String("compose")),
        ("limiters", Array(member_states)),
      ]),
    ),
  ])
}
