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

    // MARK: - Removal API (v2; RFC §6.6 / §6.7 / §6.8 / §6.9)

    /// Removes the closed interval `[start, end]` from `R(element)`.
    ///
    /// Implements RFC §6.6:
    ///  * Pre-condition `start <= end` (D1) — throws otherwise.
    ///  * If `element ∉ keys(self)` or no entry overlaps `[start, end]`,
    ///    the call is a no-op and `version` MUST NOT bump (RFC §4.10
    ///    (N3)).
    ///  * Otherwise the overlapping entries are sliced into 0..2 residual
    ///    sub-intervals each; if every residual collapses to nothing, the
    ///    element is eagerly pruned per RFC §4.10 (N1).
    ///
    /// - Throws: `RangeableError.invalidInterval` when `start > end`. The
    ///   container state MUST be unchanged on throw (atomicity).
    public mutating func remove(_ element: Element, start: Int, end: Int) throws {
        guard start <= end else {
            throw RangeableError.invalidInterval(start: start, end: end)
        }
        ensureUniqueStorage()

        // Step 2: element-presence fast-path.
        guard var set = storage.intervals[element] else {
            return
        }

        let result = set.subtract(lo: start, hi: end)
        switch result {
        case .unchanged:
            // No-op — version unchanged, event_index unchanged.
            return
        case .mutated(let becameEmpty):
            if becameEmpty {
                // Eager prune: excise from intervals, insertion_order, ord.
                excise(element)
            } else {
                storage.intervals[element] = set
            }
            storage.version &+= 1
            storage.eventIndex = nil
        }
    }

    /// Sugar for `remove(element, start: range.lowerBound, end: range.upperBound)`.
    /// `ClosedRange<Int>` already enforces `lowerBound <= upperBound`.
    public mutating func remove(_ element: Element, over range: ClosedRange<Int>) throws {
        try remove(element, start: range.lowerBound, end: range.upperBound)
    }

    /// Removes the element entirely, regardless of how many intervals it
    /// has. RFC §6.7. No-op (no version bump) if the element was never
    /// inserted.
    public mutating func remove(_ element: Element) {
        ensureUniqueStorage()
        guard storage.intervals[element] != nil else {
            return
        }
        excise(element)
        storage.version &+= 1
        storage.eventIndex = nil
    }

    /// Empties the container. RFC §6.8. No-op (no version bump) when
    /// already empty.
    public mutating func removeAll() {
        ensureUniqueStorage()
        if storage.intervals.isEmpty {
            return
        }
        storage.intervals.removeAll(keepingCapacity: false)
        storage.insertionOrder.removeAll(keepingCapacity: false)
        storage.ord.removeAll(keepingCapacity: false)
        storage.version &+= 1
        storage.eventIndex = nil
    }

    /// Removes `[start, end]` from every element's `R(e)` in one atomic
    /// step. Bumps `version` exactly once when at least one element
    /// actually changed; throws on `start > end` before any mutation.
    /// RFC §6.9.
    public mutating func removeRanges(start: Int, end: Int) throws {
        guard start <= end else {
            throw RangeableError.invalidInterval(start: start, end: end)
        }
        ensureUniqueStorage()

        // Walk every element in the current insertion order, but defer the
        // O(E) `insertion_order` rebuild until after the per-element loop
        // (avoids the O(E²) trap of `delete_at` per element).
        var anyChange = false
        let snapshot = storage.insertionOrder
        for element in snapshot {
            guard var set = storage.intervals[element] else { continue }
            let result = set.subtract(lo: start, hi: end)
            switch result {
            case .unchanged:
                continue
            case .mutated(let becameEmpty):
                anyChange = true
                if becameEmpty {
                    storage.intervals.removeValue(forKey: element)
                    storage.ord.removeValue(forKey: element)
                    // insertion_order rebuild deferred to after the loop.
                } else {
                    storage.intervals[element] = set
                }
            }
        }

        if !anyChange {
            return
        }

        // Single-pass rebuild of insertion_order + ord (RFC §6.9 step 4).
        let survivors = snapshot.filter { storage.intervals[$0] != nil }
        if survivors.count != snapshot.count {
            storage.insertionOrder = survivors
            storage.ord.removeAll(keepingCapacity: true)
            for (idx, e) in survivors.enumerated() {
                storage.ord[e] = idx + 1
            }
        }
        storage.version &+= 1
        storage.eventIndex = nil
    }

    /// Sugar form using `ClosedRange<Int>`.
    public mutating func removeRanges(over range: ClosedRange<Int>) throws {
        try removeRanges(start: range.lowerBound, end: range.upperBound)
    }

    // MARK: - Set operations (v2; RFC §6.10–§6.13)

    /// Mutating union with `other` (RFC §6.10 in-place form). Bumps
    /// `version` iff the result is structurally `!= self` (any keys added,
    /// any `R(e)` enlarged). When `other` shares storage with `self`, the
    /// op is a no-op (idempotence dual of RFC §3.2).
    public mutating func formUnion(_ other: Rangeable<Element>) {
        ensureUniqueStorage()
        // Self-union shortcut: same storage means structurally identical.
        if storage === other.storage {
            return
        }
        let merged = Rangeable.computeUnion(self, other)
        if !Rangeable.storageEquivalent(self, merged) {
            adoptStorage(of: merged, bumpVersion: true)
        }
    }

    /// Non-mutating union with `other`. Returns a fresh `Rangeable` with
    /// `version == 0`; the source is unchanged.
    public func union(_ other: Rangeable<Element>) -> Rangeable<Element> {
        return Rangeable.computeUnion(self, other)
    }

    /// Mutating intersection with `other` (RFC §6.11 in-place form). Bumps
    /// `version` iff the result is structurally `!= self` (any keys
    /// dropped, any `R(e)` shrunk).
    public mutating func formIntersection(_ other: Rangeable<Element>) {
        ensureUniqueStorage()
        if storage === other.storage {
            return
        }
        let intersected = Rangeable.computeIntersection(self, other)
        if !Rangeable.storageEquivalent(self, intersected) {
            adoptStorage(of: intersected, bumpVersion: true)
        }
    }

    /// Non-mutating intersection with `other`. Returns a fresh
    /// `Rangeable` with `version == 0`.
    public func intersection(_ other: Rangeable<Element>) -> Rangeable<Element> {
        return Rangeable.computeIntersection(self, other)
    }

    /// Mutating set difference (RFC §6.12 in-place form). Bumps `version`
    /// iff any `R_self(e)` shrunk.
    public mutating func subtract(_ other: Rangeable<Element>) {
        ensureUniqueStorage()
        if storage === other.storage {
            // self ∖ self == ∅; only bump if self had anything to remove.
            if !storage.insertionOrder.isEmpty {
                removeAll()
            }
            return
        }
        let diff = Rangeable.computeDifference(self, other)
        if !Rangeable.storageEquivalent(self, diff) {
            adoptStorage(of: diff, bumpVersion: true)
        }
    }

    /// Non-mutating set difference. Returns a fresh `Rangeable` with
    /// `version == 0`.
    public func subtracting(_ other: Rangeable<Element>) -> Rangeable<Element> {
        return Rangeable.computeDifference(self, other)
    }

    /// Mutating symmetric difference (RFC §6.13 in-place form). Bumps
    /// `version` iff the result is structurally `!= self`. Note that
    /// `r.formSymmetricDifference(r)` clears `r` and bumps once.
    public mutating func formSymmetricDifference(_ other: Rangeable<Element>) {
        ensureUniqueStorage()
        if storage === other.storage {
            if !storage.insertionOrder.isEmpty {
                removeAll()
            }
            return
        }
        let sym = Rangeable.computeSymmetricDifference(self, other)
        if !Rangeable.storageEquivalent(self, sym) {
            adoptStorage(of: sym, bumpVersion: true)
        }
    }

    /// Non-mutating symmetric difference. Returns a fresh `Rangeable`
    /// with `version == 0`.
    public func symmetricDifference(_ other: Rangeable<Element>) -> Rangeable<Element> {
        return Rangeable.computeSymmetricDifference(self, other)
    }

    // MARK: - Private helpers

    private mutating func ensureUniqueStorage() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = Storage(copying: storage)
        }
    }

    /// Excises `element` from all three element-keyed structures and
    /// densely renumbers `ord` over the remaining elements (RFC §4.10
    /// (N1)). The caller owns the version bump and event-index
    /// invalidation.
    private func excise(_ element: Element) {
        guard let idx = storage.insertionOrder.firstIndex(of: element) else { return }
        storage.intervals.removeValue(forKey: element)
        storage.insertionOrder.remove(at: idx)
        storage.ord.removeValue(forKey: element)
        // Dense renumber for elements at positions >= idx.
        for i in idx..<storage.insertionOrder.count {
            storage.ord[storage.insertionOrder[i]] = i + 1
        }
    }

    /// Replaces `self.storage` with the result of a set-op compute. When
    /// `bumpVersion` is true, `version` is incremented exactly once over
    /// the previous self (per RFC §6.10–§6.13 mutating-form rule); the
    /// fresh container's `version == 0` is intentionally discarded.
    private mutating func adoptStorage(of fresh: Rangeable<Element>, bumpVersion: Bool) {
        let priorVersion = storage.version
        // The compute helpers always produce a uniquely owned storage.
        storage = fresh.storage
        if bumpVersion {
            storage.version = priorVersion &+ 1
        } else {
            storage.version = priorVersion
        }
        storage.eventIndex = nil
    }

    /// Tests whether two `Rangeable`s have the same observable contents:
    /// same `insertion_order`, same per-element entries, same `ord`. Used
    /// to drive the mutating set-ops' "no actual change" branch (RFC
    /// §6.10 idempotence dual).
    private static func storageEquivalent(_ a: Rangeable<Element>, _ b: Rangeable<Element>) -> Bool {
        if a.storage === b.storage { return true }
        if a.storage.insertionOrder != b.storage.insertionOrder { return false }
        if a.storage.intervals.count != b.storage.intervals.count { return false }
        for e in a.storage.insertionOrder {
            guard let sa = a.storage.intervals[e], let sb = b.storage.intervals[e] else {
                return false
            }
            if sa.entries != sb.entries { return false }
        }
        return true
    }

    // MARK: - Set-op compute helpers (build fresh Rangeable; never call insert())

    /// Builds a fresh `Rangeable` whose storage is populated directly,
    /// bypassing `insert()` so we avoid per-iteration version bumps and
    /// event-index rebuilds (RFC §B.1 Swift implementation note).
    private static func makeFromCanonical(
        _ contents: [(element: Element, entries: [Interval])]
    ) -> Rangeable<Element> {
        let fresh = Rangeable<Element>()
        let s = fresh.storage
        s.insertionOrder.reserveCapacity(contents.count)
        for (idx, item) in contents.enumerated() {
            s.intervals[item.element] = DisjointSet(canonicalEntries: item.entries)
            s.insertionOrder.append(item.element)
            s.ord[item.element] = idx + 1
        }
        s.version = 0
        s.eventIndex = nil
        return fresh
    }

    /// Builds the union per RFC §6.10. Walks `lhs.insertion_order` first
    /// (each key in self appears, possibly extended by other), then
    /// tail-appends keys in `keys(other) ∖ keys(self)` in `other`'s
    /// insertion order.
    private static func computeUnion(
        _ lhs: Rangeable<Element>,
        _ rhs: Rangeable<Element>
    ) -> Rangeable<Element> {
        var contents: [(element: Element, entries: [Interval])] = []
        contents.reserveCapacity(lhs.storage.insertionOrder.count + rhs.storage.insertionOrder.count)

        for e in lhs.storage.insertionOrder {
            // R(e) is non-empty by (I1.4) — guaranteed by eager pruning.
            let lset = lhs.storage.intervals[e]!
            if let rset = rhs.storage.intervals[e] {
                contents.append((e, lset.unionList(rset)))
            } else {
                contents.append((e, lset.entries))
            }
        }

        for e in rhs.storage.insertionOrder {
            if lhs.storage.intervals[e] != nil { continue }
            // Tail-append in other's insertion order.
            let rset = rhs.storage.intervals[e]!
            contents.append((e, rset.entries))
        }

        return makeFromCanonical(contents)
    }

    /// Builds the intersection per RFC §6.11. Walks `lhs.insertion_order`
    /// over keys also in `rhs`; eager-prunes any element whose intersection
    /// is empty.
    private static func computeIntersection(
        _ lhs: Rangeable<Element>,
        _ rhs: Rangeable<Element>
    ) -> Rangeable<Element> {
        var contents: [(element: Element, entries: [Interval])] = []
        contents.reserveCapacity(Swift.min(lhs.storage.insertionOrder.count, rhs.storage.insertionOrder.count))
        for e in lhs.storage.insertionOrder {
            guard let rset = rhs.storage.intervals[e] else { continue }
            let lset = lhs.storage.intervals[e]!
            let inter = lset.intersectList(rset)
            if inter.isEmpty { continue }   // eager prune §4.10 (N1)
            contents.append((e, inter))
        }
        return makeFromCanonical(contents)
    }

    /// Builds the difference per RFC §6.12. Walks `lhs.insertion_order`;
    /// every element either survives intact (no key in `rhs`) or is
    /// subtracted via `subtractList`.
    private static func computeDifference(
        _ lhs: Rangeable<Element>,
        _ rhs: Rangeable<Element>
    ) -> Rangeable<Element> {
        var contents: [(element: Element, entries: [Interval])] = []
        contents.reserveCapacity(lhs.storage.insertionOrder.count)
        for e in lhs.storage.insertionOrder {
            let lset = lhs.storage.intervals[e]!
            let remaining: [Interval]
            if let rset = rhs.storage.intervals[e] {
                remaining = lset.subtractList(rset)
            } else {
                remaining = lset.entries
            }
            if remaining.isEmpty { continue }   // eager prune §4.10 (N1)
            contents.append((e, remaining))
        }
        return makeFromCanonical(contents)
    }

    /// Builds the symmetric difference per RFC §6.13. Self-primary keys
    /// are walked first (using the `(a∖b) ∪ (b∖a)` identity per element);
    /// other-only keys are tail-appended in `other`'s insertion order.
    private static func computeSymmetricDifference(
        _ lhs: Rangeable<Element>,
        _ rhs: Rangeable<Element>
    ) -> Rangeable<Element> {
        var contents: [(element: Element, entries: [Interval])] = []
        contents.reserveCapacity(lhs.storage.insertionOrder.count + rhs.storage.insertionOrder.count)

        for e in lhs.storage.insertionOrder {
            let lset = lhs.storage.intervals[e]!
            let sym: [Interval]
            if let rset = rhs.storage.intervals[e] {
                sym = lset.symmetricDifferenceList(rset)
            } else {
                // R_other(e) == ∅ ⇒ symdiff degenerates to R_self(e).
                sym = lset.entries
            }
            if sym.isEmpty { continue }   // eager prune §4.10 (N1)
            contents.append((e, sym))
        }

        for e in rhs.storage.insertionOrder {
            if lhs.storage.intervals[e] != nil { continue }
            // R_self(e) == ∅ ⇒ symdiff degenerates to R_other(e).
            let rset = rhs.storage.intervals[e]!
            contents.append((e, rset.entries))
        }

        return makeFromCanonical(contents)
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
