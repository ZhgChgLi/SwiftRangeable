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

    /// Result code for any v2 mutation that may shrink the set
    /// (`subtract(lo:hi:)`, `subtractList`, `intersectList`,
    /// `symmetricDifferenceList`). `Rangeable` peels `becameEmpty` to drive
    /// eager pruning per RFC §4.10 (N1).
    enum MutationResult: Equatable {
        /// Nothing changed; caller MUST NOT bump `version` and MUST NOT
        /// invalidate `event_index` (RFC §4.10 (N3)).
        case unchanged
        /// The set actually changed. `becameEmpty == true` triggers eager
        /// pruning of the parent element (RFC §4.10 (N1)).
        case mutated(becameEmpty: Bool)
    }

    /// Sorted disjoint interval entries.
    private(set) var entries: [Interval] = []

    var isEmpty: Bool { return entries.isEmpty }
    var count: Int { return entries.count }

    /// Snapshot of merged intervals. Mirrors Ruby's `to_pairs`.
    func toIntervals() -> [Interval] {
        return entries
    }

    /// Internal initialiser used by set-op constructions to bypass the
    /// `insert(lo:hi:)` path. The caller MUST guarantee that `entries` is
    /// already (I1)-canonical.
    init(canonicalEntries: [Interval]) {
        self.entries = canonicalEntries
    }

    init() {}

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

    // MARK: - v2 mutating: subtract(lo:hi:)  (RFC §6.6 sweep+splice)

    /// Removes the closed interval `[lo, hi]` from this set.
    ///
    /// Implements the RFC §6.6 sweep + splice algorithm:
    ///  * `bsearch` for the first entry overlapping `[lo, hi]`.
    ///  * Sweep right, producing 0..2 residual sub-intervals per consumed
    ///    entry (left + right residual).
    ///  * Splice the residuals back in place.
    ///
    /// - Returns: `.unchanged` if no entry overlaps (idempotent no-op);
    ///   otherwise `.mutated(becameEmpty:)` with `becameEmpty == true` when
    ///   every residual collapsed to nothing.
    @discardableResult
    mutating func subtract(lo: Int, hi: Int) -> MutationResult {
        precondition(lo <= hi, "DisjointSet.subtract requires lo (\(lo)) <= hi (\(hi))")

        // Step 3: leftmost entry whose hi >= lo (strict overlap, NOT
        // adjacency). When `iv.hi >= lo` for some entry we may need to cut.
        let i0 = lowerBound(predicate: { iv in iv.hi >= lo })

        // Step 4: nothing overlaps — idempotent no-op (§4.10 (N3)).
        if i0 == entries.count || entries[i0].lo > hi {
            return .unchanged
        }

        // Step 5: sweep all entries whose `lo <= hi` and produce 0..2
        // residuals each. `start - 1` and `end + 1` are computed only when
        // the corresponding `iv.lo < lo` / `hi < iv.hi` guard holds — see
        // RFC §6.6 underflow/overflow safety note.
        var i = i0
        var replacements: [Interval] = []
        while i < entries.count && entries[i].lo <= hi {
            let iv = entries[i]
            // Left residual: (iv.lo, lo - 1) only when iv.lo < lo, so
            // `lo > iv.lo >= Int.min`, hence `lo - 1` is safe.
            if iv.lo < lo {
                replacements.append(Interval(lo: iv.lo, hi: lo - 1))
            }
            // Right residual: (hi + 1, iv.hi) only when hi < iv.hi, so
            // `hi < iv.hi <= Int.max`, hence `hi + 1` is safe.
            if hi < iv.hi {
                replacements.append(Interval(lo: hi + 1, hi: iv.hi))
            }
            i += 1
        }

        // Step 7: splice [i0, i) with the residuals.
        entries.replaceSubrange(i0..<i, with: replacements)
        return .mutated(becameEmpty: entries.isEmpty)
    }

    // MARK: - v2 set ops over canonical lists

    /// Returns `merge_disjoint_lists(self, other)` per RFC §6.10:
    /// two-pointer linear sweep (`O(m + n)`) with `append_or_merge`
    /// adjacency-collapse. Both inputs MUST be (I1)-canonical.
    func unionList(_ other: DisjointSet<Element>) -> [Interval] {
        let l1 = self.entries
        let l2 = other.entries
        if l1.isEmpty { return l2 }
        if l2.isEmpty { return l1 }
        var out: [Interval] = []
        out.reserveCapacity(l1.count + l2.count)
        var i = 0
        var j = 0
        while i < l1.count && j < l2.count {
            if l1[i].lo <= l2[j].lo {
                appendOrMerge(&out, l1[i]); i += 1
            } else {
                appendOrMerge(&out, l2[j]); j += 1
            }
        }
        while i < l1.count { appendOrMerge(&out, l1[i]); i += 1 }
        while j < l2.count { appendOrMerge(&out, l2[j]); j += 1 }
        return out
    }

    /// Returns `intersect_disjoint_lists(self, other)` per RFC §6.11:
    /// two-pointer pairwise intersection (`O(m + n)`). Both inputs MUST
    /// be (I1)-canonical. Lemma 6.11.A shows the output is (I1)-canonical
    /// without needing an explicit adjacency-collapse step.
    func intersectList(_ other: DisjointSet<Element>) -> [Interval] {
        let l1 = self.entries
        let l2 = other.entries
        if l1.isEmpty || l2.isEmpty { return [] }
        var out: [Interval] = []
        var i = 0
        var j = 0
        while i < l1.count && j < l2.count {
            let lo = max(l1[i].lo, l2[j].lo)
            let hi = min(l1[i].hi, l2[j].hi)
            if lo <= hi {
                out.append(Interval(lo: lo, hi: hi))
            }
            if l1[i].hi <= l2[j].hi {
                i += 1
            } else {
                j += 1
            }
        }
        return out
    }

    /// Returns `subtract_disjoint_lists(self, other)` per RFC §6.12:
    /// two-pointer sweep (`O(m + n)`). Both inputs MUST be (I1)-canonical.
    /// Underflow/overflow safety: `other[j].lo - 1` and `other[j].hi + 1`
    /// are computed only behind their respective guards (RFC §6.12 dual
    /// safety note).
    func subtractList(_ other: DisjointSet<Element>) -> [Interval] {
        let lA = self.entries
        let lB = other.entries
        if lA.isEmpty { return [] }
        if lB.isEmpty { return lA }
        var out: [Interval] = []
        var i = 0
        var j = 0
        var hasCurrent = false
        var currentLo = 0
        var currentHi = 0
        while i < lA.count {
            if !hasCurrent {
                currentLo = lA[i].lo
                currentHi = lA[i].hi
                hasCurrent = true
            }
            // Skip lB entries strictly before the current entry.
            while j < lB.count && lB[j].hi < currentLo {
                j += 1
            }
            if j == lB.count || lB[j].lo > currentHi {
                // No more cuts on this current entry; commit and advance.
                out.append(Interval(lo: currentLo, hi: currentHi))
                i += 1
                hasCurrent = false
                continue
            }
            // lB[j] overlaps [currentLo, currentHi]; cut.
            if lB[j].lo > currentLo {
                // Left residual: (currentLo, lB[j].lo - 1). Guard
                // `lB[j].lo > currentLo` means `lB[j].lo > Int.min`, so
                // `lB[j].lo - 1` is safe.
                out.append(Interval(lo: currentLo, hi: lB[j].lo - 1))
            }
            if lB[j].hi < currentHi {
                // Right residual remains current; advance j. Guard
                // `lB[j].hi < currentHi` means `lB[j].hi < Int.max`, so
                // `lB[j].hi + 1` is safe.
                currentLo = lB[j].hi + 1
                j += 1
            } else {
                // lB[j] swallows the rest of the current entry; advance i.
                i += 1
                hasCurrent = false
            }
        }
        return out
    }

    /// Returns `R_self △ R_other` per RFC §6.13 (per-element, both inputs
    /// (I1)-canonical, output (I1)-canonical). Implements the
    /// `(a ∖ b) ∪ (b ∖ a)` identity, then runs `merge_disjoint_lists` to
    /// collapse the two one-sided residuals' possible adjacency
    /// (worked example in RFC §6.13: `[(0,5)]` △ `[(6,10)] = [(0,10)]`).
    func symmetricDifferenceList(_ other: DisjointSet<Element>) -> [Interval] {
        let aMinusB = self.subtractList(other)
        let bMinusA = other.subtractList(self)
        if aMinusB.isEmpty { return bMinusA }
        if bMinusA.isEmpty { return aMinusB }
        return DisjointSet.mergeCanonical(aMinusB, bMinusA)
    }

    // MARK: - private helpers for set ops

    /// Two-pointer linear merge (free function form) used by
    /// `symmetricDifferenceList` to combine two (I1)-canonical lists with
    /// adjacency-collapse via `appendOrMerge`.
    private static func mergeCanonical(_ l1: [Interval], _ l2: [Interval]) -> [Interval] {
        var out: [Interval] = []
        out.reserveCapacity(l1.count + l2.count)
        var i = 0
        var j = 0
        while i < l1.count && j < l2.count {
            if l1[i].lo <= l2[j].lo {
                appendOrMergeStatic(&out, l1[i]); i += 1
            } else {
                appendOrMergeStatic(&out, l2[j]); j += 1
            }
        }
        while i < l1.count { appendOrMergeStatic(&out, l1[i]); i += 1 }
        while j < l2.count { appendOrMergeStatic(&out, l2[j]); j += 1 }
        return out
    }

    /// `append_or_merge` per RFC §6.10: append a copy of `iv` if it does
    /// not touch the running tail, else extend the tail's `hi`. Adjacency
    /// (`tail.hi + 1 == iv.lo`) is treated as touch (RFC §4.3).
    private func appendOrMerge(_ out: inout [Interval], _ iv: Interval) {
        DisjointSet.appendOrMergeStatic(&out, iv)
    }

    private static func appendOrMergeStatic(_ out: inout [Interval], _ iv: Interval) {
        if let last = out.last {
            // touch := iv.lo <= last.hi + 1 (overlap or adjacency).
            // Underflow-safe: iv.lo is finite; last.hi + 1 is finite when
            // last.hi < Int.max, otherwise last.hi == Int.max already
            // dominates iv.lo and we extend the tail unconditionally.
            let touch: Bool
            if last.hi == .max {
                touch = true
            } else {
                touch = iv.lo <= last.hi + 1
            }
            if touch {
                let newHi = last.hi >= iv.hi ? last.hi : iv.hi
                if newHi != last.hi {
                    out[out.count - 1] = Interval(lo: last.lo, hi: newHi)
                }
                return
            }
        }
        out.append(iv)
    }
}
