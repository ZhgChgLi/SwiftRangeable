import Foundation

/// Boundary event kind: `open` enters the interval, `close` leaves it.
public enum TransitionKind: Equatable {
    case open
    case close
}

/// Element returned by `Rangeable.transitions(over:)`.
///
/// `coordinate` is `Int?`: `nil` represents +∞, mirroring RFC §4.7 (C4)'s
/// `Optional<Int>` close-event sentinel — when an interval has
/// `hi == Int.max`, the close event's conceptual `hi + 1` overflows, so the
/// RFC mandates `nil` to mean "greater than every finite Int".
///
/// For `kind == .open`, `coordinate` is always `Some(lo)`.
public struct TransitionEvent<Element: Hashable>: Equatable {
    /// Event coordinate. `nil` means +∞ (only possible for
    /// `kind == .close` whose source interval had `hi == Int.max`; see
    /// RFC §4.7 (C4)).
    public let coordinate: Int?

    /// Event kind (`.open` / `.close`).
    public let kind: TransitionKind

    /// Element that triggered this event.
    public let element: Element

    public init(coordinate: Int?, kind: TransitionKind, element: Element) {
        self.coordinate = coordinate
        self.kind = kind
        self.element = element
    }
}
