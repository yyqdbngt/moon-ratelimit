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
fn TokenBucket::check(
  self : TokenBucket,
  now : Double,
  weight : Double,
) -> Admission {
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
  if weight <= self.tokens {
    self.tokens = self.tokens - weight
    { allowed: true, retry_after: None, tokens: self.tokens, }
  } else {
    let deficit = weight - self.tokens
    {
      allowed: false,
      retry_after: Some(deficit / self.rate),
      tokens: self.tokens,
    }
  }
}
