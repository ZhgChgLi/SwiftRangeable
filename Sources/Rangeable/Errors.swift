import Foundation

/// Public error type for `Rangeable` operations.
///
/// Mirrors RFC §3.2 / §3.7's `InvalidIntervalError`. Ruby's
/// `Rangeable::InvalidIntervalError` (subclassing `ArgumentError`) maps to
/// this Swift `Error` enum's `.invalidInterval(start:end:)` case.
public enum RangeableError: Error, Equatable {
    /// Thrown when `insert(_:start:end:)` receives `start > end`, or when
    /// `transitions(over:)` receives `lo > hi`. The container state MUST
    /// be unchanged (RFC §4.4 D1's exception-safety contract).
    case invalidInterval(start: Int, end: Int)
}
