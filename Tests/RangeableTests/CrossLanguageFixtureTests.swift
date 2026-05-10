import XCTest
@testable import Rangeable

/// Cross-language consistency check: consumes the `cross_language.json`
/// produced by Ruby's `test/cross_language_fixture.rb`, replays the ops,
/// and compares against the expected outputs recorded on the Ruby side.
///
/// This test mirrors the byte-identical variant of RFC §10 Test #20: with
/// the same fixture, verify that both language implementations produce
/// identical active sets and transition sequences.
///
/// Schema versions handled:
///   - v1 — no `schema_version`, only `ops` (all `insert`) + `probes`.
///   - v2 — `schema_version: 2`, `ops` may also include
///     `remove` / `remove_element` / `clear` / `remove_ranges`,
///     plus a `set_ops` array. Probes carry an optional `phase`
///     (`v1` / `after_removes` / `final`) selecting which intermediate
///     snapshot they were computed against (see Ruby v2 generator).
final class CrossLanguageFixtureTests: XCTestCase {

    // MARK: - Decodable schema

    private struct Fixture: Decodable {
        let schemaVersion: Int?
        let seed: Int
        let ops: [Op]
        let setOps: [SetOpEntry]?
        let probes: [Probe]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case seed
            case ops
            case setOps = "set_ops"
            case probes
        }
    }

    /// One operation in the `ops` array. v1 fixtures omit `op` entirely
    /// (defaulted to `.insert` here). v2 may carry any of the five op kinds;
    /// `start` / `end` / `element` are present only for the kinds that
    /// require them.
    private struct Op: Decodable {
        let op: OpType
        let element: Int?
        let start: Int?
        let end: Int?

        private enum CodingKeys: String, CodingKey {
            case op, element, start, end
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // v1 backward-compat: missing `op` ⇒ insert.
            if let raw = try container.decodeIfPresent(String.self, forKey: .op) {
                guard let parsed = OpType(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .op, in: container,
                        debugDescription: "unknown op kind \(raw)"
                    )
                }
                self.op = parsed
            } else {
                self.op = .insert
            }
            self.element = try container.decodeIfPresent(Int.self, forKey: .element)
            self.start = try container.decodeIfPresent(Int.self, forKey: .start)
            self.end = try container.decodeIfPresent(Int.self, forKey: .end)
        }
    }

    /// One set-op scenario. `selfOps`/`otherOps`/optional `chainOps` are
    /// always insert-only sequences (the v2 generator never embeds removes
    /// inside a set-op scenario).
    private struct SetOpEntry: Decodable {
        let id: String
        let op: SetOpKind
        let selfOps: [Op]
        let otherOps: [Op]
        let chainOps: [Op]?
        let expectedState: ExpectedState
        let probes: [Probe]?

        private enum CodingKeys: String, CodingKey {
            case id, op
            case selfOps = "self_ops"
            case otherOps = "other_ops"
            case chainOps = "chain_ops"
            case expectedState = "expected_state"
            case probes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            let opRaw = try container.decode(String.self, forKey: .op)
            guard let parsed = SetOpKind(rawValue: opRaw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .op, in: container,
                    debugDescription: "unknown set_op kind \(opRaw)"
                )
            }
            self.op = parsed
            self.selfOps = try container.decode([Op].self, forKey: .selfOps)
            self.otherOps = try container.decode([Op].self, forKey: .otherOps)
            self.chainOps = try container.decodeIfPresent([Op].self, forKey: .chainOps)
            self.expectedState = try container.decode(ExpectedState.self, forKey: .expectedState)
            self.probes = try container.decodeIfPresent([Probe].self, forKey: .probes)
        }
    }

    /// Snapshot of a Rangeable's observable state, mirroring the shape used
    /// by Ruby's `serialise_state` helper (insertion order + per-element
    /// canonical interval list keyed by canonical name).
    private struct ExpectedState: Decodable {
        let insertionOrder: [String]
        let intervals: [String: [[Int]]]

        private enum CodingKeys: String, CodingKey {
            case insertionOrder = "insertion_order"
            case intervals
        }
    }

    private enum OpType: String {
        case insert
        case remove
        case removeElement = "remove_element"
        case clear
        case removeRanges = "remove_ranges"
    }

    private enum SetOpKind: String {
        case union
        case intersect
        case difference
        case symmetricDifference = "symmetric_difference"
    }

    private struct Probe: Decodable {
        let kind: String
        let phase: String?
        let i: Int?
        let lo: Int?
        let hi: Int?
        let expected: ExpectedPayload

        private enum CodingKeys: String, CodingKey {
            case kind, phase, i, lo, hi, expected
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try container.decode(String.self, forKey: .kind)
            self.phase = try container.decodeIfPresent(String.self, forKey: .phase)
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

    // MARK: - Element table (matches the Ruby fixture generator order)

    private static let elementSpecs: [AnyMarkup] = [
        .strong,
        .italic,
        .code,
        .link("a"),
        .link("b")
    ]

    // MARK: - Top-level test entry

    func testRubySwiftCrossLanguageFixture() throws {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "cross_language", withExtension: "json") else {
            XCTFail("cross_language.json fixture missing from test bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)

        let schemaVersion = fixture.schemaVersion ?? 1
        switch schemaVersion {
        case 1:
            try runV1(fixture)
        case 2:
            try runV2(fixture)
        default:
            XCTFail("unsupported schema_version: \(schemaVersion)")
        }
    }

    // MARK: - v1 runner

    /// Every op is an `insert`; every probe is computed against the post-all-ops state.
    private func runV1(_ fixture: Fixture) throws {
        var r = Rangeable<AnyMarkup>()
        for op in fixture.ops {
            try applyOp(&r, op)
        }
        for probe in fixture.probes {
            try assertProbe(r, probe)
        }
    }

    // MARK: - v2 runner

    /// Three independent snapshots:
    ///   1. `rV1`            — after ops[0..<v1Boundary]            (all inserts)
    ///   2. `rAfterRemoves`  — rV1 + the first 30 `remove` ops only
    ///                         (skipping remove_element/clear/remove_ranges)
    ///   3. `rFinal`         — after ALL ops in order
    ///
    /// Probes are dispatched to the snapshot named by `phase` (defaulting
    /// to `v1`). Set-op entries are then validated independently.
    private func runV2(_ fixture: Fixture) throws {
        let ops = fixture.ops

        // Index the v1 boundary: the first non-insert op (== 161 in the
        // current Ruby generator). Computed dynamically so the runner stays
        // robust if the generator's tail composition changes.
        var v1Boundary = ops.count
        for (i, op) in ops.enumerated() where op.op != .insert {
            v1Boundary = i
            break
        }

        // Snapshot 1: r_v1.
        var rV1 = Rangeable<AnyMarkup>()
        for op in ops[0..<v1Boundary] {
            try applyOp(&rV1, op)
        }

        // Snapshot 2: r_after_removes. Independent of rV1 (mutating one
        // MUST NOT affect the other).
        var rAfterRemoves = try cloneViaOps(Array(ops[0..<v1Boundary]))
        var removeTaken = 0
        for op in ops[v1Boundary..<ops.count] {
            if removeTaken == 30 { break }
            if op.op == .remove {
                try applyOp(&rAfterRemoves, op)
                removeTaken += 1
            }
        }

        // Snapshot 3: r_final.
        var rFinal = try cloneViaOps(Array(ops[0..<v1Boundary]))
        for op in ops[v1Boundary..<ops.count] {
            try applyOp(&rFinal, op)
        }

        // Dispatch each probe to the matching snapshot.
        for probe in fixture.probes {
            let phase = probe.phase ?? "v1"
            switch phase {
            case "v1":
                try assertProbe(rV1, probe)
            case "after_removes":
                try assertProbe(rAfterRemoves, probe)
            case "final":
                try assertProbe(rFinal, probe)
            default:
                XCTFail("unknown probe phase: \(phase)")
            }
        }

        // Set-op validation.
        for entry in fixture.setOps ?? [] {
            try verifySetOp(entry)
        }
    }

    // MARK: - Op replay

    /// Replay a list of ops onto a fresh container — used by the v2 runner
    /// so each phase snapshot is independent.
    private func cloneViaOps(_ ops: [Op]) throws -> Rangeable<AnyMarkup> {
        var r = Rangeable<AnyMarkup>()
        for op in ops {
            try applyOp(&r, op)
        }
        return r
    }

    private func applyOp(_ r: inout Rangeable<AnyMarkup>, _ op: Op) throws {
        switch op.op {
        case .insert:
            guard let element = op.element, let start = op.start, let end = op.end else {
                XCTFail("insert op missing element/start/end")
                return
            }
            try r.insert(Self.elementSpecs[element], start: start, end: end)
        case .remove:
            guard let element = op.element, let start = op.start, let end = op.end else {
                XCTFail("remove op missing element/start/end")
                return
            }
            try r.remove(Self.elementSpecs[element], start: start, end: end)
        case .removeElement:
            guard let element = op.element else {
                XCTFail("remove_element op missing element")
                return
            }
            r.remove(Self.elementSpecs[element])
        case .clear:
            r.removeAll()
        case .removeRanges:
            guard let start = op.start, let end = op.end else {
                XCTFail("remove_ranges op missing start/end")
                return
            }
            try r.removeRanges(start: start, end: end)
        }
    }

    // MARK: - Probe assertion

    private func assertProbe(_ r: Rangeable<AnyMarkup>, _ probe: Probe) throws {
        let phaseLabel = probe.phase ?? "v1"
        switch probe.kind {
        case "subscript":
            guard let i = probe.i else {
                XCTFail("subscript probe missing i (phase=\(phaseLabel))")
                return
            }
            guard case .subscript_(let expectedKeys) = probe.expected else {
                XCTFail("subscript probe expected wrong shape (phase=\(phaseLabel))")
                return
            }
            let actualKeys = r[i].objs.map { canonicalKey(for: $0) }
            XCTAssertEqual(
                actualKeys, expectedKeys,
                "subscript mismatch (phase=\(phaseLabel), i=\(i))"
            )

        case "transitions":
            guard let lo = probe.lo, let hi = probe.hi else {
                XCTFail("transitions probe missing lo/hi (phase=\(phaseLabel))")
                return
            }
            guard case .transitions(let expected) = probe.expected else {
                XCTFail("transitions probe expected wrong shape (phase=\(phaseLabel))")
                return
            }
            let events = try r.transitions(lo: lo, hi: hi)
            XCTAssertEqual(
                events.count, expected.count,
                "transitions count mismatch (phase=\(phaseLabel), lo=\(lo), hi=\(hi))"
            )
            for (idx, (a, e)) in zip(events, expected).enumerated() {
                XCTAssertEqual(
                    a.coordinate, e.coordinate,
                    "transitions[\(idx)] coord mismatch (phase=\(phaseLabel), lo=\(lo), hi=\(hi))"
                )
                XCTAssertEqual(
                    kindString(a.kind), e.kind,
                    "transitions[\(idx)] kind mismatch (phase=\(phaseLabel), lo=\(lo), hi=\(hi))"
                )
                XCTAssertEqual(
                    canonicalKey(for: a.element), e.element,
                    "transitions[\(idx)] element mismatch (phase=\(phaseLabel), lo=\(lo), hi=\(hi))"
                )
            }

        default:
            XCTFail("unknown probe kind \(probe.kind) (phase=\(phaseLabel))")
        }
    }

    // MARK: - Set-op verification

    /// Builds `self` and `other` (and an optional `chain` operand), applies
    /// the named non-mutating set op, and compares the result's
    /// `insertion_order` + `intervals` snapshot against `expected_state`,
    /// then runs every probe attached to the entry.
    private func verifySetOp(_ entry: SetOpEntry) throws {
        let selfR = try buildFromInserts(entry.selfOps)
        let otherR = try buildFromInserts(entry.otherOps)
        var result = applySetOp(lhs: selfR, rhs: otherR, op: entry.op)
        if let chainOps = entry.chainOps {
            let chainR = try buildFromInserts(chainOps)
            result = applySetOp(lhs: result, rhs: chainR, op: entry.op)
        }

        // Compare result snapshot vs expected_state.
        let actualState = serialiseState(result)
        XCTAssertEqual(
            actualState.insertionOrder, entry.expectedState.insertionOrder,
            "set_op \(entry.id): insertion_order mismatch"
        )
        XCTAssertEqual(
            actualState.intervals, entry.expectedState.intervals,
            "set_op \(entry.id): intervals mismatch"
        )

        // Run any per-entry probes against the result.
        for probe in entry.probes ?? [] {
            try assertProbe(result, probe)
        }
    }

    /// Builds a fresh Rangeable from an insert-only op list.
    private func buildFromInserts(_ ops: [Op]) throws -> Rangeable<AnyMarkup> {
        var r = Rangeable<AnyMarkup>()
        for op in ops {
            try applyOp(&r, op)
        }
        return r
    }

    /// Dispatches to the non-mutating Swift set-op API, mapping the fixture
    /// names (`union` / `intersect` / `difference` / `symmetric_difference`)
    /// to their Swift counterparts (`union(_:)` / `intersection(_:)` /
    /// `subtracting(_:)` / `symmetricDifference(_:)`).
    private func applySetOp(
        lhs: Rangeable<AnyMarkup>,
        rhs: Rangeable<AnyMarkup>,
        op: SetOpKind
    ) -> Rangeable<AnyMarkup> {
        switch op {
        case .union:               return lhs.union(rhs)
        case .intersect:           return lhs.intersection(rhs)
        case .difference:          return lhs.subtracting(rhs)
        case .symmetricDifference: return lhs.symmetricDifference(rhs)
        }
    }

    /// Snapshots a Rangeable into the same shape Ruby's `serialise_state`
    /// produces: insertion_order list of canonical keys + intervals dict
    /// keyed by canonical name with each entry encoded as `[[lo, hi], …]`.
    private func serialiseState(_ r: Rangeable<AnyMarkup>) -> (insertionOrder: [String], intervals: [String: [[Int]]]) {
        var insertionOrder: [String] = []
        var intervals: [String: [[Int]]] = [:]
        for (element, ranges) in r {
            let key = canonicalKey(for: element)
            insertionOrder.append(key)
            intervals[key] = ranges.map { [$0.lo, $0.hi] }
        }
        return (insertionOrder, intervals)
    }

    // MARK: - Canonicalisation

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
