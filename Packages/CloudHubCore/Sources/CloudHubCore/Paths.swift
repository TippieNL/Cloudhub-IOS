import Foundation

/// Server paths: always absolute, "/" separated, "/" for the root.
public enum Paths {
    /// "/a/b.jpg" -> "/a"; "/b.jpg" -> "/"; "/" -> "/".
    public static func parentOf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let cut = String(path[..<slash])
        return cut.isEmpty ? "/" : cut
    }

    /// The last segment, or the path itself when it has none.
    public static func nameOf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? path : name
    }

    public static func join(_ parent: String, _ name: String) -> String {
        (parent == "/" || parent.isEmpty) ? "/\(name)" : "\(parent)/\(name)"
    }

    /// After the last dot, or "" when there is none (Kotlin's substringAfterLast('.', "")).
    public static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// Before the last dot, or the whole name when there is none.
    public static func stemOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }
}

/// Sizes and counts the way every screen writes them.
public enum Format {
    /// "512 B", "1.5 KB", "120 MB", "3.2 GB".
    public static func bytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    public static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// "1:05" or "1:02:03".
    public static func time(milliseconds ms: Int64) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
