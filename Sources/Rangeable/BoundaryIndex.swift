import Foundation

/// Lazy boundary-event index per RFC §5.2 / §6.3.
///
/// Built once from a snapshot of each per-element `DisjointSet` plus the
/// `ord` map:
///
///  * `events`   — sweep events ordered per RFC §4.5.
///  * `segments` — non-overlapping ordered segments, each annotated with the
///                 list of active elements (sorted by ord ascending).
///  * `version`  — snapshot of `Rangeable.version` at build time; on
///                 mutation `Rangeable` clears any externally held index to
///                 trigger a rebuild.
///
/// `coordinate` is `Int?`; `nil` represents +∞ (the RFC §4.7 (C4) sentinel).
///
/// This type is an internal `final class` so that `Rangeable`'s lazy build
/// can be shared by reference outside of a `mutating get`.
internal final class BoundaryIndex<Element: Hashable> {

    /// Internal sweep event. `coordinate == nil` represents +∞ (close-only).
    struct Event {
        let coordinate: Int?
        let kind: TransitionKind
        let element: Element
        let ord: Int
    }

    /// Largest segment over which the active set does not change.
    struct Segment {
        let lo: Int
        let hi: Int
        let active: [Element]
    }

    let events: [Event]
    let segments: [Segment]
    let version: Int

    init(events: [Event], segments: [Segment], version: Int) {
        self.events = events
        self.segments = segments
        self.version = version
    }

    /// Returns the segment containing `coord`, or `nil` if none.
    /// Corresponds to RFC §6.3's `subscript [i]` binary search.
    func segment(at coord: Int) -> Segment? {
        // bsearch first segment with hi >= coord
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if segments[mid].hi >= coord {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        guard lo < segments.count else { return nil }
        let seg = segments[lo]
        return seg.lo <= coord ? seg : nil
    }

    /// Implements RFC §6.4 `transitions(over:)`: returns events in
    /// `[lo, upper]`. `upper == nil` means +∞ (includes every close event
    /// whose `coord == nil`).
    func events(in lo: Int, upper: Int?) -> [Event] {
        let iStart = firstIndex { ev in compareCoord(ev.coordinate, .some(lo)) >= 0 }
        var result: [Event] = []
        var i = iStart
        while i < events.count && compareCoord(events[i].coordinate, upper) <= 0 {
            result.append(events[i])
            i += 1
        }
        return result
    }

    /// Builds a fresh index from the per-element intervals and `ord` map.
    /// - Parameter intervals: Element list in first-insert order paired with
    ///   each element's disjoint set.
    /// - Parameter ord: element → 1-based first-insert sequence number.
    /// - Parameter version: snapshot of `Rangeable.version` at build time.
    static func build(
        intervals: [(element: Element, set: DisjointSet<Element>)],
        ord: [Element: Int],
        version: Int
    ) -> BoundaryIndex<Element> {
        var events: [Event] = []
        events.reserveCapacity(intervals.reduce(0) { $0 + $1.set.count } * 2)
        for (element, set) in intervals {
            guard let elementOrd = ord[element] else { continue }
            for iv in set.toIntervals() {
                events.append(Event(coordinate: iv.lo, kind: .open, element: element, ord: elementOrd))
                let closeCoord: Int? = (iv.hi == .max) ? nil : iv.hi + 1
                events.append(Event(coordinate: closeCoord, kind: .close, element: element, ord: elementOrd))
            }
        }

        // Sort: coord ascending (nil == +∞ goes last); same coord puts open
        // before close; same coord and same kind sorts opens by ord
        // ascending and closes by ord descending.
        events.sort { (a, b) -> Bool in
            let cmp = compareCoord(a.coordinate, b.coordinate)
            if cmp != 0 { return cmp < 0 }
            // open before close
            let kindRankA = (a.kind == .open) ? 0 : 1
            let kindRankB = (b.kind == .open) ? 0 : 1
            if kindRankA != kindRankB { return kindRankA < kindRankB }
            if a.kind == .open {
                return a.ord < b.ord
            } else {
                return a.ord > b.ord
            }
        }

        let segments = materializeSegments(events: events)
        return BoundaryIndex(events: events, segments: segments, version: version)
    }

    /// Linear sweep over events to produce segments. Per RFC §6.3, no
    /// segment with an empty active set is emitted.
    static func materializeSegments(events: [Event]) -> [Segment] {
        var segments: [Segment] = []
        // active_by_ord: keyed by ord, mapping to element. Swift Dictionary
        // does not guarantee iteration order, so explicitly sort by ord
        // ascending when snapshotting.
        var activeByOrd: [Int: Element] = [:]
        var prevCoord: Int? = nil
        var hasPrev = false
        var i = 0
        while i < events.count {
            let coord = events[i].coordinate

            if hasPrev && !activeByOrd.isEmpty, let p = prevCoord {
                // Segment hi = predecessor(coord). When coord == nil (+∞),
                // hi = Int.max; when coord == finite c, hi = c - 1.
                // c == Int.min cannot occur (any active element implies a
                // prior open, and any later coord must be > that open's
                // coord, so the smallest reachable coord is Int.min + 1).
                let segHi: Int
                if let c = coord {
                    segHi = c - 1
                } else {
                    segHi = .max
                }
                segments.append(Segment(lo: p, hi: segHi, active: snapshotActive(activeByOrd)))
            }

            // Apply every event at this coord.
            while i < events.count && coordEqual(events[i].coordinate, coord) {
                let ev = events[i]
                if ev.kind == .open {
                    activeByOrd[ev.ord] = ev.element
                } else {
                    activeByOrd.removeValue(forKey: ev.ord)
                }
                i += 1
            }

            prevCoord = coord
            hasPrev = true
        }
        return segments
    }

    private static func snapshotActive(_ activeByOrd: [Int: Element]) -> [Element] {
        return activeByOrd.keys.sorted().map { activeByOrd[$0]! }
    }

    /// Total ordering on `Int?` coords: finite < nil (+∞). Returns -1 / 0 / 1.
    static func compareCoord(_ a: Int?, _ b: Int?) -> Int {
        switch (a, b) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case let (.some(lhs), .some(rhs)):
            if lhs < rhs { return -1 }
            if lhs > rhs { return 1 }
            return 0
        }
    }

    private static func coordEqual(_ a: Int?, _ b: Int?) -> Bool {
        return compareCoord(a, b) == 0
    }

    /// Private instance helper: bsearch the first index satisfying the
    /// predicate (lower_bound).
    private func firstIndex(where predicate: (Event) -> Bool) -> Int {
        var lo = 0
        var hi = events.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if predicate(events[mid]) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }

    private func compareCoord(_ a: Int?, _ b: Int?) -> Int {
        return BoundaryIndex.compareCoord(a, b)
    }
}
