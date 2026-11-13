import Foundation

/// Which theme to use, when the phone's own setting is not the last word.
public enum ThemeChoice: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public static func of(_ name: String?) -> ThemeChoice {
        allCases.first { $0.rawValue.caseInsensitiveCompare(name ?? "") == .orderedSame } ?? .system
    }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Small, boring persistence for everything that is not a secret.
///
/// The session cookie is not here: it is a credential, and the app keeps it
/// in the Keychain (see CookieVault in the app target).
public final class Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var serverURL: String? {
        get { defaults.string(forKey: "server_url") }
        set { defaults.set(newValue, forKey: "server_url") }
    }

    /// The last username, when sign-in was asked to remember it. Never the password.
    public var rememberedUsername: String? {
        get { defaults.string(forKey: "remembered_username") }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                defaults.set(newValue, forKey: "remembered_username")
            } else {
                defaults.removeObject(forKey: "remembered_username")
            }
        }
    }

    public var theme: ThemeChoice {
        get { ThemeChoice.of(defaults.string(forKey: "theme_choice")) }
        set { defaults.set(newValue.rawValue, forKey: "theme_choice") }
    }

    /// Grid or list, remembered per install like the web app does.
    public var gridView: Bool {
        get { defaults.object(forKey: "grid_view") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "grid_view") }
    }

    /// The subtitle language last chosen, or nil for none.
    public var subtitleLanguage: String? {
        get { defaults.string(forKey: "subtitle_language") }
        set {
            if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: "subtitle_language") }
            else { defaults.removeObject(forKey: "subtitle_language") }
        }
    }

    /// Certificates the person explicitly accepted, by SHA-256 -- never by host.
    public var pinnedCertificates: Set<String> {
        Set(defaults.stringArray(forKey: "cert_pins") ?? [])
    }

    public func pin(_ fingerprint: String) {
        defaults.set(Array(pinnedCertificates.union([fingerprint])).sorted(), forKey: "cert_pins")
    }

    /* ---- where playback got to -------------------------------------------
     *
     * One ordered list rather than a key per file, so the whole set is pruned
     * in a single write and preferences cannot grow without limit.
     */

    private struct Position: Codable {
        var path: String
        var ms: Int64
    }

    private func readPositions() -> [Position] {
        guard let data = defaults.data(forKey: "resume_positions") else { return [] }
        return (try? JSONDecoder().decode([Position].self, from: data)) ?? []
    }

    private func writePositions(_ list: [Position]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: "resume_positions")
    }

    public func resumePosition(of path: String) -> Int64 {
        readPositions().first { $0.path == path }?.ms ?? 0
    }

    public func rememberResumePosition(_ path: String, ms: Int64) {
        var list = readPositions().filter { $0.path != path }
        if ms > 0 { list.append(Position(path: path, ms: ms)) }
        let pruned = ResumePolicy.prune(list.map { ($0.path, $0.ms) }, limit: ResumePolicy.maxRemembered)
        writePositions(pruned.map { Position(path: $0.0, ms: $0.1) })
    }

    public func forgetResumePosition(_ path: String) { rememberResumePosition(path, ms: 0) }

    public var rememberedPositionCount: Int { readPositions().count }

    public func forgetAllResumePositions() { defaults.removeObject(forKey: "resume_positions") }
}
