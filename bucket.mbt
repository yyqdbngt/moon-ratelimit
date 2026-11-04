///|
/// One admission decision at one instant. `retry_after` is the exact number
/// of seconds until a request of the same weight could be admitted; it is
/// null when the decision is to allow.
priv struct Admission {
  allowed : Bool
  retry_after : Double?
  tokens : Double
}

///|
/// A token bucket: capacity tokens, refilled continuously at `rate` tokens
/// per second. Time is passed in, never read, so every decision is a pure
/// function of (state, now, weight) and replays deterministically.
priv struct TokenBucket {
  rate : Double
  capacity : Double
  mut tokens : Double
  mut last : Double
}

///|
fn token_bucket(rate : Double, capacity : Double) -> TokenBucket {
  // Full at construction, which is the standard initial state.
  { rate, capacity, tokens: capacity, last: 0.0, }
}

///|
/// The decision for (now, weight) computed against the time-advanced state,
/// without changing the bucket. `check` is decide plus commit; compose calls
/// decide on every limiter first and commits only when all of them allow.
fn TokenBucket::decide(
  self : TokenBucket,
  now : Double,
  weight : Double,
) -> Admission {
  let elapsed = now - self.last
  let available = if elapsed > 0.0 {
    let refilled = self.tokens + elapsed * self.rate
    if refilled > self.capacity {
      self.capacity
    } else {
      refilled
    }
  } else {
    self.tokens
  }
  if weight <= available {
    { allowed: true, retry_after: None, tokens: available - weight, }
  } else {
    let deficit = weight - available
    {
      allowed: false,
      retry_after: Some(deficit / self.rate),
      tokens: available,
    }
  }
}

///|
/// Applies one event: the refill fold happens for denied events too, exactly
/// as the single-bucket path always has, so folding is never skipped and
/// floating-point results stay identical to the unfolded sequence.
fn TokenBucket::commit(
  self : TokenBucket,
  now : Double,
  weight : Double,
  allowed : Bool,
) -> Unit {
  let elapsed = now - self.last
  if elapsed > 0.0 {
    let refilled = self.tokens + elapsed * self.rate
    self.tokens = if refilled > self.capacity {
      self.capacity
    } else {
      refilled
    }
    self.last = now
  }
  if allowed {
    self.tokens = self.tokens - weight
  }
}

///|
fn TokenBucket::check(
  self : TokenBucket,
  now : Double,
  weight : Double,
) -> Admission {
  let decision = self.decide(now, weight)
  self.commit(now, weight, decision.allowed)
  decision
}
