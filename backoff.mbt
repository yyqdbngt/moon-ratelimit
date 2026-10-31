///|
/// One computed backoff step.
priv struct BackoffStep {
  delay_ms : Double
  previous_ms : Double
}

///|
fn backoff_step(
  jitter : String,
  base_ms : Double,
  multiplier : Double,
  max_ms : Double,
  attempt : Int32,
  previous_ms : Double,
  rng : SplitMix64,
) -> BackoffStep raise InputError {
  // Geometric growth from the base, capped: pure = base * m^(k-1). The
  // loop grows step by step so the cap applies to every intermediate value,
  // exactly like the bounded caller-side loop this models.
  let mut pure = base_ms
  for _ in 1..<attempt {
    pure = pure * multiplier
    if pure > max_ms {
      pure = max_ms
    }
  }
  let pure = if pure > max_ms { max_ms } else { pure }
  let draw = rng.next_unit()
  let delay = match jitter {
    "none" => pure
    // AWS Exponential Backoff and Jitter: full sleeps anywhere in [0, pure].
    "full" => draw * pure
    // Equal jitter keeps half the exponential and jitters the rest.
    "equal" => pure / 2.0 + draw * pure / 2.0
    // Decorrelated jitter redraws between base and 3x the previous sleep.
    "decorrelated" => {
      let ceiling = if previous_ms * 3.0 > max_ms {
        max_ms
      } else {
        previous_ms * 3.0
      }
      let low = if base_ms > ceiling { ceiling } else { base_ms }
      low + draw * (ceiling - low)
    }
    _ => raise InputError("unsupported jitter: " + jitter)
  }
  let delay = if delay > max_ms { max_ms } else { delay }
  { delay_ms: delay, previous_ms: delay, }
}

///|
fn backoff_with(request : Value) -> Value raise InputError {
  fields_only(request, [
    "operation", "strategy", "base_ms", "multiplier", "max_ms", "jitter", "attempts",
    "seed",
  ])
  let strategy = optional_str(get(request, "strategy"), "exponential")
  if strategy != "exponential" && strategy != "constant" {
    raise InputError("unsupported backoff strategy: " + strategy)
  }
  if strategy == "constant" {
    raise InputError(
      "constant strategy is not implemented in 0.1.0; exponential is",
    )
  }
  let base_ms = num(required(request, "base_ms"))
  if base_ms < 1.0 || base_ms.floor() != base_ms || base_ms > 3600000.0 {
    raise InputError("base_ms must be a whole number 1..3600000")
  }
  let multiplier = optional_num(get(request, "multiplier"), 2.0)
  if multiplier <= 1.0 || multiplier >= 10.0 {
    raise InputError("multiplier must lie within (1, 10)")
  }
  let max_ms = optional_num(get(request, "max_ms"), 30000.0)
  if max_ms < base_ms || max_ms.floor() != max_ms || max_ms > 3600000.0 {
    raise InputError("max_ms must be a whole number base_ms..3600000")
  }
  let jitter = optional_str(get(request, "jitter"), "none")
  match jitter {
    "none" | "full" | "equal" | "decorrelated" => ()
    _ => raise InputError("unsupported jitter: " + jitter)
  }
  let attempts = num(required(request, "attempts"))
  if attempts < 1.0 || attempts.floor() != attempts || attempts > 64.0 {
    raise InputError("attempts must be a whole number 1..64")
  }
  let seed = optional_num(get(request, "seed"), 0.0)
  if seed < 0.0 || seed.floor() != seed || seed > 9007199254740991.0 {
    raise InputError("seed must be a whole number 0..2^53-1")
  }
  let rng = splitmix64(seed.to_uint64())
  let delays : Array[Value] = []
  let mut previous = base_ms
  let mut capped = 0
  for attempt in 1..<(attempts.to_int() + 1) {
    let step = backoff_step(
      jitter, base_ms, multiplier, max_ms, attempt, previous, rng,
    )
    if step.delay_ms >= max_ms {
      capped += 1
    }
    previous = step.previous_ms
    delays.push(Number(step.delay_ms))
  }
  record([
    ("strategy", String(strategy)),
    ("base_ms", Number(base_ms)),
    ("multiplier", Number(multiplier)),
    ("max_ms", Number(max_ms)),
    ("jitter", String(jitter)),
    ("attempts", Number(attempts)),
    ("seed", Number(seed)),
    ("delays_ms", Array(delays)),
    ("capped_attempts", Number(capped.to_double())),
  ])
}
