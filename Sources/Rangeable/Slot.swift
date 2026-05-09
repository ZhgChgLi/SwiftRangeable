import Foundation

/// Wrapper return type for `Rangeable`'s subscript.
///
/// To align with RFC §3.3 and leave room for future fields, `subscript [i]`
/// does not return an array directly — it wraps the result in `Slot`. The
/// `objs` element order is defined by RFC §4.5 first-insert ordering
/// (sorted by `ord(e)` ascending).
public struct Slot<Element: Hashable>: Equatable {
    /// Elements active at this coordinate, in first-insert ascending order.
    public let objs: [Element]

    /// Creates a `Slot`. Called by `Rangeable` internals.
    public init(objs: [Element]) {
        self.objs = objs
    }

    /// Sugar for `objs.isEmpty`.
    public var isEmpty: Bool { return objs.isEmpty }

    /// Sugar for `objs.count`.
    public var count: Int { return objs.count }
}
