import Foundation

/// How much space is left, and what "left" even means.
///
/// A per-account quota outranks the whole-store limit, which outranks the
/// disk. With neither limit set the drive really is the ceiling, and calling
/// that "unlimited" while the disk fills up would be a comfortable lie.
public enum StorageMeter {
    public static let warnAt = 0.90

    public enum Against: Sendable { case quota, store, disk }

    public struct Reading: Equatable, Sendable {
        public var against: Against
        public var usedBytes: Int64
        public var totalBytes: Int64
        public var remainingBytes: Int64
        public var fraction: Double

        public var nearlyFull: Bool { fraction >= StorageMeter.warnAt }
        public var unlimited: Bool { against == .disk }
    }

    public static func of(usedBytes: Int64, quotaBytes: Int64, storeUsedBytes: Int64, storeLimitBytes: Int64,
                          diskFreeBytes: Int64, diskTotalBytes: Int64) -> Reading {
        if quotaBytes > 0 { return reading(.quota, usedBytes, quotaBytes) }
        if storeLimitBytes > 0 { return reading(.store, storeUsedBytes, storeLimitBytes) }
        return reading(.disk, max(0, diskTotalBytes - diskFreeBytes), diskTotalBytes)
    }

    public static func of(_ m: MyStorage) -> Reading {
        of(usedBytes: m.usedBytes, quotaBytes: m.quotaBytes, storeUsedBytes: m.storeUsedBytes,
           storeLimitBytes: m.storageLimitBytes, diskFreeBytes: m.diskFreeBytes, diskTotalBytes: m.diskTotalBytes)
    }

    private static func reading(_ against: Against, _ used: Int64, _ total: Int64) -> Reading {
        let safeUsed = max(0, used)
        let fraction = total <= 0 ? 0 : min(max(Double(safeUsed) / Double(total), 0), 1)
        return Reading(against: against, usedBytes: safeUsed, totalBytes: max(0, total),
                       remainingBytes: max(0, total - safeUsed), fraction: fraction)
    }
}

/// What a photo says about itself, formatted. Reading the values is the
/// app's job (ImageIO); the wording is decided here.
public enum PhotoFacts {
    /// "4032 × 3024 · 12.2 MP".
    public static func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let mp = Double(width) * Double(height) / 1_000_000
        return String(format: "%d × %d · %.1f MP", width, height, mp)
    }

    /// EXIF's "2024:05:17 14:03:22" as "2024-05-17 14:03"; zeros mean unknown.
    public static func taken(_ exif: String?) -> String? {
        guard let text = exif?.trimmingCharacters(in: .whitespaces),
              let match = text.range(of: #"^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2})(:\d{2}.*)?$"#, options: .regularExpression),
              match.lowerBound == text.startIndex else { return nil }
        let digits = text.prefix(16)
        let parts = digits.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "T" }).map(String.init)
        guard parts.count >= 5 else { return nil }
        if parts[0] == "0000" || parts[1] == "00" || parts[2] == "00" { return nil }
        return "\(parts[0])-\(parts[1])-\(parts[2]) \(parts[3]):\(parts[4])"
    }

    /// Make and model as one name, without the make twice.
    public static func camera(make: String?, model: String?) -> String? {
        let m = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let n = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if n.isEmpty { return m.isEmpty ? nil : m }
        if m.isEmpty || n.lowercased().hasPrefix(m.lowercased()) { return n }
        return "\(m) \(n)"
    }

    /// "f/1.7 · 1/120 s · ISO 50 · 6.9 mm" -- whichever the camera wrote.
    public static func exposure(fNumber: Double?, seconds: Double?, iso: Int?, focalMm: Double?) -> String? {
        var parts: [String] = []
        if let f = fNumber, f > 0 { parts.append("f/" + trimmed(f)) }
        if let s = seconds, s > 0 { parts.append(shutter(s)) }
        if let iso, iso > 0 { parts.append("ISO \(iso)") }
        if let mm = focalMm, mm > 0 { parts.append(trimmed(mm) + " mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func shutter(_ seconds: Double) -> String {
        seconds >= 1 ? trimmed(seconds) + " s" : "1/\(Int((1 / seconds).rounded())) s"
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
