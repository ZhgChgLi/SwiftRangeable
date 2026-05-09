import Foundation
@testable import Rangeable

// Fixtures mirroring Ruby's `test/test_helper.rb`. Each struct represents
// a markup token; two instances of the same type with the same payload
// compare equal via `==`, simulating equivalence-class merging of markdown
// markup.

struct Strong: Hashable, RangeableElement {
    var tag: String = "strong"
}

struct Italic: Hashable, RangeableElement {
    var tag: String = "italic"
}

struct Code: Hashable, RangeableElement {
    var tag: String = "code"
}

struct Link: Hashable, RangeableElement {
    var url: String
}

enum Fixtures {
    static func strong() -> Strong { return Strong() }
    static func italic() -> Italic { return Italic() }
    static func code() -> Code { return Code() }
    static func link(_ url: String) -> Link { return Link(url: url) }
}

/// Polymorphic `Hashable` element used to put different fixture types in
/// the same `Rangeable`. The enum stands in for "any markup token".
enum AnyMarkup: Hashable {
    case strong
    case italic
    case code
    case link(String)
}

extension AnyMarkup: RangeableElement {}
