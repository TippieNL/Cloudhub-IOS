import Foundation

/// Names in the order a person counts them: "File 2" before "File 10".
///
/// A run of digits is read as one whole number, so "1.2.3" comes before
/// "1.2.10". Letters compare without regard to case. Then:
///
///  - The name before its extension is compared first, so "photo.jpg" stays
///    ahead of "photo 2.jpg", "photo-2.jpg" and "photo_2.jpg" alike. Only
///    something that reads as an extension counts: the letters and digits
///    after the last dot, at least one of them a letter.
///  - A name that runs out first comes first.
///  - Names that read the same are still never equal: fewer leading zeros
///    first, then upper case before lower.
///
/// Compared over UTF-16 code units, exactly as the Android client compares
/// Kotlin strings, so both apps sort a folder the same way. Digit runs are
/// compared as text of any length, so a 30-digit serial cannot overflow.
public enum NaturalOrder {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let sign = compareUnits(Array(a.utf16), Array(b.utf16))
        return sign < 0 ? .orderedAscending : (sign > 0 ? .orderedDescending : .orderedSame)
    }

    public static func less(_ a: String, _ b: String) -> Bool { compare(a, b) == .orderedAscending }

    static func compareUnits(_ a: [UInt16], _ b: [UInt16]) -> Int {
        let baseA = baseEnd(a)
        let baseB = baseEnd(b)
        let byBase = compareRange(a, 0, baseA, b, 0, baseB)
        if byBase != 0 { return byBase }
        let byExtension = compareRange(a, baseA, a.count, b, baseB, b.count)
        if byExtension != 0 { return byExtension }
        return tieBreak(a, b)
    }

    private static let dot: UInt16 = 0x2E
    private static let zero: UInt16 = 0x30

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isLetter(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return scalar.properties.isAlphabetic
    }

    /// Where the extension starts: the last dot, or the end when there is none.
    private static func baseEnd(_ name: [UInt16]) -> Int {
        guard let dotIndex = name.lastIndex(of: dot), dotIndex > 0, dotIndex != name.count - 1 else {
            return name.count
        }
        var letter = false
        for k in (dotIndex + 1)..<name.count {
            let c = name[k]
            if isLetter(c) { letter = true } else if !isDigit(c) { return name.count }
        }
        return letter ? dotIndex : name.count
    }

    private static func compareRange(_ a: [UInt16], _ aFrom: Int, _ aTo: Int,
                                     _ b: [UInt16], _ bFrom: Int, _ bTo: Int) -> Int {
        var i = aFrom
        var j = bFrom
        while i < aTo && j < bTo {
            if isDigit(a[i]) && isDigit(b[j]) {
                let endA = digitsEnd(a, i, aTo)
                let endB = digitsEnd(b, j, bTo)
                let byValue = compareNumbers(a, i, endA, b, j, endB)
                if byValue != 0 { return byValue }
                i = endA
                j = endB
            } else {
                let byChar = compareIgnoringCase(a[i], b[j])
                if byChar != 0 { return byChar }
                i += 1
                j += 1
            }
        }
        return sign((aTo - i) - (bTo - j))
    }

    private static func compareNumbers(_ a: [UInt16], _ aFrom: Int, _ aTo: Int,
                                       _ b: [UInt16], _ bFrom: Int, _ bTo: Int) -> Int {
        var i = aFrom
        var j = bFrom
        while i < aTo && a[i] == zero { i += 1 }
        while j < bTo && b[j] == zero { j += 1 }
        let lengths = sign((aTo - i) - (bTo - j))
        if lengths != 0 { return lengths }
        while i < aTo {
            if a[i] != b[j] { return a[i] < b[j] ? -1 : 1 }
            i += 1
            j += 1
        }
        return 0
    }

    private static func tieBreak(_ a: [UInt16], _ b: [UInt16]) -> Int {
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if isDigit(a[i]) && isDigit(b[j]) {
                let endA = digitsEnd(a, i, a.count)
                let endB = digitsEnd(b, j, b.count)
                let zeros = sign((endA - i) - (endB - j))
                if zeros != 0 { return zeros }
                i = endA
                j = endB
            } else {
                i += 1
                j += 1
            }
        }
        // Upper case before lower: plain code-unit order.
        return a.lexicographicallyPrecedes(b) ? -1 : (a == b ? 0 : 1)
    }

    private static func digitsEnd(_ s: [UInt16], _ from: Int, _ to: Int) -> Int {
        var k = from
        while k < to && isDigit(s[k]) { k += 1 }
        return k
    }

    /// As Kotlin's String.compareTo(ignoreCase = true) compares one character.
    static func compareIgnoringCase(_ x: UInt16, _ y: UInt16) -> Int {
        if x == y { return 0 }
        let ux = upper(x)
        let uy = upper(y)
        if ux == uy { return 0 }
        let lx = lower(ux)
        let ly = lower(uy)
        return lx == ly ? 0 : (lx < ly ? -1 : 1)
    }

    private static func upper(_ c: UInt16) -> UInt16 { mapped(c) { $0.properties.uppercaseMapping } }
    private static func lower(_ c: UInt16) -> UInt16 { mapped(c) { $0.properties.lowercaseMapping } }

    /// A single-unit case mapping, or the unit unchanged (as Char.uppercaseChar does).
    private static func mapped(_ c: UInt16, _ mapping: (Unicode.Scalar) -> String) -> UInt16 {
        guard let scalar = Unicode.Scalar(c) else { return c }
        let units = Array(mapping(scalar).utf16)
        return units.count == 1 ? units[0] : c
    }

    private static func sign(_ n: Int) -> Int { n < 0 ? -1 : (n > 0 ? 1 : 0) }
}

/// Kotlin's `String.compareTo(other, ignoreCase = true)`, which the Name sort uses.
public func compareIgnoringCase(_ a: String, _ b: String) -> Int {
    let x = Array(a.utf16)
    let y = Array(b.utf16)
    for k in 0..<min(x.count, y.count) {
        let byChar = NaturalOrder.compareIgnoringCase(x[k], y[k])
        if byChar != 0 { return byChar }
    }
    return x.count - y.count
}
