import Foundation

/// What the content area of the file browser should be showing.
public enum Shown: Sendable {
    /// Loading, with nothing yet worth keeping on screen.
    case skeleton
    /// Entries to draw. A refresh over existing entries stays here.
    case content
    /// The server answered, and the folder really has nothing in it.
    case empty
    /// There are entries, but the filter or the search matched none of them.
    case noMatches
    /// The listing failed. Never confused with an empty folder.
    case error
}

/// How the last attempt to list a folder ended.
public enum LoadState: Sendable { case loading, ready, failed }

/// Which of the five states the browser is in. A failure outranks
/// everything; content already on screen outranks a refresh's spinner.
public func browserState(load: LoadState, hasEntries: Bool, hasVisible: Bool, filtering: Bool) -> Shown {
    if load == .failed { return .error }
    if load == .loading && !hasEntries { return .skeleton }
    if hasVisible { return .content }
    if load == .loading { return .content }
    return filtering ? .noMatches : .empty
}

/// When a skeleton may appear, and for how long at least: both exist to stop a flicker.
public enum SkeletonTiming {
    public static let delayMs: UInt64 = 120
    public static let minShownMs: UInt64 = 400

    public static func lingerMs(shownForMs: UInt64) -> UInt64 {
        shownForMs >= minShownMs ? 0 : minShownMs - shownForMs
    }
}

/// How a folder is sorted. Natural is Name with numbers read as numbers.
public enum FileSort: String, CaseIterable, Sendable {
    case name, natural, newest, largest

    public var label: String {
        switch self {
        case .name: return "Name"
        case .natural: return "Natural Number"
        case .newest: return "Newest"
        case .largest: return "Largest"
        }
    }

    /// Folders first, then by the chosen rule.
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch self {
            case .name: return compareIgnoringCase(a.name, b.name) < 0
            case .natural: return NaturalOrder.less(a.name, b.name)
            case .newest: return a.modified > b.modified
            case .largest: return a.size > b.size
            }
        }
    }
}

/// How the All folders search is asked for, and what its header says.
public enum SearchRules {
    /// The server refuses anything shorter.
    public static let minQuery = 2
    /// All folders searches from the root, whatever folder is open.
    public static let scope = "/"
    /// How long the server may walk before answering with what it has.
    public static let sliceMs = 2_000
    /// How long typing must pause before an edit searches again.
    public static let debounceMs: UInt64 = 400
    /// A server that never finishes is not asked for ever.
    public static let maxSlices = 100

    public static func canSearch(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespaces).count >= minQuery
    }

    /// The server said there is more, it got further than last time, and the bound has not been reached.
    public static func shouldContinue(_ found: SearchResult, scannedBefore: Int, slicesSoFar: Int) -> Bool {
        found.incomplete && found.scanned > scannedBefore && slicesSoFar < maxSlices
    }

    /// "No matches" is only said once every folder has been searched.
    public static func summary(query: String, count n: Int, truncated: Bool, scanned: Int,
                               searching: Bool, error: String?) -> String {
        let matches = "\(n) match\(n == 1 ? "" : "es")"
        if let error, n > 0 { return "\(matches) so far; the search stopped: \(error)" }
        if let error { return "Search failed: \(error)" }
        if searching && n == 0 { return "Searching all folders for \u{201C}\(query)\u{201D}…" }
        if searching { return "\(matches) so far, still searching…" }
        if n == 0 && truncated { return "No matches for \u{201C}\(query)\u{201D} in the first \(scanned) files searched" }
        if n == 0 { return "No matches for \u{201C}\(query)\u{201D} in any folder" }
        if truncated { return "\(matches) (showing the first \(n))" }
        return "\(matches) in all folders"
    }
}

/// Whether a rename prompt's answer asks for anything at all.
public func isRename(current: String, requested: String) -> Bool {
    !requested.trimmingCharacters(in: .whitespaces).isEmpty && requested != current
}
