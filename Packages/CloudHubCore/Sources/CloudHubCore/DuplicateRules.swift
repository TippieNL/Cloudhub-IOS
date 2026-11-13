import Foundation

/// What the duplicates screen offers to delete, and when to stop asking.
///
/// Every group keeps a copy, always -- a duplicate finder that can empty a
/// group has deleted the photo, not the duplicate -- and nothing is ever
/// deleted without being asked for.
public enum DuplicateRules {
    /// A server that never finishes is not polled for ever.
    public static let maxSlices = 500

    public static func shouldContinue(_ scan: DuplicateScan, slicesSoFar: Int) -> Bool {
        !scan.done && slicesSoFar < maxSlices
    }

    /// A stable identity: the first path, since a file belongs to exactly one group.
    public static func groupId(_ group: DuplicateGroup) -> String { group.files.first?.path ?? "" }

    public static func nameOf(_ path: String) -> String { Paths.nameOf(path) }

    public static func folderOf(_ path: String) -> String { Paths.parentOf(path) }

    /// The copy chosen, or else the oldest; ties break on the path.
    public static func keeper(for group: DuplicateGroup, chosen: String?) -> String {
        if let chosen, group.files.contains(where: { $0.path == chosen }) { return chosen }
        return group.files.min { a, b in a.mtime != b.mtime ? a.mtime < b.mtime : a.path < b.path }?.path ?? ""
    }

    public static func removable(_ group: DuplicateGroup, chosen: String?) -> [String] {
        if group.files.count <= 1 { return [] }
        let keep = keeper(for: group, chosen: chosen)
        return group.files.map(\.path).filter { $0 != keep }
    }

    public static func removable(in groups: [DuplicateGroup], keeping: [String: String]) -> [String] {
        groups.flatMap { removable($0, chosen: keeping[groupId($0)]) }
    }

    public static func freed(by groups: [DuplicateGroup], selected: Set<String>) -> Int64 {
        groups.reduce(0) { sum, group in
            sum + group.files.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
        }
    }

    /// Photos, Videos or Other -- never All.
    public static func kindOf(_ group: DuplicateGroup) -> KindFilter {
        switch group.kind {
        case "image": return .photos
        case "video": return .videos
        case nil: return byNames(group)
        default: return .other
        }
    }

    private static func byNames(_ group: DuplicateGroup) -> KindFilter {
        let kinds = group.files.map { kindOfName($0.path) }
        if kinds.contains(.photos) { return .photos }
        if kinds.contains(.videos) { return .videos }
        return .other
    }

    private static let cameraStills: Set<String> = ["heic", "heif", "tif", "tiff"]

    private static func kindOfName(_ path: String) -> KindFilter {
        let ext = Paths.extensionOf(nameOf(path)).lowercased()
        if FileEntry.image.contains(ext) || cameraStills.contains(ext) { return .photos }
        if FileEntry.video.contains(ext) { return .videos }
        return .other
    }

    public static func matches(_ filter: KindFilter, _ group: DuplicateGroup) -> Bool {
        filter == .all || kindOf(group) == filter
    }

    public static func counts(_ groups: [DuplicateGroup]) -> [KindFilter: Int] {
        Dictionary(uniqueKeysWithValues: KindFilter.allCases.map { f in (f, groups.filter { matches(f, $0) }.count) })
    }

    public static func effective(_ chosen: KindFilter, _ groups: [DuplicateGroup]) -> KindFilter {
        (chosen != .all && !groups.contains { matches(chosen, $0) }) ? .all : chosen
    }

    public static func shown(_ groups: [DuplicateGroup], _ filter: KindFilter) -> [DuplicateGroup] {
        groups.filter { matches(filter, $0) }
    }

    /// The copies ticked among the sets on show: what Move to trash acts on.
    public static func selected(in groups: [DuplicateGroup], _ selected: Set<String>) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for group in groups {
            for file in group.files where selected.contains(file.path) && seen.insert(file.path).inserted {
                out.append(file.path)
            }
        }
        return out
    }

    /// True when a selection would leave a group with nothing in it.
    public static func wouldEmptyAGroup(_ groups: [DuplicateGroup], _ selected: Set<String>) -> Bool {
        groups.contains { group in !group.files.isEmpty && group.files.allSatisfy { selected.contains($0.path) } }
    }

    /// How far along a running scan is, or nil while that cannot be said.
    public static func progress(_ scan: DuplicateScan) -> Double? {
        if scan.done { return 1 }
        if scan.toHash <= 0 { return nil }
        return min(max(Double(scan.hashed) / Double(scan.toHash), 0), 1)
    }

    /// The same scan with some copies gone; a group left with one copy leaves too.
    public static func without(_ scan: DuplicateScan, removed: Set<String>) -> DuplicateScan {
        if removed.isEmpty { return scan }
        let groups: [DuplicateGroup] = scan.groups.compactMap { group in
            let kept = group.files.filter { !removed.contains($0.path) }
            guard kept.count > 1 else { return nil }
            var g = group
            g.files = kept
            g.count = kept.count
            g.reclaimable = group.bytes * Int64(kept.count - 1)
            return g
        }
        var out = scan
        out.groups = groups
        out.duplicateFiles = groups.reduce(0) { $0 + $1.count - 1 }
        out.reclaimable = groups.reduce(0) { $0 + $1.reclaimable }
        return out
    }

    public static func summary(groupCount: Int, reclaimable: Int64) -> String {
        if groupCount == 0 { return "No duplicates found" }
        return "\(groupCount) \(groupCount == 1 ? "set" : "sets") of copies · \(Format.bytes(reclaimable)) to reclaim"
    }

    public static func activity(_ scan: DuplicateScan) -> String {
        if scan.done { return "\(scan.scanned) files checked" }
        if scan.toHash <= 0 { return "Looking through \(scan.scanned) files…" }
        return "Comparing \(scan.hashed) of \(scan.toHash) possible matches…"
    }
}
