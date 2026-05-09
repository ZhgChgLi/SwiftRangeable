import Foundation

/// Deterministic PRNG (SplitMix64), used by property tests.
///
/// `SystemRandomNumberGenerator` cannot be seeded, so it cannot reproduce
/// sequences. SplitMix64 is Sebastiano Vigna's high-quality fixed-step
/// generator; given the same seed, the produced sequence is byte-identical
/// across platforms. Ruby's `Random.new(seed)` uses Mersenne Twister, so the
/// sequences differ between languages, but we only need determinism *within*
/// the same language (property tests are reproducible from a single seed
/// without needing to be byte-identical with Ruby — RFC §10 Test #20's note
/// already permits the "share pre-generated triples between languages"
/// workaround, while we instead run an independent brute-force oracle in
/// each language).
struct SeedableRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the degenerate sequence when seed == 0.
        self.state = seed == 0 ? 0xdead_beef_dead_beef : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Returns an Int in the closed interval `[lower, upper]`, distributed
    /// nearly uniformly (modulo bias is acceptable for testing).
    mutating func intInRange(_ lower: Int, through upper: Int) -> Int {
        precondition(lower <= upper)
        let range = UInt64(upper - lower + 1)
        let r = next() % range
        return lower + Int(r)
    }
}
