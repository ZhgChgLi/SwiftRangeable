import XCTest
@testable import Rangeable

/// Mirrors the 23 normative test-contract items from RFC.md §10. Each test
/// name embeds the RFC number and aligns 1:1 with
/// `RubyRangeable/test/rangeable_test.rb`.
final class RangeableContractTests: XCTestCase {

    var r: Rangeable<AnyMarkup> = Rangeable()

    override func setUp() {
        super.setUp()
        r = Rangeable<AnyMarkup>()
    }

    private func iv(_ lo: Int, _ hi: Int) -> Interval {
        return Interval(lo: lo, hi: hi)
    }

    // MARK: - Test #1 — Empty

    func test01Empty() {
        XCTAssertEqual(r[0].objs, [])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [])
        XCTAssertEqual(r.count, 0)
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - Test #2 — Single insert

    func test02SingleInsert() throws {
        try r.insert(.strong, start: 2, end: 5)
        XCTAssertEqual(r[2].objs, [.strong])
        XCTAssertEqual(r[5].objs, [.strong])
        XCTAssertEqual(r[6].objs, [])
        XCTAssertEqual(r[1].objs, [])
    }

    // MARK: - Test #3 — Inclusive end

    func test03InclusiveEnd() throws {
        try r.insert(.strong, start: 3, end: 8)
        XCTAssertEqual(r[8].objs, [.strong])
        XCTAssertEqual(r[9].objs, [])
    }

    // MARK: - Test #4 — Single-point

    func test04SinglePoint() throws {
        try r.insert(.strong, start: 4, end: 4)
        XCTAssertEqual(r[3].objs, [])
        XCTAssertEqual(r[4].objs, [.strong])
        XCTAssertEqual(r[5].objs, [])
    }

    // MARK: - Test #5 — Same-element overlap merge

    func test05SameElementOverlapMerge() throws {
        try r.insert(.strong, start: 2, end: 5)
        try r.insert(.strong, start: 3, end: 7)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 7)])
    }

    // MARK: - Test #6 — Same-element adjacency merge

    func test06SameElementAdjacencyMerge() throws {
        try r.insert(.strong, start: 2, end: 4)
        try r.insert(.strong, start: 5, end: 7)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 7)])
    }

    // MARK: - Test #7 — Same-element non-adjacent disjoint

    func test07SameElementNonAdjacentDisjoint() throws {
        try r.insert(.strong, start: 2, end: 4)
        try r.insert(.strong, start: 6, end: 7)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 4), iv(6, 7)])
    }

    // MARK: - Test #8 — Same-element nested

    func test08SameElementNested() throws {
        try r.insert(.strong, start: 2, end: 10)
        try r.insert(.strong, start: 4, end: 6)
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 10)])
    }

    // MARK: - Test #9 — Idempotent insert

    func test09IdempotentInsert() throws {
        try r.insert(.strong, start: 2, end: 5)
        let v1 = r.version
        try r.insert(.strong, start: 2, end: 5)
        let v2 = r.version
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 5)])
        XCTAssertEqual(v1, v2, "idempotent insert MUST NOT bump version")
    }

    // MARK: - Test #10 — Different elements coexist

    func test10DifferentElementsCoexist() throws {
        try r.insert(.strong, start: 2, end: 5)
        try r.insert(.italic, start: 3, end: 7)
        XCTAssertEqual(r[3].objs, [.strong, .italic])
        XCTAssertEqual(r[6].objs, [.italic])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 5)])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r), [iv(3, 7)])
    }

    // MARK: - Test #11 — Equal-by-equality elements merge

    func test11EqualByEqualityElementsMerge() throws {
        try r.insert(.link("a"), start: 2, end: 5)
        try r.insert(.link("a"), start: 4, end: 8)
        try r.insert(.link("b"), start: 6, end: 9)
        XCTAssertEqual(AnyMarkup.link("a").getRange(from: r), [iv(2, 8)])
        XCTAssertEqual(AnyMarkup.link("b").getRange(from: r), [iv(6, 9)])
    }

    // MARK: - Test #12 — First-insert order at point

    func test12FirstInsertOrderAtPoint() throws {
        try r.insert(.strong, start: 1, end: 10)
        try r.insert(.italic, start: 1, end: 10)
        try r.insert(.code, start: 1, end: 10)
        XCTAssertEqual(r[5].objs, [.strong, .italic, .code])
    }

    // MARK: - Test #13 — Order preserved through merge

    func test13OrderPreservedThroughMerge() throws {
        try r.insert(.strong, start: 1, end: 5)
        try r.insert(.italic, start: 3, end: 7)
        try r.insert(.strong, start: 4, end: 8)
        XCTAssertEqual(r[6].objs, [.strong, .italic])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(1, 8)])
    }

    // MARK: - Test #14 — Transitions over a range

    func test14TransitionsOverARange() throws {
        try r.insert(.strong, start: 2, end: 5)
        try r.insert(.italic, start: 3, end: 7)
        let events = try r.transitions(over: 0...10).map { ($0.coordinate, $0.kind, $0.element) }
        let expected: [(Int?, TransitionKind, AnyMarkup)] = [
            (2, .open, .strong),
            (3, .open, .italic),
            (6, .close, .strong),
            (8, .close, .italic),
        ]
        assertSameEvents(events, expected)
    }

    // MARK: - Test #15 — Transitions same-start

    func test15TransitionsSameStart() throws {
        try r.insert(.strong, start: 3, end: 5)
        try r.insert(.italic, start: 3, end: 7)
        let events = try r.transitions(over: 0...10).map { ($0.coordinate, $0.kind, $0.element) }
        let expected: [(Int?, TransitionKind, AnyMarkup)] = [
            (3, .open, .strong),
            (3, .open, .italic),
            (6, .close, .strong),
            (8, .close, .italic),
        ]
        assertSameEvents(events, expected)
    }

    // MARK: - Test #16 — Transitions same-end (LIFO)

    func test16TransitionsSameEndLifo() throws {
        try r.insert(.strong, start: 3, end: 5)
        try r.insert(.italic, start: 3, end: 5)
        let events = try r.transitions(over: 0...10).map { ($0.coordinate, $0.kind, $0.element) }
        let expected: [(Int?, TransitionKind, AnyMarkup)] = [
            (3, .open, .strong),
            (3, .open, .italic),
            (6, .close, .italic),
            (6, .close, .strong),
        ]
        assertSameEvents(events, expected)
    }

    // MARK: - Test #17 — start > end raises

    func test17StartGtEndRaises() {
        XCTAssertThrowsError(try r.insert(.strong, start: 5, end: 2)) { err in
            guard case RangeableError.invalidInterval(let s, let e) = err else {
                XCTFail("expected RangeableError.invalidInterval")
                return
            }
            XCTAssertEqual(s, 5)
            XCTAssertEqual(e, 2)
        }
        XCTAssertTrue(r.isEmpty, "failed insert MUST leave container unchanged")
        XCTAssertEqual(r.version, 0)
    }

    // MARK: - Test #18 — Negative start

    func test18NegativeStart() throws {
        try r.insert(.strong, start: -2, end: 3)
        XCTAssertEqual(r[-1].objs, [.strong])
        XCTAssertEqual(r[0].objs, [.strong])
        XCTAssertEqual(r[3].objs, [.strong])
        XCTAssertEqual(r[4].objs, [])
    }

    // MARK: - Test #19 — Insert/read interleave (rebuild correctness)

    func test19InsertReadInterleaveRebuild() throws {
        try r.insert(.strong, start: 1, end: 3)
        let read1 = r[2].objs
        try r.insert(.strong, start: 5, end: 7)
        let read2 = r[6].objs
        XCTAssertEqual(read1, [.strong])
        XCTAssertEqual(read2, [.strong])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(1, 3), iv(5, 7)])
    }

    // MARK: - Test #20 — Property test (small smoke; full property test in PropertyTests)

    func test20PropertySmokeAgainstBruteForce() throws {
        var rng = SeedableRNG(seed: 42)
        let elements: [AnyMarkup] = [.strong, .italic, .code, .link("x"), .link("y")]
        var triples: [(AnyMarkup, Int, Int)] = []
        for _ in 0..<50 {
            let lo = rng.intInRange(-50, through: 50)
            let span = rng.intInRange(0, through: 20)
            let hi = lo + span
            let element = elements[rng.intInRange(0, through: elements.count - 1)]
            triples.append((element, lo, hi))
        }
        for (e, lo, hi) in triples {
            try r.insert(e, start: lo, end: hi)
        }
        for i in -60...60 {
            let expected = bruteForceActive(triples: triples, at: i)
            XCTAssertEqual(r[i].objs, expected, "mismatch at i=\(i)")
        }
    }

    // MARK: - Test #21 — Idempotent insert does NOT bump version

    func test21IdempotentInsertNoVersionBump() throws {
        try r.insert(.strong, start: 2, end: 5)
        let v1 = r.version
        try r.insert(.strong, start: 2, end: 5)
        let v2 = r.version
        XCTAssertEqual(v1, v2)
    }

    // MARK: - Test #21.A — Idempotent insert with strict containment

    func test21AIdempotentInsertStrictContainment() throws {
        try r.insert(.strong, start: 2, end: 10)
        let v1 = r.version
        try r.insert(.strong, start: 4, end: 6)
        let v2 = r.version
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(2, 10)])
        XCTAssertEqual(v1, v2, "strict-containment fast-path MUST NOT bump version")
    }

    // MARK: - Test #22 — transitions with lo > hi raises

    func test22TransitionsLoGtHiRaises() throws {
        try r.insert(.strong, start: 2, end: 5)
        // Swift's `ClosedRange<Int>` traps when `lo > hi`, so passing a
        // reversed `ClosedRange` to transitions is not possible. Use the
        // `transitions(lo:hi:)` overload to verify the RFC §10 Test #22
        // invariant explicitly: `lo > hi` MUST raise InvalidIntervalError.
        XCTAssertThrowsError(try r.transitions(lo: 5, hi: 2)) { err in
            guard case RangeableError.invalidInterval(let s, let e) = err else {
                XCTFail("expected invalidInterval, got \(err)")
                return
            }
            XCTAssertEqual(s, 5)
            XCTAssertEqual(e, 2)
        }
    }

    // MARK: - Test #23 — Int.min as lo of insert

    func test23IntMinAsLo() throws {
        // Swift's Int.min is the actual Int.min; the Ruby reference uses
        // `-(2**62)` (Ruby's 64-bit Fixnum range), which on Swift maps to
        // Int.min for an even tighter boundary test.
        let intMin = Int.min
        try r.insert(.strong, start: intMin, end: intMin + 5)
        XCTAssertEqual(r[intMin].objs, [.strong])
        XCTAssertEqual(r[intMin + 5].objs, [.strong])
        XCTAssertEqual(r[intMin + 6].objs, [])
        XCTAssertEqual(AnyMarkup.strong.getRange(from: r), [iv(intMin, intMin + 5)])
    }

    // MARK: - Test #23.A — Int.max as hi of insert

    func test23AIntMaxAsHi() throws {
        let intMax = Int.max
        try r.insert(.strong, start: 100, end: intMax)
        let events = try r.transitions(over: 50...intMax).map { ($0.coordinate, $0.kind) }
        // Expected: (100, open), (nil, close). Per RFC §4.7 (C4):
        // hi == Int.max ⇒ close coord = nil.
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].0, 100)
        XCTAssertEqual(events[0].1, .open)
        XCTAssertNil(events[1].0)
        XCTAssertEqual(events[1].1, .close)
    }

    // MARK: - Helpers

    /// Brute-force oracle: collects elements in first-seen order and keeps
    /// only those with at least one interval covering `i`. Mirrors Ruby's
    /// `brute_force_active`.
    private func bruteForceActive(triples: [(AnyMarkup, Int, Int)], at i: Int) -> [AnyMarkup] {
        var seen = Set<AnyMarkup>()
        var insertionOrder: [AnyMarkup] = []
        for (e, _, _) in triples {
            if !seen.contains(e) {
                seen.insert(e)
                insertionOrder.append(e)
            }
        }
        var byElement: [AnyMarkup: [(Int, Int)]] = [:]
        for (e, lo, hi) in triples {
            byElement[e, default: []].append((lo, hi))
        }
        return insertionOrder.filter { e in
            (byElement[e] ?? []).contains { (lo, hi) in lo <= i && i <= hi }
        }
    }

    private func assertSameEvents(
        _ actual: [(Int?, TransitionKind, AnyMarkup)],
        _ expected: [(Int?, TransitionKind, AnyMarkup)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "event count mismatch", file: file, line: line)
        for (i, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a.0, e.0, "event[\(i)].coordinate", file: file, line: line)
            XCTAssertEqual(a.1, e.1, "event[\(i)].kind", file: file, line: line)
            XCTAssertEqual(a.2, e.2, "event[\(i)].element", file: file, line: line)
        }
    }
}
