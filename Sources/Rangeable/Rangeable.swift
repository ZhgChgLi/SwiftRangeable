import Foundation

/// `Rangeable` is the integer-coordinate, closed-interval, generic-element
/// container specified by RFC.md.
///
/// It maps `Hashable` elements to merged disjoint integer ranges and supports
/// three query families: by-element (`getRange(of:)`), by-position (`r[i]`),
/// and by-range (`transitions(over:)`).
///
/// `Rangeable` is a value type with copy-on-write semantics; mutations do not
/// affect other holders of an older copy. Element ordering follows RFC §4.5
/// first-insert ordering.
public struct Rangeable<Element: Hashable> {

    // MARK: - Storage (COW)

    /// COW backing storage. All mutations go through `ensureUniqueStorage()`.
    fileprivate final class Storage {
        var intervals: [Element: DisjointSet<Element>]
        var insertionOrder: [Element]
        var ord: [Element: Int]
        var version: Int
        /// Lazily built event index; cleared to nil on mutation.
        /// Note: because `BoundaryIndex` is a reference type, read-only paths
        /// can replace it (via the storage's mutable field) without breaking
        /// `Rangeable`'s value semantics.
        var eventIndex: BoundaryIndex<Element>?

        init() {
            self.intervals = [:]
            self.insertionOrder = []
            self.ord = [:]
            self.version = 0
            self.eventIndex = nil
        }

        init(copying other: Storage) {
            self.intervals = other.intervals
            self.insertionOrder = other.insertionOrder
            self.ord = other.ord
            self.version = other.version
            // The event index is an immutable snapshot; reusing it is safe
            // (no one else will mutate it).
            self.eventIndex = other.eventIndex
        }
    }

    private var storage: Storage

    // MARK: - Initialization

    /// Creates an empty container. RFC §3.1.
    public init() {
        self.storage = Storage()
    }

    /// Explicit sugar for creating an empty container, mirroring RFC §3.1's
    /// `Rangeable.empty()`.
    public static func empty() -> Rangeable<Element> {
        return Rangeable<Element>()
    }

    // MARK: - Public state

    /// The container's mutation version. Strictly increments after every
    /// "actually changed" insert; idempotent inserts MUST NOT bump
    /// (RFC §3.2, Test #21).
    public var version: Int { return storage.version }

    /// Number of distinct equivalence-class elements that have been inserted.
    /// Equal to `insertionOrder.count`, not `Σ |R(e)|`. RFC §3.5.1.
    public var count: Int { return storage.insertionOrder.count }

    /// Sugar for `count == 0`. RFC §3.5.1.
    public var isEmpty: Bool { return storage.insertionOrder.isEmpty }

    // MARK: - Insert (RFC §3.2 / §6.1)

    /// Merges the interval `[start, end]` for `element` into the container.
    /// - Parameters:
    ///   - element: The element to insert. Equal elements (by `==`) merge.
    ///   - start: Inclusive lower bound of the interval.
    ///   - end: Inclusive upper bound of the interval.
    /// - Throws: `RangeableError.invalidInterval` when `start > end`.
    /// - Important: For inserts fully contained within an existing entry,
    ///   the version MUST NOT bump (RFC §6.5.B Lemma B, Test #21 / #21.A).
    public mutating func insert(_ element: Element, start: Int, end: Int) throws {
        guard start <= end else {
            throw RangeableError.invalidInterval(start: start, end: end)
        }
        ensureUniqueStorage()

        var set = storage.intervals[element] ?? DisjointSet<Element>()
        let isFirstInsert = (storage.intervals[element] == nil)
        if isFirstInsert {
            storage.insertionOrder.append(element)
            storage.ord[element] = storage.insertionOrder.count
        }

        let result = set.insert(lo: start, hi: end)
        storage.intervals[element] = set

        switch result {
        case .mutated:
            storage.version &+= 1
            storage.eventIndex = nil
        case .idempotent:
            // No actual mutation; version stays put and the event index
            // remains valid.
            break
        }
    }

    // MARK: - getRange (RFC §3.4 / §6.2)

    /// Returns the merged disjoint intervals for `element`, sorted by `lo`
    /// ascending. Returns an empty array for elements never inserted.
    /// RFC §3.4.
    public func getRange(of element: Element) -> [Interval] {
        guard let set = storage.intervals[element] else { return [] }
        return set.toIntervals()
    }

    // MARK: - subscript (RFC §3.3 / §6.3)

    /// The list of elements active at coordinate `i`, ordered per RFC §4.5
    /// first-insert ordering. Legal for any `i ∈ ℤ` (including negatives or
    /// uncovered coordinates) and runs in `O(log M + r)`.
    public subscript(i: Int) -> Slot<Element> {
        let index = ensureEventIndexFresh()
        guard let segment = index.segment(at: i) else {
            return Slot(objs: [])
        }
        return Slot(objs: segment.active)
    }

    /// Equivalent spelling of `subscript [i]`, mirroring RFC §3.3.
    public func activeAt(index i: Int) -> Slot<Element> {
        return self[i]
    }

    // MARK: - transitions (RFC §3.5 / §6.4)

    /// Returns every boundary event in `[lo, hi]`, ordered per RFC §4.5.
    /// The query range is `lo <= ev.coord <= hi + 1`, so close events for
    /// intervals ending at `hi` (with `coord = hi+1`) are also returned.
    /// - Throws: `RangeableError.invalidInterval` when `lo > hi`.
    public func transitions(over range: ClosedRange<Int>) throws -> [TransitionEvent<Element>] {
        return try transitions(lo: range.lowerBound, hi: range.upperBound)
    }

    /// Same as `transitions(over:)` but accepts explicit `lo` / `hi`,
    /// allowing boundary tests with `lo > hi` (Swift's `ClosedRange`
    /// disallows that itself).
    /// - Throws: `RangeableError.invalidInterval` when `lo > hi`.
    public func transitions(lo: Int, hi: Int) throws -> [TransitionEvent<Element>] {
        guard lo <= hi else {
            throw RangeableError.invalidInterval(start: lo, end: hi)
        }
        let index = ensureEventIndexFresh()
        // upper := succ(hi); when hi == Int.max, upper == nil (+∞).
        let upper: Int? = (hi == .max) ? nil : hi + 1
        let evs = index.events(in: lo, upper: upper)
        return evs.map { ev in
            TransitionEvent(coordinate: ev.coordinate, kind: ev.kind, element: ev.element)
        }
    }

    // MARK: - Iteration / copy (RFC §3.5.1)

    /// Explicit deep copy. Swift value-type mutation already triggers COW,
    /// but RFC §3.5.1 requires an explicit `copy()` entry point; provided
    /// here to align with Ruby's `dup`.
    public func copy() -> Rangeable<Element> {
        var dup = Rangeable<Element>()
        dup.storage = Storage(copying: storage)
        return dup
    }

    // MARK: - Private helpers

    private mutating func ensureUniqueStorage() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = Storage(copying: storage)
        }
    }

    /// Ensures the event index is fresh and returns a `BoundaryIndex`
    /// aligned with the current `version`.
    /// This method does not need `mutating`: thanks to the reference-typed
    /// `Storage`, writing back the cache does not affect any `Rangeable`
    /// value's identity (cache write-back on the read-only path is an
    /// externally invisible implementation detail).
    private func ensureEventIndexFresh() -> BoundaryIndex<Element> {
        if let cached = storage.eventIndex, cached.version == storage.version {
            return cached
        }
        // RFC §5.2 (I3.d) cache write-back recheck: snapshot the version,
        // build, then re-compare before writing. Trivially holds in a
        // single-threaded environment; in a multi-threaded one the caller
        // must synchronize themselves (v1 single-writer / multi-reader,
        // RFC §11).
        let vStart = storage.version
        let intervalsTuples = storage.insertionOrder.compactMap { element -> (element: Element, set: DisjointSet<Element>)? in
            guard let set = storage.intervals[element] else { return nil }
            return (element: element, set: set)
        }
        let rebuilt = BoundaryIndex<Element>.build(
            intervals: intervalsTuples,
            ord: storage.ord,
            version: vStart
        )
        if storage.version == vStart {
            storage.eventIndex = rebuilt
        }
        return rebuilt
    }
}

// MARK: - Sequence conformance (RFC §3.5.1 iteration)

extension Rangeable: Sequence {

    /// Iterator over `(element, ranges)` pairs in ascending first-insert order.
    public struct Iterator: IteratorProtocol {
        private let elements: [Element]
        private let intervals: [Element: DisjointSet<Element>]
        private var cursor: Int

        fileprivate init(elements: [Element], intervals: [Element: DisjointSet<Element>]) {
            self.elements = elements
            self.intervals = intervals
            self.cursor = 0
        }

        public mutating func next() -> (Element, [Interval])? {
            guard cursor < elements.count else { return nil }
            let element = elements[cursor]
            cursor += 1
            let ranges = intervals[element]?.toIntervals() ?? []
            return (element, ranges)
        }
    }

    public func makeIterator() -> Iterator {
        return Iterator(elements: storage.insertionOrder, intervals: storage.intervals)
    }
}

// MARK: - Sugar protocol (RFC §3.4)

/// Marker protocol that grants custom `Hashable` types the
/// `e.getRange(from: r)` sugar.
///
/// RFC §12.2's earlier draft proposed adding the sugar directly via
/// `extension Hashable`, but that would pollute the entire Swift standard
/// library's `Hashable` namespace. This protocol is the opt-in alternative:
/// have your custom type conform to `RangeableElement` to call
/// `getRange(from:)` on its instances.
public protocol RangeableElement: Hashable {}

public extension RangeableElement {
    /// Sugar for `r.getRange(of: self)`.
    func getRange(from rangeable: Rangeable<Self>) -> [Interval] {
        return rangeable.getRange(of: self)
    }
}
