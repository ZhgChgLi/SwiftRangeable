# SwiftRangeable

[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange)](https://swift.org) [![Platforms](https://img.shields.io/badge/platforms-iOS%2012%2B%20%7C%20macOS%2010.14%2B-blue)]() [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Reference Swift implementation of [`Rangeable<Element>`](https://github.com/ZhgChgLi/RangeableRFC) — a generic, integer-coordinate, closed-interval set container with first-insert ordered active queries.

## Installation

### Swift Package Manager

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ZhgChgLi/SwiftRangeable.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: ["Rangeable"]),
]
```

Or add the package via Xcode → File → Add Packages → paste the repository URL.

## Usage

```swift
import Rangeable

enum InlineMarkup: Hashable, RangeableElement {
    case strong
    case italic
    case link(String)
}

var r = Rangeable<InlineMarkup>()
try r.insert(.strong,        start: 2, end: 5)
try r.insert(.strong,        start: 3, end: 7)   // merges with [2, 5] → [2, 7]
try r.insert(.strong,        start: 9, end: 11)  // disjoint
try r.insert(.italic,        start: 3, end: 8)

r.getRange(of: .strong)   // [Interval(lo: 2, hi: 7), Interval(lo: 9, hi: 11)]
r.getRange(of: .italic)   // [Interval(lo: 3, hi: 8)]

r[4].objs    // [.strong, .italic]   first-insert order
r[8].objs    // [.italic]
r[10].objs   // [.strong]
```

### Sweep iteration via transitions

```swift
let events = r.transitions(over: 0...15)
for event in events {
    switch event.kind {
    case .open:
        print("\(event.coordinate ?? Int.max): open \(event.element)")
    case .close:
        print("\(event.coordinate ?? Int.max): close \(event.element)")
    }
}
```

## API

| Member | Type | Notes |
|---|---|---|
| `Rangeable<Element>()` | initializer | empty |
| `mutating func insert(_:start:end:) throws` | mutates self | throws `RangeableError.invalidInterval` if `start > end` |
| `subscript(_ i: Int)` | `Slot<Element>` | exposes `.objs` |
| `getRange(of:)` | `[Interval]` | merged disjoint ranges |
| `transitions(over:)` | `[TransitionEvent<Element>]` | accepts `ClosedRange<Int>` |
| `count` | `Int` | distinct elements |
| `isEmpty` | `Bool` | |
| iteration | `Sequence` conformance | `for (element, ranges) in r` |

## Semantics

- **End is inclusive**: `[a, b]` covers `a...b`, both ends.
- **Same-element merging**: equal elements (by `Hashable`) merge on overlap or integer adjacency. `[2, 4] ∪ [5, 7] = [2, 7]`.
- **Idempotent insert**: re-inserting a contained interval costs no version bump.
- **Out-of-order rejected**: `try insert(_, start: 5, end: 2)` throws.
- **Active-set ordering**: deterministic — first-insert order of the element.
- **Coordinate sentinel**: a close event for an interval ending at `Int.max` carries `coordinate == nil` (None == +∞ per RFC § 4.7).
- **Value semantics + COW**: `Rangeable` is a `struct` with copy-on-write storage; assignment is O(1).

See [RangeableRFC](https://github.com/ZhgChgLi/RangeableRFC) § 4 for normative semantics and § 10 for the 23-case test contract.

## Cross-language consistency

This Swift implementation joins the [Ruby](https://github.com/ZhgChgLi/RubyRangeable), [Python](https://github.com/ZhgChgLi/PythonRangeable), [JS](https://github.com/ZhgChgLi/JSRangeable), [Kotlin](https://github.com/ZhgChgLi/KotlinRangeable) and [Go](https://github.com/ZhgChgLi/GoRangeable) implementations. All six share a 160-op / 86-probe JSON fixture and produce byte-identical outputs.

## See also

- **[RangeableRFC](https://github.com/ZhgChgLi/RangeableRFC)** — normative specification.
- **[RubyRangeable](https://github.com/ZhgChgLi/RubyRangeable)** — Ruby reference (`gem install rangeable`).
- **[PythonRangeable](https://github.com/ZhgChgLi/PythonRangeable)** — Python reference (`pip install rangeable`).
- **[JSRangeable](https://github.com/ZhgChgLi/JSRangeable)** — TypeScript reference (`npm i rangeable-js`).
- **[KotlinRangeable](https://github.com/ZhgChgLi/KotlinRangeable)** — Kotlin/JVM reference (JitPack).
- **[GoRangeable](https://github.com/ZhgChgLi/GoRangeable)** — Go reference (`go get github.com/ZhgChgLi/GoRangeable`).

## Development

```sh
$ swift test
```

38 tests cover the full RFC § 10 contract, additional coverage for `count` / `isEmpty` / iteration / COW semantics, a property test against a brute-force oracle, and the cross-language fixture.

## License

MIT © [ZhgChgLi](https://github.com/ZhgChgLi)
