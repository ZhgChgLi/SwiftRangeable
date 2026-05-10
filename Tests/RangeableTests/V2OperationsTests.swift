import XCTest
@testable import Rangeable

/// Mirrors the v2 normative test contracts in RFC §10.B–§10.G:
/// removal (#21–#43) and set ops (#44–#80). Test ids in comments use the
/// `§10.B #N` etc. convention from the RFC; per-method happy-path,
/// boundary, idempotence, eager-prune, COW, and atomicity probes are
/// grouped per method.
final class V2OperationsTests: XCTestCase {

    // Helpers

    private func iv(_ lo: Int, _ hi: Int) -> Interval {
        return Interval(lo: lo, hi: hi)
    }

    private func keysInOrder<E: Hashable>(_ r: Rangeable<E>) -> [E] {
        return r.map { $0.0 }
    }

    // ============================================================
    // §10.B — remove(e, start, end) — RFC §6.6, tests #21–#31
    // ============================================================

    /// §10.B #21 — no overlap MUST NOT bump version.
    func test_remove_eStartEnd_noOverlap_isNoOp() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 10, end: 20)
        let v0 = r.version
        try r.remove(.strong, start: 0, end: 5)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(10, 20)])
        XCTAssertEqual(r.version, v0, "no-overlap remove MUST NOT bump version")
        XCTAssertEqual(r.count, 1)
    }

    /// §10.B #22 — exact-match consumes one entry, eager-prunes element.
    func test_remove_eStartEnd_exactMatchConsumesEntry() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 10, end: 20)
        let v0 = r.version
        try r.remove(.strong, start: 10, end: 20)
        XCTAssertEqual(r.count, 0)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [])
        XCTAssertEqual(r.version, v0 + 1, "actual change MUST bump version exactly once")
    }

    /// §10.B #23 — left residual only.
    func test_remove_eStartEnd_leftResidualOnly() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.remove(.strong, start: 5, end: 100)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 4)])
    }

    /// §10.B #24 — right residual only.
    func test_remove_eStartEnd_rightResidualOnly() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.remove(.strong, start: -100, end: 5)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(6, 10)])
    }

    /// §10.B #25 — split into two residuals.
    func test_remove_eStartEnd_splitProducesTwoResiduals() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.remove(.strong, start: 3, end: 6)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 2), iv(7, 10)])
    }

    /// §10.B #26 — span multiple entries.
    func test_remove_eStartEnd_spansMultipleEntries() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.strong, start: 10, end: 15)
        try r.insert(.strong, start: 20, end: 25)
        try r.remove(.strong, start: 3, end: 22)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 2), iv(23, 25)])
    }

    /// §10.B #27 — removing entire R(e) eager-prunes element and shifts
    /// other elements' ord.
    func test_remove_eStartEnd_fullySpansEagerPrune() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.strong, start: 10, end: 15)
        try r.insert(.italic, start: 7, end: 8)
        let v0 = r.version
        try r.remove(.strong, start: -100, end: 100)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(keysInOrder(r), [.italic])
        XCTAssertEqual(r[7].objs, [.italic])
        XCTAssertEqual(r.version, v0 + 1)
    }

    /// §10.B #28 — no-op remove (overlap miss + element absent) MUST NOT
    /// bump version, on either path.
    func test_remove_eStartEnd_noOpDoesNotBump() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 10, end: 20)
        let v0 = r.version
        try r.remove(.strong, start: 30, end: 40)   // overlap miss
        XCTAssertEqual(r.version, v0)
        try r.remove(.italic, start: 0, end: 5)     // never inserted
        XCTAssertEqual(r.version, v0)
    }

    /// §10.B #29 — start > end MUST raise and leave state unchanged.
    func test_remove_eStartEnd_startGtEndThrowsAtomically() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        let v0 = r.version
        XCTAssertThrowsError(try r.remove(.strong, start: 7, end: 3)) { err in
            guard case RangeableError.invalidInterval(let s, let e) = err else {
                XCTFail("expected invalidInterval, got \(err)"); return
            }
            XCTAssertEqual(s, 7); XCTAssertEqual(e, 3)
        }
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 10)])
        XCTAssertEqual(r.version, v0)
    }

    /// §10.B #30 — start == Int.min underflow safety: when iv.lo == start
    /// no left residual is built, so `start - 1 = Int.min - 1` is never
    /// computed.
    func test_remove_eStartEnd_intMinUnderflowSafe() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: .min, end: .min + 100)
        try r.remove(.strong, start: .min, end: .min + 50)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(.min + 51, .min + 100)])
    }

    /// §10.B #31 — end == Int.max overflow safety: when end == iv.hi no
    /// right residual is built, so `end + 1 = Int.max + 1` is never
    /// computed.
    func test_remove_eStartEnd_intMaxOverflowSafe() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: .max)
        try r.remove(.strong, start: 1000, end: .max)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 999)])
    }

    /// Bonus — remove(_:over:) sugar matches start/end form.
    func test_remove_eOverRange_sugarMatches() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.remove(.strong, over: 3...6)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 2), iv(7, 10)])
    }

    // ============================================================
    // §10.B — remove(e) — RFC §6.7, tests #32–#35
    // ============================================================

    /// §10.B #32 — excise from intervals + insertion_order + ord; renumber.
    func test_removeElement_excisesAndRenumbers() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.italic, start: 7, end: 12)
        try r.insert(.code, start: 15, end: 20)
        let v0 = r.version
        r.remove(.italic)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(keysInOrder(r), [.strong, .code])
        XCTAssertEqual(r[16].objs, [.code])  // implies ord(code) == 1 → still last visually but ord shifts.
        XCTAssertEqual(r.version, v0 + 1)
    }

    /// §10.B #33 — remove(e) on never-inserted element MUST NOT bump.
    func test_removeElement_neverInsertedDoesNotBump() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        let v0 = r.version
        r.remove(.italic)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.version, v0)
    }

    /// §10.B #34 — remove(e) on element with single interval.
    func test_removeElement_singleIntervalEmpties() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 5, end: 10)
        r.remove(.strong)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.count, 0)
    }

    /// §10.B #35 — remove(e) on element with many intervals deletes them all.
    func test_removeElement_manyIntervalsAllGone() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.strong, start: 10, end: 15)
        try r.insert(.strong, start: 20, end: 25)
        r.remove(.strong)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [])
    }

    /// Bonus — remove(e) preserves ordering of subsequent insertions
    /// (Test #78 cross-ref).
    func test_removeElement_thenReinsertGetsFreshOrd() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)    // ord(strong)=1
        try r.insert(.italic, start: 10, end: 15)  // ord(italic)=2
        r.remove(.strong)
        try r.insert(.strong, start: 100, end: 110)
        XCTAssertEqual(keysInOrder(r), [.italic, .strong])
    }

    // ============================================================
    // §10.B — removeAll() / clear() — RFC §6.8, tests #36–#40
    // ============================================================

    /// §10.B #36 — clear non-empty bumps version once.
    func test_removeAll_nonEmptyBumpsOnce() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.italic, start: 7, end: 12)
        let v0 = r.version
        r.removeAll()
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r), [])
        XCTAssertEqual(r.version, v0 + 1)
    }

    /// §10.B #37 — clear empty MUST NOT bump version.
    func test_removeAll_emptyDoesNotBump() {
        var r = Rangeable<AnyMarkup>()
        let v0 = r.version
        r.removeAll()
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.version, v0)
    }

    /// §10.B #38 — post-clear isEmpty + queries.
    func test_removeAll_postClearQueriesAreEmpty() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        r.removeAll()
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r[3].objs, [])
        XCTAssertEqual(try r.transitions(over: 0...10).count, 0)
    }

    /// §10.B #39 — post-clear count.
    func test_removeAll_postClearCountIsZero() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.italic, start: 7, end: 12)
        r.removeAll()
        XCTAssertEqual(r.count, 0)
        var iter = r.makeIterator()
        XCTAssertNil(iter.next())
    }

    /// §10.B #40 — insert after clear assigns ord = 1.
    func test_removeAll_insertAfterAssignsFreshOrd() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.italic, start: 7, end: 12)
        r.removeAll()
        try r.insert(.code, start: 100, end: 110)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(keysInOrder(r), [.code])
    }

    // ============================================================
    // §10.B — removeRanges(start, end) — RFC §6.9, tests #41–#43
    // ============================================================

    /// §10.B #41 — broad range hits multiple elements; single bump.
    func test_removeRanges_broadRangeMultipleElements() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.insert(.italic, start: 5, end: 15)
        try r.insert(.code, start: 100, end: 110)
        let v0 = r.version
        try r.removeRanges(start: 3, end: 8)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 2), iv(9, 10)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r), [iv(9, 15)])
        XCTAssertEqual(AnyMarkup.code.getRange(from: r), [iv(100, 110)])
        XCTAssertEqual(r.version, v0 + 1, "exactly one bump for the entire op")
    }

    /// §10.B #42 — no overlap on any element MUST NOT bump.
    func test_removeRanges_noOverlapDoesNotBump() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.insert(.italic, start: 50, end: 60)
        let v0 = r.version
        try r.removeRanges(start: 20, end: 30)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 10)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r), [iv(50, 60)])
        XCTAssertEqual(r.version, v0)
    }

    /// §10.B #43 — broad range fully covers everything (variant 1).
    func test_removeRanges_fullySwallowsAll() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.italic, start: 10, end: 20)
        try r.insert(.code, start: 25, end: 30)
        let v0 = r.version
        try r.removeRanges(start: 0, end: 30)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.version, v0 + 1)
    }

    /// §10.B #43 (variant) — partial: prunes Italic, retains Strong + Code,
    /// densely renumbers ord (Strong=1, Code=2 originally Strong=1, Italic=2,
    /// Code=3).
    func test_removeRanges_mixedPruneAndRetainRenumbersOrd() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 5)
        try r.insert(.italic, start: 10, end: 20)
        try r.insert(.code, start: 25, end: 30)
        let v0 = r.version
        try r.removeRanges(start: 8, end: 22)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r), [])
        XCTAssertEqual(AnyMarkup.code.getRange(from: r), [iv(25, 30)])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(keysInOrder(r), [.strong, .code])
        XCTAssertEqual(r.version, v0 + 1)
    }

    /// §9 case 33 / §10.B #29 atomicity: start > end raises before any
    /// mutation.
    func test_removeRanges_startGtEndThrowsAtomically() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        let v0 = r.version
        XCTAssertThrowsError(try r.removeRanges(start: 5, end: 3)) { err in
            guard case RangeableError.invalidInterval(let s, let e) = err else {
                XCTFail("expected invalidInterval"); return
            }
            XCTAssertEqual(s, 5); XCTAssertEqual(e, 3)
        }
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 10)])
        XCTAssertEqual(r.version, v0)
    }

    /// Bonus — removeRanges(over:) sugar matches.
    func test_removeRanges_overRangeSugar() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        try r.removeRanges(over: 3...6)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(0, 2), iv(7, 10)])
    }

    // ============================================================
    // §10.C — union — RFC §6.10, tests #44–#50
    // ============================================================

    /// §10.C #44 — disjoint elements; insertion order preserved.
    func test_union_disjointKeys() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.italic, start: 10, end: 15)
        let v1Before = r1.version
        let v2Before = r2.version
        let r3 = r1.union(r2)
        XCTAssertEqual(r3.count, 2)
        XCTAssertEqual(keysInOrder(r3), [.strong, .italic])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r3), [iv(10, 15)])
        XCTAssertEqual(r3.version, 0)
        XCTAssertEqual(r1.version, v1Before)
        XCTAssertEqual(r2.version, v2Before)
    }

    /// §10.C #45 — same element, overlapping intervals.
    func test_union_sharedElementOverlapping() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 5, end: 15)
        let r3 = r1.union(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 15)])
        XCTAssertEqual(r3.count, 1)
    }

    /// §10.C #46 — adjacency-merge in append_or_merge.
    func test_union_adjacencyMerge() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 6, end: 10)
        let r3 = r1.union(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 10)])
    }

    /// §10.C #47 — formUnion with subset MUST NOT bump version
    /// (idempotence dual).
    func test_formUnion_idempotentSubsetDoesNotBump() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        try r1.insert(.italic, start: 20, end: 30)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 3, end: 7)
        let v0 = r1.version
        r1.formUnion(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r1), [iv(0, 10)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r1), [iv(20, 30)])
        XCTAssertEqual(r1.version, v0)
    }

    /// §10.C #48 — union of two empties = empty.
    func test_union_twoEmpties() {
        let r1 = Rangeable<AnyMarkup>()
        let r2 = Rangeable<AnyMarkup>()
        let r3 = r1.union(r2)
        XCTAssertTrue(r3.isEmpty)
        XCTAssertEqual(r3.count, 0)
        XCTAssertEqual(r3.version, 0)
    }

    /// §10.C #49 — union with self = self structurally; mutating form
    /// MUST NOT bump.
    func test_union_withSelfStructurallyEqual() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.italic, start: 10, end: 15)
        let v0 = r1.version
        let r2 = r1.union(r1)
        XCTAssertEqual(keysInOrder(r2), keysInOrder(r1))
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r2), AnyMarkup.strong.getRange(from: r1))
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r2), AnyMarkup.italic.getRange(from: r1))
        XCTAssertEqual(r2.version, 0)
        XCTAssertEqual(r1.version, v0)

        // Mutating form on self.
        var r3 = r1.copy()
        let v3Before = r3.version
        r3.formUnion(r3)
        XCTAssertEqual(r3.version, v3Before)
    }

    /// §10.C #50 — insertion_order tail-append in other's order.
    func test_union_insertionOrderTailAppend() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 1)         // self order: [strong]
        try r1.insert(.italic, start: 2, end: 3)         // self order: [strong, italic]
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.code, start: 4, end: 5)           // other order: [code]
        try r2.insert(.italic, start: 10, end: 11)       // other order: [code, italic]
        try r2.insert(.link("d"), start: 12, end: 13)    // other order: [code, italic, link("d")]
        let r3 = r1.union(r2)
        XCTAssertEqual(keysInOrder(r3), [.strong, .italic, .code, .link("d")])
    }

    /// COW — union must not mutate r1 / r2.
    func test_union_copyOnWriteIsolation() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.italic, start: 10, end: 20)
        let r1Snapshot = r1.copy()
        _ = r1.union(r2)
        XCTAssertEqual(keysInOrder(r1), keysInOrder(r1Snapshot))
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r1), AnyMarkup.strong.getRange(from: r1Snapshot))
    }

    // ============================================================
    // §10.D — intersect — RFC §6.11, tests #51–#57
    // ============================================================

    /// §10.D #51 — no shared keys → empty.
    func test_intersect_noSharedKeys() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.italic, start: 5, end: 15)
        let r3 = r1.intersection(r2)
        XCTAssertTrue(r3.isEmpty)
        XCTAssertEqual(r3.count, 0)
    }

    /// §10.D #52 — shared overlapping intervals.
    func test_intersect_sharedOverlapping() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 5, end: 15)
        let r3 = r1.intersection(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(5, 10)])
        XCTAssertEqual(r3.count, 1)
    }

    /// §10.D #53 — shared but disjoint → element pruned.
    func test_intersect_sharedDisjointPrunesElement() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 100, end: 200)
        let r3 = r1.intersection(r2)
        XCTAssertTrue(r3.isEmpty)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [])
    }

    /// §10.D #54 — intersect with self = self.
    func test_intersect_withSelf() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.italic, start: 10, end: 15)
        let v0 = r1.version
        let r2 = r1.intersection(r1)
        XCTAssertEqual(keysInOrder(r2), keysInOrder(r1))
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r2), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r2), [iv(10, 15)])
        XCTAssertEqual(r2.version, 0)
        XCTAssertEqual(r1.version, v0)
    }

    /// §10.D #55 — intersect with empty = empty.
    func test_intersect_withEmpty() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.italic, start: 10, end: 15)
        let r2 = Rangeable<AnyMarkup>()
        let r3 = r1.intersection(r2)
        XCTAssertTrue(r3.isEmpty)
    }

    /// §10.D #56 — intersection produces multiple sub-intervals per element.
    func test_intersect_multipleSubIntervals() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.strong, start: 10, end: 15)
        try r1.insert(.strong, start: 20, end: 25)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 3, end: 22)
        let r3 = r1.intersection(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3),
                       [iv(3, 5), iv(10, 15), iv(20, 22)])
    }

    /// §10.D #57 — insertion order preservation + dense ord renumber.
    func test_intersect_insertionOrderAndDenseOrd() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("a"), start: 0, end: 5)
        try r1.insert(.link("b"), start: 10, end: 15)
        try r1.insert(.link("c"), start: 20, end: 25)
        try r1.insert(.link("d"), start: 30, end: 35)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("a"), start: 0, end: 5)
        try r2.insert(.link("c"), start: 21, end: 24)
        try r2.insert(.link("e"), start: 100, end: 200)
        let r3 = r1.intersection(r2)
        XCTAssertEqual(keysInOrder(r3), [.link("a"), .link("c")])
        XCTAssertEqual(AnyMarkup.link("a").getRange(from: r3), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.link("c").getRange(from: r3), [iv(21, 24)])
    }

    /// formIntersection mutating + bump rule.
    func test_formIntersection_idempotentSelfDoesNotBump() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.italic, start: 10, end: 15)
        let v0 = r1.version
        r1.formIntersection(r1)
        XCTAssertEqual(r1.version, v0)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r1), [iv(0, 5)])
    }

    // ============================================================
    // §10.E — difference — RFC §6.12, tests #58–#65
    // ============================================================

    /// §10.E #58 — disjoint elements; result structurally equal to self.
    func test_difference_disjointKeys() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.italic, start: 5, end: 15)
        let r3 = r1.subtracting(r2)
        XCTAssertEqual(keysInOrder(r3), [.strong])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 10)])
        XCTAssertEqual(r3.version, 0)
    }

    /// §10.E #59 — difference with self = empty.
    func test_difference_withSelfEmpty() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        try r1.insert(.italic, start: 20, end: 30)
        let r2 = r1.subtracting(r1)
        XCTAssertTrue(r2.isEmpty)
        XCTAssertEqual(r2.count, 0)
    }

    /// §10.E #60 — left residuals.
    func test_difference_leftResiduals() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 5, end: 100)
        let r3 = r1.subtracting(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 4)])
    }

    /// §10.E #61 — right residuals.
    func test_difference_rightResiduals() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: -100, end: 5)
        let r3 = r1.subtracting(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(6, 10)])
    }

    /// §10.E #62 — both residuals (split).
    func test_difference_bothResidualsSplit() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 3, end: 6)
        let r3 = r1.subtracting(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 2), iv(7, 10)])
    }

    /// §10.E #63 — subtract spans multiple L_a entries.
    func test_difference_spansMultipleEntries() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.strong, start: 10, end: 15)
        try r1.insert(.strong, start: 20, end: 25)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 3, end: 22)
        let r3 = r1.subtracting(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 2), iv(23, 25)])
    }

    /// §10.E #64 — insertion order preservation.
    func test_difference_insertionOrderPreserved() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("a"), start: 0, end: 5)
        try r1.insert(.link("b"), start: 10, end: 15)
        try r1.insert(.link("c"), start: 20, end: 25)
        try r1.insert(.link("d"), start: 30, end: 35)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("b"), start: 9, end: 16)   // fully consumes B
        try r2.insert(.link("e"), start: 100, end: 200) // ignored — not in r1
        let r3 = r1.subtracting(r2)
        XCTAssertEqual(keysInOrder(r3), [.link("a"), .link("c"), .link("d")])
    }

    /// §10.E #65 — difference ≡ removeRanges-loop equivalence (structural,
    /// only when the cuts don't cross-pollute elements).
    ///
    /// Important: the RFC §6.12 informative equivalence holds only under
    /// the structural condition that every interval in `other` covers
    /// only those positions in `self` that map to the *same* element. For
    /// our test we use a setup where every element in `r1` shares the
    /// same coordinate range, and `r2` carries the same range under each
    /// of r1's keys — so per-element diff and blanket `removeRanges`
    /// converge.
    func test_difference_equivalentToRemoveRangesLoop() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 20)
        try r1.insert(.italic, start: 0, end: 20)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 5, end: 8)
        try r2.insert(.italic, start: 5, end: 8)
        try r2.insert(.strong, start: 12, end: 15)
        try r2.insert(.italic, start: 12, end: 15)
        let r3 = r1.subtracting(r2)
        var r4 = r1.copy()
        try r4.removeRanges(start: 5, end: 8)
        try r4.removeRanges(start: 12, end: 15)
        XCTAssertEqual(keysInOrder(r3), keysInOrder(r4))
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), AnyMarkup.strong.getRange(from: r4))
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r3), AnyMarkup.italic.getRange(from: r4))
        // Both should be [(0,4), (9,11), (16,20)] for each element.
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3),
                       [iv(0, 4), iv(9, 11), iv(16, 20)])
    }

    /// subtract mutating bumps once when changed.
    func test_subtract_mutatingBumpsOnce() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 3, end: 6)
        let v0 = r1.version
        r1.subtract(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r1), [iv(0, 2), iv(7, 10)])
        XCTAssertEqual(r1.version, v0 + 1)
    }

    /// subtract: subtracting disjoint MUST NOT bump (no actual change).
    func test_subtract_mutatingDisjointDoesNotBump() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.italic, start: 0, end: 10)
        let v0 = r1.version
        r1.subtract(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r1), [iv(0, 10)])
        XCTAssertEqual(r1.version, v0)
    }

    // ============================================================
    // §10.F — symmetric_difference — RFC §6.13, tests #66–#71
    // ============================================================

    /// §10.F #66 — sym-diff with empty = self.
    func test_symdiff_withEmptyEqualsSelf() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.italic, start: 10, end: 15)
        let r2 = Rangeable<AnyMarkup>()
        let r3 = r1.symmetricDifference(r2)
        XCTAssertEqual(keysInOrder(r3), [.strong, .italic])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r3), [iv(10, 15)])
        XCTAssertEqual(r3.version, 0)
    }

    /// §10.F #67 — sym-diff with self = empty.
    func test_symdiff_withSelfEmpty() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        try r1.insert(.italic, start: 10, end: 15)
        let r2 = r1.symmetricDifference(r1)
        XCTAssertTrue(r2.isEmpty)
        XCTAssertEqual(r2.count, 0)
    }

    /// §10.F #68 — per-element residuals from both sides.
    func test_symdiff_perElementResiduals() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 5, end: 15)
        let r3 = r1.symmetricDifference(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 4), iv(11, 15)])
    }

    /// §10.F #68 (truly-adjacent variant) — RFC §6.13 worked example:
    /// `[(0,5)] △ [(6,10)] = [(0,10)]` because residuals are adjacent.
    func test_symdiff_adjacentResidualsCollapse() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 6, end: 10)
        let r3 = r1.symmetricDifference(r2)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r3), [iv(0, 10)])
    }

    /// §10.F #69 — commutativity modulo insertion_order.
    func test_symdiff_commutativeModuloOrder() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("a"), start: 0, end: 5)
        try r1.insert(.link("b"), start: 10, end: 15)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("b"), start: 12, end: 17)
        try r2.insert(.link("c"), start: 20, end: 25)
        let r3 = r1.symmetricDifference(r2)
        let r4 = r2.symmetricDifference(r1)
        // Per-element R(e) is identical.
        for key in [AnyMarkup.link("a"), .link("b"), .link("c")] {
            XCTAssertEqual(key.getRange(from: r3), key.getRange(from: r4),
                           "per-element symdiff should commute on \(key)")
        }
        XCTAssertEqual(AnyMarkup.link("a").getRange(from: r3), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.link("b").getRange(from: r3), [iv(10, 11), iv(16, 17)])
        XCTAssertEqual(AnyMarkup.link("c").getRange(from: r3), [iv(20, 25)])
        // Insertion order is self-primary.
        XCTAssertEqual(keysInOrder(r3), [.link("a"), .link("b"), .link("c")])
        XCTAssertEqual(keysInOrder(r4), [.link("b"), .link("c"), .link("a")])
    }

    /// §10.F #70 — associativity. Worked spec example yields R(A) = [(0,4),
    /// (10,10), (16,20)].
    func test_symdiff_associativity() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 10)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("A"), start: 5, end: 15)
        var r3 = Rangeable<AnyMarkup>()
        try r3.insert(.link("A"), start: 10, end: 20)

        let left = r1.symmetricDifference(r2).symmetricDifference(r3)
        let right = r1.symmetricDifference(r2.symmetricDifference(r3))
        let expected = [iv(0, 4), iv(10, 10), iv(16, 20)]
        XCTAssertEqual(AnyMarkup.link("A").getRange(from: left), expected)
        XCTAssertEqual(AnyMarkup.link("A").getRange(from: right), expected)
        XCTAssertEqual(keysInOrder(left), [.link("A")])
        XCTAssertEqual(keysInOrder(right), [.link("A")])
    }

    /// §10.F #71 — insertion_order tail-append for keys ∈ other ∖ self.
    func test_symdiff_insertionOrderTailAppend() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 5)
        try r1.insert(.link("B"), start: 10, end: 15)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("C"), start: 20, end: 25)
        try r2.insert(.link("D"), start: 30, end: 35)
        let r3 = r1.symmetricDifference(r2)
        XCTAssertEqual(keysInOrder(r3), [.link("A"), .link("B"), .link("C"), .link("D")])
    }

    /// formSymmetricDifference mutating bump rule + self-clear behaviour.
    func test_formSymmetricDifference_selfClearsAndBumps() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        let v0 = r1.version
        r1.formSymmetricDifference(r1)
        XCTAssertTrue(r1.isEmpty)
        XCTAssertEqual(r1.version, v0 + 1)
    }

    // ============================================================
    // §10.G — Set-op insertion-order stress, tests #72–#80
    // ============================================================

    /// §10.G #72 — Dense ord renumber after multi-element prune.
    func test_setOps_intersectMultiElementPrune() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 1)
        try r1.insert(.link("B"), start: 2, end: 3)
        try r1.insert(.link("C"), start: 4, end: 5)
        try r1.insert(.link("D"), start: 6, end: 7)
        try r1.insert(.link("E"), start: 8, end: 9)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("B"), start: 100, end: 200)
        try r2.insert(.link("D"), start: 100, end: 200)
        let r3 = r1.intersection(r2)
        XCTAssertTrue(r3.isEmpty)
        XCTAssertEqual(r3.count, 0)
    }

    /// §10.G #73 — union then intersect chain preserves insertion order.
    func test_setOps_unionThenIntersect() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 5)
        try r1.insert(.link("B"), start: 10, end: 15)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("C"), start: 20, end: 25)
        try r2.insert(.link("B"), start: 12, end: 17)
        var r3 = Rangeable<AnyMarkup>()
        try r3.insert(.link("B"), start: 0, end: 100)
        try r3.insert(.link("C"), start: 0, end: 100)

        let chain = r1.union(r2).intersection(r3)
        XCTAssertEqual(keysInOrder(chain), [.link("B"), .link("C")])
    }

    /// §10.G #74 — set-op result ord is correct even if input had pruned
    /// elements.
    func test_setOps_priorPrunesRespected() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 5)
        try r1.insert(.link("B"), start: 10, end: 15)
        try r1.insert(.link("C"), start: 20, end: 25)
        r1.remove(.link("B"))
        // r1 insertion_order is now [A, C]
        let empty = Rangeable<AnyMarkup>()
        let r2 = r1.union(empty)
        XCTAssertEqual(keysInOrder(r2), [.link("A"), .link("C")])
    }

    /// §10.G #75 — difference then union recovers insertion order.
    func test_setOps_differenceThenUnionRecoversOrder() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 10)
        try r1.insert(.link("B"), start: 20, end: 30)
        try r1.insert(.link("C"), start: 40, end: 50)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("B"), start: 0, end: 100)   // fully consumes B from r1
        let r3 = r1.subtracting(r2).union(r1)
        XCTAssertEqual(keysInOrder(r3), [.link("A"), .link("C"), .link("B")])
    }

    /// §10.G #76 — union of three with overlapping keys.
    func test_setOps_unionOfThree() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 5)
        try r1.insert(.link("B"), start: 10, end: 15)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("B"), start: 20, end: 25)
        try r2.insert(.link("C"), start: 30, end: 35)
        var r3 = Rangeable<AnyMarkup>()
        try r3.insert(.link("C"), start: 40, end: 45)
        try r3.insert(.link("D"), start: 50, end: 55)

        let chain = r1.union(r2).union(r3)
        XCTAssertEqual(keysInOrder(chain), [.link("A"), .link("B"), .link("C"), .link("D")])
        XCTAssertEqual(AnyMarkup.link("A").getRange(from: chain), [iv(0, 5)])
        XCTAssertEqual(AnyMarkup.link("B").getRange(from: chain), [iv(10, 15), iv(20, 25)])
        XCTAssertEqual(AnyMarkup.link("C").getRange(from: chain), [iv(30, 35), iv(40, 45)])
        XCTAssertEqual(AnyMarkup.link("D").getRange(from: chain), [iv(50, 55)])
    }

    /// §10.G #77 — symmetric_difference two algebraic forms produce
    /// identical per-element R(e).
    func test_setOps_symdiffTwoForms() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 10)
        try r1.insert(.link("B"), start: 20, end: 30)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("A"), start: 5, end: 15)
        try r2.insert(.link("C"), start: 40, end: 50)

        let form1 = r1.symmetricDifference(r2)
        let form2 = r1.union(r2).subtracting(r1.intersection(r2))
        for key in [AnyMarkup.link("A"), .link("B"), .link("C")] {
            XCTAssertEqual(key.getRange(from: form1), key.getRange(from: form2),
                           "per-element should match on \(key)")
        }
    }

    /// §10.G #78 — insert-after-remove ord reassignment (R14).
    func test_setOps_insertAfterRemoveReassignsOrd() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.link("A"), start: 0, end: 5)
        try r.insert(.link("B"), start: 10, end: 15)
        r.remove(.link("A"))
        // r.insertion_order = [B]
        try r.insert(.link("A"), start: 100, end: 110)
        XCTAssertEqual(keysInOrder(r), [.link("B"), .link("A")])
    }

    /// §10.G #79 — cross-op ord consistency (intersect after union).
    func test_setOps_crossOpOrdConsistency() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 5)
        try r1.insert(.link("B"), start: 10, end: 15)
        try r1.insert(.link("C"), start: 20, end: 25)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("B"), start: 12, end: 17)
        try r2.insert(.link("D"), start: 30, end: 35)
        let unionR = r1.union(r2)
        XCTAssertEqual(keysInOrder(unionR), [.link("A"), .link("B"), .link("C"), .link("D")])

        var r3 = Rangeable<AnyMarkup>()
        try r3.insert(.link("B"), start: 0, end: 100)
        try r3.insert(.link("D"), start: 0, end: 100)
        try r3.insert(.link("A"), start: 0, end: 100)
        let intersected = unionR.intersection(r3)
        XCTAssertEqual(keysInOrder(intersected), [.link("A"), .link("B"), .link("D")])
    }

    /// §10.G #80 — empty result eager prune across set-op chain.
    func test_setOps_emptyResultPruneAcrossChain() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.link("A"), start: 0, end: 5)
        try r1.insert(.link("B"), start: 10, end: 15)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.link("A"), start: 100, end: 200)
        try r2.insert(.link("B"), start: 100, end: 200)
        let r3 = r1.intersection(r2)
        XCTAssertTrue(r3.isEmpty)
        let r4 = r3.union(r1)
        XCTAssertEqual(keysInOrder(r4), [.link("A"), .link("B")])
    }

    // ============================================================
    // Cross-cutting probes (COW, version invariants, mixed flows)
    // ============================================================

    /// COW: formUnion on a snapshot must not mutate prior copies.
    func test_cow_formUnionDoesNotAffectSnapshot() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        let snapshot = r1.copy()
        var other = Rangeable<AnyMarkup>()
        try other.insert(.italic, start: 10, end: 15)
        r1.formUnion(other)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(keysInOrder(snapshot), [.strong])
        XCTAssertEqual(snapshot[0].objs, [.strong])
        XCTAssertEqual(r1.count, 2)
    }

    /// COW: removeRanges via implicit COW from value assignment.
    func test_cow_removeRangesViaImplicitAssignment() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 10)
        var r2 = r1   // value-type assignment shares storage
        try r2.removeRanges(start: 3, end: 6)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r1), [iv(0, 10)])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r2), [iv(0, 2), iv(7, 10)])
    }

    /// Idempotence end-to-end: a sequence of operations all composed of
    /// no-ops never bumps version.
    func test_idempotence_chainOfNoOpsDoesNotBump() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        let v0 = r.version
        try r.remove(.strong, start: 100, end: 200)
        try r.removeRanges(start: 50, end: 60)
        r.remove(.italic)
        r.removeAll()
        // removeAll on non-empty bumps; reset and check no-op chain only.
        var r2 = Rangeable<AnyMarkup>()
        let v0_2 = r2.version
        r2.removeAll()
        try r2.removeRanges(start: 0, end: 10)
        r2.remove(.strong)
        XCTAssertEqual(r2.version, v0_2)
        // The first chain should bump exactly once for the .removeAll
        // (the rest are no-ops).
        XCTAssertEqual(r.version, v0 + 1)
    }

    /// Event-index invalidation: after a real removal, queries reflect
    /// the new state.
    func test_eventIndex_invalidationAfterRemoval() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 0, end: 10)
        XCTAssertEqual(r[5].objs, [.strong])  // forces lazy build
        try r.remove(.strong, start: 3, end: 7)
        XCTAssertEqual(r[5].objs, [])
        XCTAssertEqual(r[2].objs, [.strong])
        XCTAssertEqual(r[8].objs, [.strong])
    }

    /// formUnion of structurally equal but distinct storages MUST NOT
    /// bump version.
    func test_formUnion_structurallyEqualDoesNotBump() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 0, end: 5)
        let v0 = r1.version
        r1.formUnion(r2)
        XCTAssertEqual(r1.version, v0)
    }

    /// formIntersection of structurally equal MUST NOT bump.
    func test_formIntersection_structurallyEqualDoesNotBump() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 0, end: 5)
        var r2 = Rangeable<AnyMarkup>()
        try r2.insert(.strong, start: 0, end: 5)
        let v0 = r1.version
        r1.formIntersection(r2)
        XCTAssertEqual(r1.version, v0)
    }
}
