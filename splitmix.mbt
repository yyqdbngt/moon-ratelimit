///|
/// SplitMix64, seeded by the caller: a deterministic, non-cryptographic
/// generator whose entire state is one word, so a jitter table reproduces
/// bit for bit on every backend from the seed in the request. It is not a
/// security primitive and says so wherever it is used.
priv struct SplitMix64 {
  mut state : UInt64
}

///|
fn splitmix64(seed : UInt64) -> SplitMix64 {
  { state: seed, }
}

///|
fn SplitMix64::next_unit(self : SplitMix64) -> Double {
  // The mixing constants are the published SplitMix64 constants.
  self.state = self.state + 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z = z ^ (z >> 31)
  // 53 bits into [0, 1): doubles hold 53 significant bits, so every value
  // this returns is a distinct double with no rounding.
  (z >> 11).to_double() / 9007199254740992.0
}
