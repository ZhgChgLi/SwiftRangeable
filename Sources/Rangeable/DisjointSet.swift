import Foundation

/// Sorted disjoint interval list for a single element.
///
/// Maintains the RFC §5.1 (I1) invariants:
///  * Strictly ascending order by `lo`.
///  * Adjacent entries `(lo₁, hi₁), (lo₂, hi₂)` satisfy `hi₁ + 1 < lo₂`
///    (no overlap, no integer adjacency).
///  * `lo <= hi`.
///
/// `insert(lo:hi:)` follows the RFC §6.1 cleaner variant: a containment
/// fast-path returns `.idempotent` when fully covered, leaving the caller
/// to decide whether to bump the version.
internal struct DisjointSet<Element: Hashable> {

    /// Result code for `insert`. `Rangeable` uses this to decide whether to
    /// bump `version`.
    enum InsertResult {
        /// Standard mutation path — caller should bump version and
        /// invalidate the event index.
        case mutated
        /// Interval is fully contained by an existing entry; caller MUST
        /// NOT bump version (RFC §6.5.B Lemma B, Test #21 / #21.A).
        case idempotent
    }

    /// Sorted disjoint interval entries.
    private(set) var entries: [Interval] = []

    var isEmpty: Bool { return entries.isEmpty }
    var count: Int { return entries.count }

    /// Snapshot of merged intervals. Mirrors Ruby's `to_pairs`.
    func toIntervals() -> [Interval] {
        return entries
    }

    /// Merges `[lo, hi]` into this set.
    /// - Returns: `.idempotent` if `[lo, hi]` is fully contained by an
    ///   existing entry; otherwise `.mutated`.
    @discardableResult
    mutating func insert(lo: Int, hi: Int) -> InsertResult {
        precondition(lo <= hi, "DisjointSet.insert requires lo (\(lo)) <= hi (\(hi))")

        // Step 4 (RFC §6.1): bsearch the leftmost touch candidate.
        // The predicate is `iv.hi + 1 >= lo`; when `iv.hi == Int.max`,
        // `iv.hi + 1` is conceptually +∞ and always ≥ any finite `lo`, so
        // succ is treated as true.
        let i0 = lowerBound(predicate: { iv in succAtLeast(iv.hi, lo) })

        // Step 5: gather every touching entry.
        // Predicate `entries[i].lo <= hi + 1`; when `hi == Int.max` it is
        // always true.
        var toMergeEnd = i0
        while toMergeEnd < entries.count && loAtMost(entries[toMergeEnd].lo, hi) {
            toMergeEnd += 1
        }
        let mergeCount = toMergeEnd - i0

        // Step 6: containment idempotent fast-path.
        if mergeCount == 1 {
            let existing = entries[i0]
            if existing.lo <= lo && hi <= existing.hi {
                return .idempotent
            }
        }

        // Step 7: real mutation — splice in the merged interval.
        var newLo = lo
        var newHi = hi
        if mergeCount > 0 {
            let first = entries[i0]
            let last = entries[toMergeEnd - 1]
            if first.lo < newLo { newLo = first.lo }
            if last.hi > newHi { newHi = last.hi }
        }
        let merged = Interval(lo: newLo, hi: newHi)
        if mergeCount > 0 {
            entries.replaceSubrange(i0..<toMergeEnd, with: [merged])
        } else {
            entries.insert(merged, at: i0)
        }
        return .mutated
    }

    // MARK: - Private helpers

    /// `lower_bound` style binary search: returns the leftmost index
    /// satisfying `predicate`, or `entries.count` if none does.
    private func lowerBound(predicate: (Interval) -> Bool) -> Int {
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if predicate(entries[mid]) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }

    /// Safely computes `hi + 1 >= lo` (with `hi == Int.max` treated as +∞,
    /// always true). Per RFC §6.1's note: MUST NOT be written as
    /// `iv.hi >= lo - 1` because that underflows when `lo == Int.min`.
    private func succAtLeast(_ hi: Int, _ lo: Int) -> Bool {
        if hi == .max { return true }
        return hi + 1 >= lo
    }

    /// Safely computes `entryLo <= hi + 1` (with `hi == Int.max` treated as
    /// +∞, always true).
    private func loAtMost(_ entryLo: Int, _ hi: Int) -> Bool {
        if hi == .max { return true }
        return entryLo <= hi + 1
    }
}
