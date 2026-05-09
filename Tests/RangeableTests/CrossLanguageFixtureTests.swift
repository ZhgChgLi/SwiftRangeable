import XCTest
@testable import Rangeable

/// Cross-language consistency check: consumes the `cross_language.json`
/// produced by Ruby's `test/cross_language_fixture.rb`, replays the ops,
/// and compares against the expected outputs recorded on the Ruby side.
///
/// This test mirrors the byte-identical variant of RFC §10 Test #20: with
/// the same fixture, verify that both language implementations produce
/// identical active sets and transition sequences.
final class CrossLanguageFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        let seed: Int
        let ops: [Op]
        let probes: [Probe]
    }

    private struct Op: Decodable {
        let element: Int
        let start: Int
        let end: Int
    }

    private struct Probe: Decodable {
        let kind: String
        let i: Int?
        let lo: Int?
        let hi: Int?
        let expected: ExpectedPayload

        private enum CodingKeys: String, CodingKey {
            case kind, i, lo, hi, expected
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try container.decode(String.self, forKey: .kind)
            self.i = try container.decodeIfPresent(Int.self, forKey: .i)
            self.lo = try container.decodeIfPresent(Int.self, forKey: .lo)
            self.hi = try container.decodeIfPresent(Int.self, forKey: .hi)
            // Dispatch by kind so empty arrays don't accidentally decode as
            // the wrong variant.
            switch self.kind {
            case "subscript":
                let strings = try container.decode([String].self, forKey: .expected)
                self.expected = .subscript_(strings: strings)
            case "transitions":
                let events = try container.decode([ExpectedEvent].self, forKey: .expected)
                self.expected = .transitions(events: events)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "unknown probe kind \(self.kind)"
                )
            }
        }
    }

    private enum ExpectedPayload {
        case subscript_(strings: [String])
        case transitions(events: [ExpectedEvent])
    }

    private struct ExpectedEvent: Decodable {
        let coordinate: Int?
        let kind: String
        let element: String
    }

    func testRubySwiftCrossLanguageFixture() throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "cross_language", withExtension: "json") else {
            XCTFail("cross_language.json fixture missing from test bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)

        let elementSpecs: [AnyMarkup] = [
            .strong,
            .italic,
            .code,
            .link("a"),
            .link("b")
        ]

        var r = Rangeable<AnyMarkup>()
        for op in fixture.ops {
            try r.insert(elementSpecs[op.element], start: op.start, end: op.end)
        }

        for probe in fixture.probes {
            switch probe.kind {
            case "subscript":
                guard let i = probe.i else {
                    XCTFail("subscript probe missing i")
                    continue
                }
                guard case .subscript_(let expectedKeys) = probe.expected else {
                    XCTFail("subscript probe expected wrong shape")
                    continue
                }
                let actualKeys = r[i].objs.map { canonicalKey(for: $0) }
                XCTAssertEqual(actualKeys, expectedKeys, "subscript mismatch at i=\(i)")

            case "transitions":
                guard let lo = probe.lo, let hi = probe.hi else {
                    XCTFail("transitions probe missing lo/hi")
                    continue
                }
                guard case .transitions(let expected) = probe.expected else {
                    XCTFail("transitions probe expected wrong shape")
                    continue
                }
                let events = try r.transitions(lo: lo, hi: hi)
                XCTAssertEqual(events.count, expected.count, "transitions count mismatch at lo=\(lo) hi=\(hi)")
                for (idx, (a, e)) in zip(events, expected).enumerated() {
                    XCTAssertEqual(a.coordinate, e.coordinate, "transitions[\(idx)] coord mismatch")
                    XCTAssertEqual(kindString(a.kind), e.kind, "transitions[\(idx)] kind mismatch")
                    XCTAssertEqual(canonicalKey(for: a.element), e.element, "transitions[\(idx)] element mismatch")
                }

            default:
                XCTFail("unknown probe kind \(probe.kind)")
            }
        }
    }

    private func canonicalKey(for element: AnyMarkup) -> String {
        switch element {
        case .strong: return "strong"
        case .italic: return "italic"
        case .code: return "code"
        case .link(let url): return "link:\(url)"
        }
    }

    private func kindString(_ kind: TransitionKind) -> String {
        switch kind {
        case .open: return "open"
        case .close: return "close"
        }
    }
}
