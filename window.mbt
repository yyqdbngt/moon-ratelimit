///|
/// A fixed window counter: `limit` events per `window_seconds`, counted per
/// wall-clock window. The known flaw is deliberate and demonstrated by test:
/// a full allowance at the end of one window plus a full allowance at the
/// start of the next passes 2x the limit through a trailing window that
/// straddles the boundary. The sliding window exists for callers that cannot
/// accept that; this one costs two integers.
priv struct FixedWindow {
  limit : Int32
  window : Double
  mut index : Int64
  mut count : Int32
}

///|
fn fixed_window(limit : Int32, window : Double) -> FixedWindow {
  { limit, window, index: -1, count: 0, }
}

///|
fn FixedWindow::check(
  self : FixedWindow,
  now : Double,
  weight : Int32,
) -> Admission {
  let index = (now / self.window).floor().to_int64()
  if index != self.index {
    self.index = index
    self.count = 0
  }
  if self.count + weight <= self.limit {
    self.count = self.count + weight
    {
      allowed: true,
      retry_after: None,
      tokens: (self.limit - self.count).to_double(),
    }
  } else {
    let boundary = (index + 1).to_double() * self.window
    {
      allowed: false,
      retry_after: Some(boundary - now),
      tokens: (self.limit - self.count).to_double(),
    }
  }
}

///|
/// An exact sliding window: every admitted (time, weight) is remembered, and
/// an event is admitted when the total weight inside (now - window, now]
/// plus its own stays within the limit. Exactness costs memory proportional
/// to the events in one window; that boundary is documented, not hidden.
priv struct SlidingWindow {
  limit : Int32
  window : Double
  entries : Array[(Double, Int32)]
}

///|
fn sliding_window(limit : Int32, window : Double) -> SlidingWindow {
  { limit, window, entries: [], }
}

///|
fn SlidingWindow::sum(self : SlidingWindow, now : Double) -> Int32 {
  let mut total = 0
  for entry in self.entries {
    if entry.0 > now - self.window {
      total += entry.1
    }
  }
  total
}

///|
fn SlidingWindow::check(
  self : SlidingWindow,
  now : Double,
  weight : Int32,
) -> Admission {
  let held = self.sum(now)
  if held + weight <= self.limit {
    self.entries.push((now, weight))
    {
      allowed: true,
      retry_after: None,
      tokens: (self.limit - held - weight).to_double(),
    }
  } else {
    // The earliest expiries that would free enough room: walk oldest-first
    // until the remainder fits, and name that entry's expiry moment.
    let mut kept = held
    let mut expiry : Double? = None
    let mut index = 0
    while index < self.entries.length() && expiry is None {
      let (at, entry_weight) = self.entries[index]
      if at > now - self.window {
        kept -= entry_weight
        if kept + weight <= self.limit {
          expiry = Some(at + self.window - now)
        }
      }
      index += 1
    }
    match expiry {
      Some(seconds) =>
        {
          allowed: false,
          retry_after: Some(seconds),
          tokens: (self.limit - held).to_double(),
        }
      None =>
        // A single weight above the limit can never fit; the caller hears
        // that as a refusal to answer with a retry time.
        {
          allowed: false,
          retry_after: None,
          tokens: (self.limit - held).to_double(),
        }
    }
  }
}
