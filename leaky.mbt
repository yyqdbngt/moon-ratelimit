///|
/// A leaky bucket: capacity units of queue, draining continuously at `rate`
/// units per second. An event pours `weight` units in; if the bucket would
/// overflow the event is denied and the excess is reported. The dual of the
/// token bucket, expressed from the queue side.
priv struct LeakyBucket {
  rate : Double
  capacity : Double
  mut level : Double
  mut last : Double
}

///|
fn leaky_bucket(rate : Double, capacity : Double) -> LeakyBucket {
  // Starts empty: the bucket has no backlog.
  { rate, capacity, level: 0.0, last: 0.0, }
}

///|
fn LeakyBucket::check(
  self : LeakyBucket,
  now : Double,
  weight : Double,
) -> Admission {
  let elapsed = now - self.last
  if elapsed > 0.0 {
    let drained = self.level - elapsed * self.rate
    self.level = if drained < 0.0 { 0.0 } else { drained }
    self.last = now
  }
  if self.level + weight <= self.capacity {
    self.level = self.level + weight
    { allowed: true, retry_after: None, tokens: self.capacity - self.level, }
  } else {
    let overflow = self.level + weight - self.capacity
    {
      allowed: false,
      retry_after: Some(overflow / self.rate),
      tokens: self.capacity - self.level,
    }
  }
}
