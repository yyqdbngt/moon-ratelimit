///|
/// Approximate sliding window counter: divides time into `slices` fixed
/// sub-windows and admits against the sum of the `slices` sub-windows
/// ending at the current one. That sum covers the trailing window
/// (now - window, now] with an error of at most one sub-window's count,
/// because the true window starts partway through the oldest sub-window
/// summed. Memory is O(slices), not O(events).
/// Each ring slot remembers which sub-window index it was last written
/// for, and a slot read for any other index counts as zero. That
/// bookkeeping is what stops a reused slot from leaking a count written
/// one full ring earlier, and it removes the need for an aging pass.
priv struct SlidingWindowCounter {
  limit : Int32
  slices : Int32
  counts : Array[Int32]
  origins : Array[Int32]
  slice_width : Double
}

///|
fn sliding_window_counter(
  limit : Int32,
  window : Double,
  slices : Int32,
) -> SlidingWindowCounter {
  {
    limit,
    slices,
    counts: Array::make(slices, 0),
    origins: Array::make(slices, -1),
    slice_width: window / slices.to_double(),
  }
}

///|
/// The stored count of sub-window `index`, or zero when the slot it maps
/// to was last written for a different sub-window.
fn SlidingWindowCounter::held_at(
  self : SlidingWindowCounter,
  index : Int32,
) -> Int32 {
  let slot = (index % self.slices + self.slices) % self.slices
  if self.origins[slot] == index {
    self.counts[slot]
  } else {
    0
  }
}

///|
fn SlidingWindowCounter::check(
  self : SlidingWindowCounter,
  now : Double,
  weight : Int32,
) -> Admission {
  let current = (now / self.slice_width).floor().to_int()
  // Sub-windows older than the `slices` ending at `current` lie outside
  // the trailing window and are never summed, so they need no erasure.
  let mut held = 0
  for i in 0..<self.slices {
    let index = current - i
    if index >= 0 {
      held += self.held_at(index)
    }
  }
  if held + weight <= self.limit {
    let slot = (current % self.slices + self.slices) % self.slices
    if self.origins[slot] != current {
      self.origins[slot] = current
      self.counts[slot] = 0
    }
    self.counts[slot] = self.counts[slot] + weight
    {
      allowed: true,
      retry_after: None,
      tokens: (self.limit - held - weight).to_double(),
    }
  } else {
    // Capacity reappears only when `current` advances and the oldest
    // summed sub-window leaves the range, which happens at the next
    // sub-window boundary.
    {
      allowed: false,
      retry_after: Some((current + 1).to_double() * self.slice_width - now),
      tokens: (self.limit - held).to_double(),
    }
  }
}
