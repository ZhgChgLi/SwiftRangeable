import XCTest
@testable import Rangeable

/// Mirrors Ruby's `test/property_test.rb`: with a fixed seed, generate
/// 1000 random inserts, then sweep every coordinate and check against a
/// brute-force oracle.
final class PropertyTests: XCTestCase {

    private let coordBound = 200

    func testRandomInsertsMatchBruteForce() throws {
        var rng = SeedableRNG(seed: 0x2026_0509)
        let elements: [AnyMarkup] = [.strong, .italic, .code, .link("x"), .link("y")]
        var triples: [(AnyMarkup, Int, Int)] = []
        for _ in 0..<1000 {
            let lo = rng.intInRange(-coordBound, through: coordBound)
            let span = rng.intInRange(0, through: 40)
            let hi = lo + span
            let e = elements[rng.intInRange(0, through: elements.count - 1)]
            triples.append((e, lo, hi))
        }

        var r = Rangeable<AnyMarkup>()
        for (e, lo, hi) in triples {
            try r.insert(e, start: lo, end: hi)
        }

        let (firstSeenOrder, intervalsByElement) = buildOracleData(triples: triples)

        var failures: [(Int, [AnyMarkup], [AnyMarkup])] = []
        for i in -(coordBound + 5)...(coordBound + 5) {
            let expected = bruteForce(at: i, order: firstSeenOrder, intervalsByElement: intervalsByElement)
            let actual = r[i].objs
            if actual != expected {
                failures.append((i, expected, actual))
            }
        }

        XCTAssertTrue(failures.isEmpty, sampleFailures(failures))
    }

    func testRandomGetRangeMatchesBruteForce() throws {
        var rng = SeedableRNG(seed: 0x2026_0510)
        let elements: [AnyMarkup] = [.strong, .italic, .code, .link("p"), .link("q")]
        var triples: [(AnyMarkup, Int, Int)] = []
        for _ in 0..<500 {
            let lo = rng.intInRange(-100, through: 100)
            let span = rng.intInRange(0, through: 15)
            let hi = lo + span
            let e = elements[rng.intInRange(0, through: elements.count - 1)]
            triples.append((e, lo, hi))
        }

        var r = Rangeable<AnyMarkup>()
        for (e, lo, hi) in triples {
            try r.insert(e, start: lo, end: hi)
        }

        let (_, intervalsByElement) = buildOracleData(triples: triples)
        for e in elements {
            guard let pairs = intervalsByElement[e] else { continue }
            let expected = canonicalize(pairs)
            let actual = r.getRange(of: e).map { ($0.lo, $0.hi) }
            XCTAssertTrue(samePairs(actual, expected), "get_range mismatch for \(e)")
        }
    }

    // MARK: - Oracle helpers

    private func buildOracleData(
        triples: [(AnyMarkup, Int, Int)]
    ) -> (order: [AnyMarkup], byElement: [AnyMarkup: [(Int, Int)]]) {
        var seen = Set<AnyMarkup>()
        var order: [AnyMarkup] = []
        var byElement: [AnyMarkup: [(Int, Int)]] = [:]
        for (e, lo, hi) in triples {
            if !seen.contains(e) {
                seen.insert(e)
                order.append(e)
            }
            byElement[e, default: []].append((lo, hi))
        }
        return (order, byElement)
    }

    private func bruteForce(
        at i: Int,
        order: [AnyMarkup],
        intervalsByElement: [AnyMarkup: [(Int, Int)]]
    ) -> [AnyMarkup] {
        return order.filter { e in
            (intervalsByElement[e] ?? []).contains { (lo, hi) in lo <= i && i <= hi }
        }
    }

    /// I1-canonical form: sort by `lo` and merge adjacent intervals.
    private func canonicalize(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        let sorted = pairs.sorted { $0.0 < $1.0 }
        var out: [(Int, Int)] = []
        for (lo, hi) in sorted {
            if let last = out.last, last.1 + 1 >= lo {
                if hi > last.1 {
                    out[out.count - 1] = (last.0, hi)
                }
            } else {
                out.append((lo, hi))
            }
        }
        return out
    }

    private func samePairs(_ a: [(Int, Int)], _ b: [(Int, Int)]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.0 != y.0 || x.1 != y.1 {
            return false
        }
        return true
    }

    private func sampleFailures(_ failures: [(Int, [AnyMarkup], [AnyMarkup])]) -> String {
        guard !failures.isEmpty else { return "" }
        let head = failures.prefix(5).map { i, expected, actual in
            "i=\(i) expected=\(expected) actual=\(actual)"
        }
        return "first failures (\(failures.count) total):\n\(head.joined(separator: "\n"))"
    }
}
