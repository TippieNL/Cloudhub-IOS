import Foundation

/// All, Photos, Videos, Other -- the four filters the web app's Favorites
/// page offers, used by Favorites and Duplicates alike so "Photos" means one
/// thing across the app.
public enum KindFilter: String, CaseIterable, Sendable, Identifiable {
    case all, photos, videos, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .other: return "Other"
        }
    }

    public func matches(_ entry: FileEntry) -> Bool {
        switch self {
        case .all: return true
        case .photos: return entry.kind == .image
        case .videos: return entry.kind == .video
        case .other: return entry.kind != .image && entry.kind != .video
        }
    }
}

public enum FavoriteRules {
    public static func counts(_ entries: [FileEntry]) -> [KindFilter: Int] {
        Dictionary(uniqueKeysWithValues: KindFilter.allCases.map { f in (f, entries.filter(f.matches).count) })
    }

    /// A filter that has emptied falls back to All rather than leaving an empty screen.
    public static func effective(_ chosen: KindFilter, _ entries: [FileEntry]) -> KindFilter {
        (chosen != .all && !entries.contains(where: chosen.matches)) ? .all : chosen
    }

    /// A new star goes to the top, where the server will list it.
    public static func afterToggle(_ entries: [FileEntry], _ entry: FileEntry, starred: Bool) -> [FileEntry] {
        let others = entries.filter { $0.path != entry.path }
        return starred ? [entry] + others : others
    }
}

/// What the photo viewer shows around the photos, and what an edit does to the row.
public enum ViewerRules {
    /// "3 of 12", or nothing for a single photo.
    public static func counter(index: Int, count: Int) -> String? {
        count <= 1 ? nil : "\(min(max(index, 0), count - 1) + 1) of \(count)"
    }

    public static func without(_ images: [FileEntry], path: String) -> [FileEntry] {
        images.filter { $0.path != path }
    }

    /// The one that moved into its place, or the new last one if it was last.
    public static func pageAfterRemoval(index: Int, remaining: Int) -> Int {
        remaining <= 0 ? 0 : min(max(index, 0), remaining - 1)
    }

    /// An undone delete goes back where it was -- and not twice.
    public static func restored(_ images: [FileEntry], _ entry: FileEntry, at: Int) -> [FileEntry] {
        if images.contains(where: { $0.path == entry.path }) { return images }
        var copy = images
        copy.insert(entry, at: min(max(at, 0), copy.count))
        return copy
    }

    /// A rename, with the name the server ended up with. Renamed into
    /// something that is not a photo, it leaves the viewer.
    public static func renamed(_ images: [FileEntry], old: FileEntry, newPath: String, newName: String) -> [FileEntry] {
        var updated = old
        updated.path = newPath
        updated.name = newName
        updated.fileExtension = nil
        if updated.kind != .image { return without(images, path: old.path) }
        return images.map { $0.path == old.path ? updated : $0 }
    }
}

/// What an added subtitle file has to be called for the player to find it.
public enum SubtitleRules {
    public static let extensions: Set<String> = ["srt", "vtt"]

    public static func isSubtitleFile(_ fileName: String) -> Bool {
        extensions.contains(Paths.extensionOf(fileName).lowercased())
    }

    /// "The.Film.2024.1080p.WEB-DL.nl.srt" -> "nl"; offered for correction, never used silently.
    public static func guessLanguage(_ fileName: String) -> String {
        let stem = Paths.stemOf(fileName)
        guard stem.contains(".") else { return "" }
        let last = Paths.extensionOf(stem).lowercased()
        return last.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil ? last : ""
    }

    /// `Holiday.mp4` plus "nl" gives `Holiday.nl.srt`; no language gives `Holiday.srt`.
    public static func fileName(forVideo videoName: String, language: String, extension ext: String) -> String {
        let stem = Paths.stemOf(videoName)
        let tag = language.trimmingCharacters(in: .whitespaces).lowercased()
        var suffix = ext.trimmingCharacters(in: .whitespaces).lowercased()
        if suffix.hasPrefix(".") { suffix.removeFirst() }
        return tag.isEmpty ? "\(stem).\(suffix)" : "\(stem).\(tag).\(suffix)"
    }
}

/// Where a download is saved, and under what name.
public enum DownloadRules {
    /// `name`, or the first of "name (1).ext", "name (2).ext", ... that is free --
    /// the pattern iOS's Files app and Android's MediaStore both use.
    public static func freeName(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) { return name }
        let dot = name.lastIndex(of: ".")
        // A leading dot starts a hidden file's name; it is not an extension.
        let base: String
        let ext: String
        if let dot, dot > name.startIndex {
            base = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            base = name
            ext = ""
        }
        for n in 1...999 {
            let candidate = "\(base) (\(n))\(ext)"
            if !isTaken(candidate) { return candidate }
        }
        return "\(base) (\(Int(Date().timeIntervalSince1970 * 1000)))\(ext)"
    }

    /// Only the last segment, never empty.
    public static func safeName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        return last.trimmingCharacters(in: .whitespaces).isEmpty ? "download" : last
    }
}

/// Whether a remembered playback position is worth returning to, and how many to keep.
public enum ResumePolicy {
    public static let minPositionMs: Int64 = 10_000
    public static let endMarginMs: Int64 = 15_000
    public static let maxRemembered = 200

    /// Both ends are excluded; an unknown duration (0) still honours the position.
    public static func shouldResume(positionMs: Int64, durationMs: Int64) -> Bool {
        if positionMs < minPositionMs { return false }
        if durationMs <= 0 { return true }
        return positionMs < durationMs - endMarginMs
    }

    /// Keep the most recent `limit` of an ordered list of (path, position).
    public static func prune(_ entries: [(String, Int64)], limit: Int) -> [(String, Int64)] {
        if limit <= 0 { return [] }
        if entries.count <= limit { return entries }
        return Array(entries.suffix(limit))
    }
}

/// Which third of the video a double tap landed in.
public enum TapZone: Sendable { case seekBack, middle, seekForward }

public func zoneAt(x: Double, width: Double) -> TapZone {
    if width <= 0 { return .middle }
    let fraction = x / width
    if fraction < 0.35 { return .seekBack }
    if fraction > 0.65 { return .seekForward }
    return .middle
}

/// What a video tile is allowed to cost, and what is handed back to the server.
public enum VideoThumbnails {
    /// The server refuses anything over 1280px; this is a tile, not a poster.
    public static let maxEdgePx = 640
    public static let jpegQuality = 0.7

    /// Never upscaled.
    public static func scaledSize(width: Int, height: Int) -> (Int, Int) {
        if width <= 0 || height <= 0 { return (0, 0) }
        let longest = max(width, height)
        if longest <= maxEdgePx { return (width, height) }
        let factor = Double(maxEdgePx) / Double(longest)
        return (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
    }

    private static let lock = NSLock()
    private static var contributed: [String] = []
    private static var contributedSet: Set<String> = []

    /// True the first time a path is offered this session (bounded at 256).
    public static func markContributed(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if contributedSet.contains(path) { return false }
        contributed.append(path)
        contributedSet.insert(path)
        while contributed.count > 256 {
            contributedSet.remove(contributed.removeFirst())
        }
        return true
    }
}
