import XCTest
@testable import Rangeable

/// Supplementary informative tests (RFC §10 #24–#27) plus Swift-specific
/// value-type / COW behavior checks. Test #28 (mutable element
/// frozen-on-insert) applies only to Ruby; Swift passes it trivially via
/// value semantics, so no explicit case is needed.
final class AdditionalTests: XCTestCase {

    // MARK: - Test #24 — repeated reads return equal sequence

    func test24RepeatedReadsReturnSameSequence() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 2, end: 5)
        try r.insert(.italic, start: 3, end: 7)
        let a = r[3].objs
        let b = r[3].objs
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, [.strong, .italic])
    }

    // MARK: - Test #25 — lazy build invariant under no-op repeated query

    func test25LazyBuildInvariantUnderRepeatedQuery() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 1, end: 5)
        let v1 = r.version
        _ = r[2].objs
        XCTAssertEqual(r.version, v1)
        _ = r[2].objs
        XCTAssertEqual(r.version, v1)
    }

    // MARK: - Test #26 — cross-element merge keeps insertion order

    func test26CrossElementMergeDoesNotPolluteOrder() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 1, end: 3)
        try r.insert(.italic, start: 2, end: 4)
        try r.insert(.strong, start: 3, end: 5)
        XCTAssertEqual(r[2].objs, [.strong, .italic])
    }

    // MARK: - Test #27 — transitions outside any interval

    func test27EmptyTransitionsOutsideAnyInterval() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 10, end: 20)
        let events = try r.transitions(over: 0...5)
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - COW: copy-on-write isolation

    func testValueSemanticsCopyOnWrite() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 1, end: 5)
        var r2 = r1
        try r2.insert(.italic, start: 2, end: 4)
        // r1 must not be affected by r2's insert.
        XCTAssertEqual(r1.count, 1)
        XCTAssertEqual(r1[3].objs, [.strong])
        XCTAssertEqual(r2.count, 2)
        XCTAssertEqual(r2[3].objs, [.strong, .italic])
    }

    func testExplicitCopyDeepClones() throws {
        var r1 = Rangeable<AnyMarkup>()
        try r1.insert(.strong, start: 1, end: 5)
        var r2 = r1.copy()
        try r2.insert(.italic, start: 2, end: 4)
        XCTAssertEqual(r1.count, 1)
        XCTAssertEqual(r2.count, 2)
    }

    // MARK: - Sequence iteration in insertion order

    func testIterationFollowsInsertionOrder() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.italic, start: 1, end: 5)
        try r.insert(.strong, start: 2, end: 6)
        try r.insert(.code, start: 3, end: 7)
        let elements = r.map { $0.0 }
        XCTAssertEqual(elements, [.italic, .strong, .code])
    }

    // MARK: - getRange of element never inserted returns []

    func testGetRangeUnknownElementReturnsEmpty() throws {
        var r = Rangeable<AnyMarkup>()
        try r.insert(.strong, start: 1, end: 5)
        XCTAssertEqual(r.getRange(of: .italic), [])
        XCTAssertEqual(AnyMarkup.italic.getRange(from: r), [])
    }

    // MARK: - empty() static factory

    func testEmptyStaticFactory() {
        let r = Rangeable<AnyMarkup>.empty()
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Single-element type Strong fixture also works

    func testSingleElementTypeStrongFixture() throws {
        var r = Rangeable<Strong>()
        try r.insert(Strong(), start: 2, end: 5)
        XCTAssertEqual(r[3].objs, [Strong()])
        XCTAssertEqual(Strong().getRange(from: r), [Interval(lo: 2, hi: 5)])
    }
}
