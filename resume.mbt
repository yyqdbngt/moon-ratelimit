///|
/// Every limiter can package its state as JSON and start again from it.
/// A state object names the algorithm and its parameters, then carries the
/// fields decide and commit read; feeding it back as `initial_state`
/// continues the replay where it stopped. A schedule split at any event
/// resumes from the prefix's final_state and answers exactly what the
/// unbroken replay answers, which the oracle fuzz checks schedule by
/// schedule for every algorithm and for compose.

///|
fn state_name(state : Value, want : String) -> Unit raise InputError {
  let got = str(required(state, "algorithm"))
  if got != want {
    raise InputError("initial_state algorithm does not match: " + got)
  }
}

///|
/// A parameter the request already carries must equal the one baked into
/// the state, so a resumed replay cannot quietly run different law.
fn state_param(
  state : Value,
  key : String,
  want : Double,
) -> Unit raise InputError {
  let got = num(required(state, key))
  if got != want {
    raise InputError("initial_state " + key + " does not match the request")
  }
}

///|
fn state_whole(state : Value, key : String) -> Int32 raise InputError {
  let value = num(required(state, key))
  if value.floor() != value || value < -1.0 || value > 2147483647.0 {
    raise InputError("initial_state " + key + " must be a whole number")
  }
  value.to_int()
}

///|
fn TokenBucket::to_state(self : TokenBucket) -> Value {
  record([
    ("algorithm", String("token_bucket")),
    ("rate", Number(self.rate)),
    ("burst", Number(self.capacity)),
    ("tokens", Number(self.tokens)),
    ("last", Number(self.last)),
  ])
}

///|
fn token_bucket_from_state(
  state : Value,
  rate : Double,
  capacity : Double,
) -> TokenBucket raise InputError {
  state_name(state, "token_bucket")
  state_param(state, "rate", rate)
  state_param(state, "burst", capacity)
  let tokens = num(required(state, "tokens"))
  if tokens < 0.0 || tokens > capacity {
    raise InputError("initial_state tokens must be within 0..burst")
  }
  let last = num(required(state, "last"))
  if last < 0.0 {
    raise InputError("initial_state last must be nonnegative")
  }
  { rate, capacity, tokens, last, }
}

///|
fn Gcra::to_state(self : Gcra) -> Value {
  record([
    ("algorithm", String("gcra")),
    ("rate", Number(self.rate)),
    ("burst", Number(self.capacity)),
    ("tat", Number(self.tat)),
  ])
}

///|
fn gcra_from_state(
  state : Value,
  rate : Double,
  capacity : Double,
) -> Gcra raise InputError {
  state_name(state, "gcra")
  state_param(state, "rate", rate)
  state_param(state, "burst", capacity)
  let tat = num(required(state, "tat"))
  if tat < 0.0 {
    raise InputError("initial_state tat must be nonnegative")
  }
  { rate, capacity, tat, }
}

///|
fn LeakyBucket::to_state(self : LeakyBucket) -> Value {
  record([
    ("algorithm", String("leaky_bucket")),
    ("rate", Number(self.rate)),
    ("burst", Number(self.capacity)),
    ("level", Number(self.level)),
    ("last", Number(self.last)),
  ])
}

///|
fn leaky_bucket_from_state(
  state : Value,
  rate : Double,
  capacity : Double,
) -> LeakyBucket raise InputError {
  state_name(state, "leaky_bucket")
  state_param(state, "rate", rate)
  state_param(state, "burst", capacity)
  let level = num(required(state, "level"))
  if level < 0.0 || level > capacity {
    raise InputError("initial_state level must be within 0..burst")
  }
  let last = num(required(state, "last"))
  if last < 0.0 {
    raise InputError("initial_state last must be nonnegative")
  }
  { rate, capacity, level, last, }
}

///|
fn FixedWindow::to_state(self : FixedWindow) -> Value {
  record([
    ("algorithm", String("fixed_window")),
    ("limit", Number(self.limit.to_double())),
    ("window_seconds", Number(self.window)),
    ("index", Number(self.index.to_double())),
    ("count", Number(self.count.to_double())),
  ])
}

///|
fn fixed_window_from_state(
  state : Value,
  limit : Int32,
  window : Double,
) -> FixedWindow raise InputError {
  state_name(state, "fixed_window")
  state_param(state, "limit", limit.to_double())
  state_param(state, "window_seconds", window)
  let index = state_whole(state, "index")
  let count = state_whole(state, "count")
  if count < 0 || count > limit {
    raise InputError("initial_state count must be within 0..limit")
  }
  { limit, window, index: index.to_int64(), count, }
}

///|
fn SlidingWindow::to_state(self : SlidingWindow) -> Value {
  let entries : Array[Value] = []
  for (at, weight) in self.entries {
    entries.push(
      record([("at", Number(at)), ("weight", Number(weight.to_double()))]),
    )
  }
  record([
    ("algorithm", String("sliding_window")),
    ("limit", Number(self.limit.to_double())),
    ("window_seconds", Number(self.window)),
    ("entries", Array(entries)),
  ])
}

///|
fn sliding_window_from_state(
  state : Value,
  limit : Int32,
  window : Double,
) -> SlidingWindow raise InputError {
  state_name(state, "sliding_window")
  state_param(state, "limit", limit.to_double())
  state_param(state, "window_seconds", window)
  let entries : Array[(Double, Int32)] = []
  for raw in arr(required(state, "entries")) {
    fields_only(raw, ["at", "weight"])
    let at = num(required(raw, "at"))
    if at < 0.0 {
      raise InputError("initial_state entry time must be nonnegative")
    }
    let weight = num(required(raw, "weight"))
    if weight.floor() != weight || weight < 1.0 || weight > limit.to_double() {
      raise InputError("initial_state entry weight must be 1..limit")
    }
    match entries.last() {
      Some(previous) =>
        if at < previous.0 {
          raise InputError(
            "initial_state entries must be nondecreasing in time",
          )
        }
      None => ()
    }
    entries.push((at, weight.to_int()))
  }
  { limit, window, entries, }
}

///|
fn SlidingWindowCounter::to_state(self : SlidingWindowCounter) -> Value {
  let counts : Array[Value] = []
  let origins : Array[Value] = []
  for i in 0..<self.slices {
    counts.push(Number(self.counts[i].to_double()))
    origins.push(Number(self.origins[i].to_double()))
  }
  record([
    ("algorithm", String("sliding_window_counter")),
    ("limit", Number(self.limit.to_double())),
    // The struct keeps slice_width, the window divided by slices; the state
    // reports the window, which the importer re-divides.
    ("window_seconds", Number(self.slice_width * self.slices.to_double())),
    ("slices", Number(self.slices.to_double())),
    ("counts", Array(counts)),
    ("origins", Array(origins)),
  ])
}

///|
fn sliding_window_counter_from_state(
  state : Value,
  limit : Int32,
  window : Double,
  slices : Int32,
) -> SlidingWindowCounter raise InputError {
  state_name(state, "sliding_window_counter")
  state_param(state, "limit", limit.to_double())
  state_param(state, "window_seconds", window)
  state_param(state, "slices", slices.to_double())
  let raw_counts = arr(required(state, "counts"))
  let raw_origins = arr(required(state, "origins"))
  if raw_counts.length() != slices || raw_origins.length() != slices {
    raise InputError("initial_state ring arrays must match slices")
  }
  let limiter = sliding_window_counter(limit, window, slices)
  for i in 0..<slices {
    let count = num(raw_counts[i])
    if count.floor() != count || count < 0.0 || count > limit.to_double() {
      raise InputError("initial_state counts must be whole numbers 0..limit")
    }
    let origin = num(raw_origins[i])
    if origin.floor() != origin || origin < -1.0 || origin > 2147483647.0 {
      raise InputError("initial_state origins must be whole numbers >= -1")
    }
    limiter.counts[i] = count.to_int()
    limiter.origins[i] = origin.to_int()
  }
  limiter
}

///|
fn Limiter::to_state(self : Limiter) -> Value {
  match self {
    Bucket(limiter) => limiter.to_state()
    Gcra(limiter) => limiter.to_state()
    Leaky(limiter) => limiter.to_state()
    Fixed(limiter) => limiter.to_state()
    Sliding(limiter) => limiter.to_state()
    Counter(limiter) => limiter.to_state()
  }
}
