///|
/// GCRA, the Generic Cell Rate Algorithm, kept in the form that makes its
/// equivalence with the token bucket a theorem rather than a hope: the state
/// is the theoretical arrival time `tat` of the next conforming arrival, and
/// the invariant
///
///     tokens(now) == capacity - rate * max(0, tat - now)
///
/// holds exactly. The equivalence tests below re-derive it on deterministic
/// and pseudo-random schedules by running both limiters side by side.
priv struct Gcra {
  rate : Double
  capacity : Double
  mut tat : Double
}

///|
fn gcra(rate : Double, capacity : Double) -> Gcra {
  // tat 0 matches a bucket that starts full at time 0.
  { rate, capacity, tat: 0.0, }
}

///|
fn Gcra::tokens_now(self : Gcra, now : Double) -> Double {
  let ahead = self.tat - now
  if ahead > 0.0 {
    self.capacity - self.rate * ahead
  } else {
    self.capacity
  }
}

///|
fn Gcra::check(self : Gcra, now : Double, weight : Double) -> Admission {
  let tokens = self.tokens_now(now)
  if weight <= tokens {
    let start = if self.tat > now { self.tat } else { now }
    self.tat = start + weight / self.rate
    { allowed: true, retry_after: None, tokens: tokens - weight, }
  } else {
    // Deficit over rate: identical in value to the bucket's arithmetic.
    let deficit = weight - tokens
    { allowed: false, retry_after: Some(deficit / self.rate), tokens, }
  }
}
