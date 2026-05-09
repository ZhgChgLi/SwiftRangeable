import Foundation

/// Immutable closed integer interval `[lo, hi]`.
///
/// Used as the storage unit inside `Rangeable`'s `DisjointSet`, and also as
/// the public element returned by `getRange(of:)`. Equality is structural
/// (same `lo` / `hi` means equal).
public struct Interval: Equatable, Hashable {
    /// Inclusive lower bound.
    public let lo: Int

    /// Inclusive upper bound.
    public let hi: Int

    /// Creates `[lo, hi]`. `lo > hi` is illegal (RFC §4.4 D1).
    /// - Important: This initializer enforces `lo <= hi` via `precondition`.
    ///   The public `Rangeable.insert` path checks first and throws
    ///   `RangeableError`; the precondition here only guards the internal
    ///   invariant.
    public init(lo: Int, hi: Int) {
        precondition(lo <= hi, "Interval requires lo (\(lo)) <= hi (\(hi))")
        self.lo = lo
        self.hi = hi
    }

    /// Whether the interval contains coordinate `coord` (closed range).
    public func contains(_ coord: Int) -> Bool {
        return lo <= coord && coord <= hi
    }
}
