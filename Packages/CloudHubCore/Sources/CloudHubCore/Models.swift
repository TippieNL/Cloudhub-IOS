import Foundation

/*
 * The server's JSON, as the app reads it.
 *
 * Every field has a default and a missing or mistyped key falls back to it,
 * the way the Android client's `ignoreUnknownKeys` + defaults behave: a newer
 * or older server adding or dropping a field must not break the whole reply.
 */

extension KeyedDecodingContainer {
    /// The value under `key`, or `fallback` when it is absent, null or of another type.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// The value under `key`, or nil.
    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// One row of a folder listing, matching FileService::entry() on the server.
public struct FileEntry: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: String
    public var fileExtension: String?
    /// The server already has a cached frame for this video.
    public var hasThumbnail: Bool

    public var id: String { path }

    public init(
        name: String, path: String, isDirectory: Bool = false, size: Int64 = 0,
        modified: String = "", fileExtension: String? = nil, hasThumbnail: Bool = false
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.fileExtension = fileExtension
        self.hasThumbnail = hasThumbnail
    }

    enum CodingKeys: String, CodingKey {
        case name, path, isDirectory, size, modified, hasThumbnail
        case fileExtension = "extension"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, "")
        path = c.value(.path, "")
        isDirectory = c.value(.isDirectory, false)
        size = c.value(.size, Int64(0))
        modified = c.value(.modified, "")
        fileExtension = c.optional(.fileExtension)
        hasThumbnail = c.value(.hasThumbnail, false)
    }

    /// Lower case, without the dot.
    public var ext: String {
        let raw = fileExtension ?? Paths.extensionOf(name)
        return (raw.hasPrefix(".") ? String(raw.dropFirst()) : raw).lowercased()
    }

    public enum Kind: Sendable { case folder, image, video, audio, pdf, text, other }

    public var kind: Kind {
        if isDirectory { return .folder }
        let e = ext
        if FileEntry.image.contains(e) { return .image }
        if FileEntry.video.contains(e) { return .video }
        if FileEntry.audio.contains(e) { return .audio }
        if e == "pdf" { return .pdf }
        if FileEntry.text.contains(e) { return .text }
        return .other
    }

    // Kept in step with the sets in public/assets/js/app.js. HEIC is added
    // here because iOS draws it natively and an iPhone is what makes them.
    public static let image: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "avif", "heic", "heif"]
    public static let video: Set<String> = ["mp4", "webm", "ogv", "ogg", "mov", "m4v", "avi", "mkv",
                                            "mpeg", "mpg", "3gp", "3g2", "ts", "m2ts", "mts"]
    public static let audio: Set<String> = ["mp3", "wav", "oga", "m4a", "aac", "flac", "opus"]
    public static let text: Set<String> = ["txt", "md", "csv", "log", "json", "xml", "yml", "yaml"]

    /// The folder this entry is in.
    public var parent: String { Paths.parentOf(path) }
}

public struct User: Codable, Hashable, Sendable {
    public var id: Int
    public var username: String
    public var role: String

    public init(id: Int = 0, username: String = "", role: String = "viewer") {
        self.id = id
        self.username = username
        self.role = role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, 0)
        username = c.value(.username, "")
        role = c.value(.role, "viewer")
    }

    public var canWrite: Bool { role == "editor" || role == "admin" }
    public var isAdmin: Bool { role == "admin" }
}

/// What the second step of signing in needs, as TwoFactor::signInInfo() describes it.
public struct SecondStep: Codable, Hashable, Sendable {
    public var method: String
    /// The last two digits of the number the code goes to.
    public var phoneEnding: String?
    public var codeLength: Int
    /// False when the server cannot text this account: a recovery code is the only way in.
    public var smsAvailable: Bool
    public var codeSent: Bool
    /// Seconds before another code may be asked for.
    public var resendIn: Int
    public var expiresIn: Int?

    public init(method: String = "sms", phoneEnding: String? = nil, codeLength: Int = 6,
                smsAvailable: Bool = true, codeSent: Bool = false, resendIn: Int = 0, expiresIn: Int? = nil) {
        self.method = method
        self.phoneEnding = phoneEnding
        self.codeLength = codeLength
        self.smsAvailable = smsAvailable
        self.codeSent = codeSent
        self.resendIn = resendIn
        self.expiresIn = expiresIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = c.value(.method, "sms")
        phoneEnding = c.optional(.phoneEnding)
        codeLength = c.value(.codeLength, 6)
        smsAvailable = c.value(.smsAvailable, true)
        codeSent = c.value(.codeSent, false)
        resendIn = c.value(.resendIn, 0)
        expiresIn = c.optional(.expiresIn)
    }
}

public struct AuthStatus: Codable, Sendable {
    public var authenticated: Bool
    public var user: User?
    public var csrfToken: String
    /// Set while this session's password was right and its texted code is still awaited.
    public var twoFactor: SecondStep?

    public init(authenticated: Bool = false, user: User? = nil, csrfToken: String = "", twoFactor: SecondStep? = nil) {
        self.authenticated = authenticated
        self.user = user
        self.csrfToken = csrfToken
        self.twoFactor = twoFactor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authenticated = c.value(.authenticated, false)
        user = c.optional(.user)
        csrfToken = c.value(.csrfToken, "")
        twoFactor = c.optional(.twoFactor)
    }
}

public struct LoginResult: Codable, Sendable {
    public var success: Bool
    public var user: User?
    public var csrfToken: String
    /// Set, with success false, when the password was right but a texted code is wanted too.
    public var twoFactor: SecondStep?
    /// After signing in with a recovery code: how many are left.
    public var recoveryCodesLeft: Int?

    public init(success: Bool = false, user: User? = nil, csrfToken: String = "",
                twoFactor: SecondStep? = nil, recoveryCodesLeft: Int? = nil) {
        self.success = success
        self.user = user
        self.csrfToken = csrfToken
        self.twoFactor = twoFactor
        self.recoveryCodesLeft = recoveryCodesLeft
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = c.value(.success, false)
        user = c.optional(.user)
        csrfToken = c.value(.csrfToken, "")
        twoFactor = c.optional(.twoFactor)
        recoveryCodesLeft = c.optional(.recoveryCodesLeft)
    }
}

/// A code was texted: where to, for how long it works, and when another may be asked for.
public struct CodeSent: Codable, Sendable {
    public var sent: Bool
    public var phoneEnding: String?
    public var expiresIn: Int?
    public var resendIn: Int
    public var codeLength: Int

    public init(sent: Bool = false, phoneEnding: String? = nil, expiresIn: Int? = nil, resendIn: Int = 0, codeLength: Int = 6) {
        self.sent = sent
        self.phoneEnding = phoneEnding
        self.expiresIn = expiresIn
        self.resendIn = resendIn
        self.codeLength = codeLength
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = c.value(.sent, false)
        phoneEnding = c.optional(.phoneEnding)
        expiresIn = c.optional(.expiresIn)
        resendIn = c.value(.resendIn, 0)
        codeLength = c.value(.codeLength, 6)
    }
}

/// GET /api/users/me/two-factor.
public struct TwoFactorOverview: Codable, Hashable, Sendable {
    public var available: Bool
    public var schemaReady: Bool
    public var smsAvailable: Bool
    public var enabled: Bool
    public var phoneEnding: String?
    public var enabledAt: String?
    public var recoveryCodesLeft: Int
    public var codeLength: Int

    public init(available: Bool = false, schemaReady: Bool = true, smsAvailable: Bool = false, enabled: Bool = false,
                phoneEnding: String? = nil, enabledAt: String? = nil, recoveryCodesLeft: Int = 0, codeLength: Int = 6) {
        self.available = available
        self.schemaReady = schemaReady
        self.smsAvailable = smsAvailable
        self.enabled = enabled
        self.phoneEnding = phoneEnding
        self.enabledAt = enabledAt
        self.recoveryCodesLeft = recoveryCodesLeft
        self.codeLength = codeLength
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.value(.available, false)
        schemaReady = c.value(.schemaReady, true)
        smsAvailable = c.value(.smsAvailable, false)
        enabled = c.value(.enabled, false)
        phoneEnding = c.optional(.phoneEnding)
        enabledAt = c.optional(.enabledAt)
        recoveryCodesLeft = c.value(.recoveryCodesLeft, 0)
        codeLength = c.value(.codeLength, 6)
    }
}

public struct StageProblem: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryAfter: Int

    public init(code: String = "", message: String = "", retryAfter: Int = 0) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.value(.code, "")
        message = c.value(.message, "")
        retryAfter = c.value(.retryAfter, 0)
    }
}

/// One step of a change to two-step verification.
public struct TwoFactorStage: Codable, Hashable, Sendable {
    public var done: Bool
    /// phone, disable or recovery.
    public var action: String
    /// current: the phone codes go to now; new: the number being moved to.
    public var stage: String
    public var phoneEnding: String?
    public var codeLength: Int
    public var recoveryAllowed: Bool
    public var sent: Bool
    public var resendIn: Int
    public var expiresIn: Int?
    public var error: StageProblem?
    public var enabled: Bool?
    public var recoveryCodes: [String]?
    public var recoveryCodesLeft: Int?

    public init(done: Bool = false, action: String = "", stage: String = "", phoneEnding: String? = nil,
                codeLength: Int = 6, recoveryAllowed: Bool = false, sent: Bool = false, resendIn: Int = 0,
                expiresIn: Int? = nil, error: StageProblem? = nil, enabled: Bool? = nil,
                recoveryCodes: [String]? = nil, recoveryCodesLeft: Int? = nil) {
        self.done = done
        self.action = action
        self.stage = stage
        self.phoneEnding = phoneEnding
        self.codeLength = codeLength
        self.recoveryAllowed = recoveryAllowed
        self.sent = sent
        self.resendIn = resendIn
        self.expiresIn = expiresIn
        self.error = error
        self.enabled = enabled
        self.recoveryCodes = recoveryCodes
        self.recoveryCodesLeft = recoveryCodesLeft
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = c.value(.done, false)
        action = c.value(.action, "")
        stage = c.value(.stage, "")
        phoneEnding = c.optional(.phoneEnding)
        codeLength = c.value(.codeLength, 6)
        recoveryAllowed = c.value(.recoveryAllowed, false)
        sent = c.value(.sent, false)
        resendIn = c.value(.resendIn, 0)
        expiresIn = c.optional(.expiresIn)
        error = c.optional(.error)
        enabled = c.optional(.enabled)
        recoveryCodes = c.optional(.recoveryCodes)
        recoveryCodesLeft = c.optional(.recoveryCodesLeft)
    }
}

public struct SearchResult: Codable, Sendable {
    public var query: String
    public var results: [FileEntry]
    /// A cap was reached, so this is not the whole answer.
    public var truncated: Bool
    /// The server stopped for time: the same request again carries on.
    public var incomplete: Bool
    public var scanned: Int

    public init(query: String = "", results: [FileEntry] = [], truncated: Bool = false, incomplete: Bool = false, scanned: Int = 0) {
        self.query = query
        self.results = results
        self.truncated = truncated
        self.incomplete = incomplete
        self.scanned = scanned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = c.value(.query, "")
        results = c.value(.results, [])
        truncated = c.value(.truncated, false)
        incomplete = c.value(.incomplete, false)
        scanned = c.value(.scanned, 0)
    }
}

public struct UploadStatus: Codable, Sendable {
    public var id: String
    public var name: String
    public var size: Int64
    /// What the server actually holds. A resume continues from here.
    public var received: Int64
    public var complete: Bool
    public var chunkBytes: Int64

    public init(id: String = "", name: String = "", size: Int64 = 0, received: Int64 = 0,
                complete: Bool = false, chunkBytes: Int64 = 8 * 1024 * 1024) {
        self.id = id
        self.name = name
        self.size = size
        self.received = received
        self.complete = complete
        self.chunkBytes = chunkBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        name = c.value(.name, "")
        size = c.value(.size, Int64(0))
        received = c.value(.received, Int64(0))
        complete = c.value(.complete, false)
        chunkBytes = c.value(.chunkBytes, Int64(8 * 1024 * 1024))
    }
}

public struct UploadComplete: Codable, Sendable {
    public var success: Bool
    public var name: String
    public var path: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = c.value(.success, false)
        name = c.value(.name, "")
        path = c.value(.path, "")
    }
}

public struct TrashEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var originalPath: String
    public var isDirectory: Bool
    public var bytes: Int64
    public var files: Int
    public var deletedAt: String
    public var deletedBy: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        name = c.value(.name, "")
        originalPath = c.value(.originalPath, "")
        isDirectory = c.value(.isDirectory, false)
        bytes = c.value(.bytes, Int64(0))
        files = c.value(.files, 0)
        deletedAt = c.value(.deletedAt, "")
        deletedBy = c.optional(.deletedBy)
    }
}

public struct TrashListing: Codable, Sendable {
    public var enabled: Bool
    public var retentionDays: Int
    public var entries: [TrashEntry]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, true)
        retentionDays = c.value(.retentionDays, 0)
        entries = c.value(.entries, [])
    }
}

/// One subtitle file found beside a video. Always fetched as WebVTT.
public struct SubtitleTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var name: String
    public var label: String
    public var language: String
    public var forced: Bool
    public var url: String

    public init(id: String = "", path: String = "", name: String = "", label: String = "",
                language: String = "", forced: Bool = false, url: String = "") {
        self.id = id
        self.path = path
        self.name = name
        self.label = label
        self.language = language
        self.forced = forced
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        path = c.value(.path, "")
        name = c.value(.name, "")
        label = c.value(.label, "")
        language = c.value(.language, "")
        forced = c.value(.forced, false)
        url = c.value(.url, "")
    }
}

public struct SubtitleListing: Codable, Sendable {
    public var path: String
    public var tracks: [SubtitleTrack]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.value(.path, "")
        tracks = c.value(.tracks, [])
    }
}

public struct ShareLink: Codable, Hashable, Sendable {
    public var token: String
    public var url: String
    public var name: String
    public var kind: String
    public var expiresAt: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = c.value(.token, "")
        url = c.value(.url, "")
        name = c.value(.name, "")
        kind = c.value(.kind, "")
        expiresAt = c.optional(.expiresAt)
    }
}

/// The account's favorites, most recently starred first; each an ordinary listing row.
public struct FavoritesListing: Codable, Sendable {
    public var favorites: [FileEntry]
    public var limit: Int

    public init(favorites: [FileEntry] = [], limit: Int = 0) {
        self.favorites = favorites
        self.limit = limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = c.value(.favorites, [])
        limit = c.value(.limit, 0)
    }
}

public struct FavoriteResult: Codable, Sendable {
    public var success: Bool
    public var favorite: Bool
    public var path: String
    public var message: String

    public init(success: Bool = true, favorite: Bool = false, path: String = "", message: String = "") {
        self.success = success
        self.favorite = favorite
        self.path = path
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = c.value(.success, false)
        favorite = c.value(.favorite, false)
        path = c.value(.path, "")
        message = c.value(.message, "")
    }
}

public struct SimpleResult: Codable, Sendable {
    public var success: Bool
    public var message: String
    public var trashed: Bool
    /// A delete into the trash: the entry that restores it, which is what Undo needs.
    public var id: String?
    /// A rename or a restore: where the file is now -- not always where it was asked to go.
    public var path: String?
    public var name: String?

    public init(success: Bool = true, message: String = "", trashed: Bool = false,
                id: String? = nil, path: String? = nil, name: String? = nil) {
        self.success = success
        self.message = message
        self.trashed = trashed
        self.id = id
        self.path = path
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = c.value(.success, false)
        message = c.value(.message, "")
        trashed = c.value(.trashed, false)
        id = c.optional(.id)
        path = c.optional(.path)
        name = c.optional(.name)
    }
}

/// A bulk move or copy: partial success is reported per item, never hidden.
public struct RelocateResult: Codable, Sendable {
    public struct Failure: Codable, Sendable {
        public var path: String
        public var message: String

        public init(path: String = "", message: String = "") {
            self.path = path
            self.message = message
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = c.value(.path, "")
            message = c.value(.message, "")
        }
    }

    public var success: Bool
    public var completed: Int
    public var failed: [Failure]

    public init(success: Bool = true, completed: Int = 0, failed: [Failure] = []) {
        self.success = success
        self.completed = completed
        self.failed = failed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = c.value(.success, false)
        completed = c.value(.completed, 0)
        failed = c.value(.failed, [])
    }
}

public struct ServerConfigInfo: Codable, Sendable {
    public var readOnly: Bool
    public var allowDelete: Bool
    public var allowOverwrite: Bool
    public var maxUploadMb: Int
    public var maxUploadFiles: Int
    public var chunkMb: Int
    /// The duplicate finder's limits -- and their absence says this build has none.
    public var duplicateMinBytes: Int64?
    public var duplicateScanSeconds: Int?
    public var duplicateMaxFiles: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        readOnly = c.value(.readOnly, false)
        allowDelete = c.value(.allowDelete, true)
        allowOverwrite = c.value(.allowOverwrite, true)
        maxUploadMb = c.value(.maxUploadMb, 2048)
        maxUploadFiles = c.value(.maxUploadFiles, 20)
        chunkMb = c.value(.chunkMb, 8)
        duplicateMinBytes = c.optional(.duplicateMinBytes)
        duplicateScanSeconds = c.optional(.duplicateScanSeconds)
        duplicateMaxFiles = c.optional(.duplicateMaxFiles)
    }
}

public struct StorageBucket: Codable, Hashable, Sendable {
    public var bytes: Int64
    public var files: Int
    public var entries: Int

    public init(bytes: Int64 = 0, files: Int = 0, entries: Int = 0) {
        self.bytes = bytes
        self.files = files
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = c.value(.bytes, Int64(0))
        files = c.value(.files, 0)
        entries = c.value(.entries, 0)
    }
}

/// What one account is using, from /api/storage/me -- readable by anyone.
public struct MyStorage: Codable, Sendable {
    public var usedBytes: Int64
    public var quotaBytes: Int64
    public var storeUsedBytes: Int64
    public var storageLimitBytes: Int64
    public var diskFreeBytes: Int64
    public var diskTotalBytes: Int64
    public var files: Int
    public var folders: Int
    public var trash: StorageBucket
    public var versions: StorageBucket
    public var cached: Bool
    public var measuredAt: String?
    public var isAdmin: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usedBytes = c.value(.usedBytes, Int64(0))
        quotaBytes = c.value(.quotaBytes, Int64(0))
        storeUsedBytes = c.value(.storeUsedBytes, Int64(0))
        storageLimitBytes = c.value(.storageLimitBytes, Int64(0))
        diskFreeBytes = c.value(.diskFreeBytes, Int64(0))
        diskTotalBytes = c.value(.diskTotalBytes, Int64(0))
        files = c.value(.files, 0)
        folders = c.value(.folders, 0)
        trash = c.value(.trash, StorageBucket())
        versions = c.value(.versions, StorageBucket())
        cached = c.value(.cached, false)
        measuredAt = c.optional(.measuredAt)
        isAdmin = c.value(.isAdmin, false)
    }
}

public struct AccountUsage: Codable, Hashable, Sendable {
    public var userId: Int?
    public var username: String?
    public var bytes: Int64
    public var files: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.optional(.userId)
        username = c.optional(.username)
        bytes = c.value(.bytes, Int64(0))
        files = c.value(.files, 0)
    }
}

public struct LargestFile: Codable, Hashable, Sendable {
    public var path: String
    public var bytes: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.value(.path, "")
        bytes = c.value(.bytes, Int64(0))
    }
}

/// The whole-server report from /api/storage/usage. Admins only.
///
/// `folders` is sent as a list of per-folder rows, not a count, and is not
/// modelled: the Android client learned that the hard way.
public struct ServerStorage: Codable, Sendable {
    public var bytes: Int64
    public var files: Int
    public var diskFree: Int64
    public var diskTotal: Int64
    public var trash: StorageBucket
    public var versions: StorageBucket
    public var storageLimitBytes: Int64
    public var userQuotaBytes: Int64
    public var cached: Bool
    public var measuredAt: String?
    public var byUser: [AccountUsage]
    public var largest: [LargestFile]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = c.value(.bytes, Int64(0))
        files = c.value(.files, 0)
        diskFree = c.value(.diskFree, Int64(0))
        diskTotal = c.value(.diskTotal, Int64(0))
        trash = c.value(.trash, StorageBucket())
        versions = c.value(.versions, StorageBucket())
        storageLimitBytes = c.value(.storageLimitBytes, Int64(0))
        userQuotaBytes = c.value(.userQuotaBytes, Int64(0))
        cached = c.value(.cached, false)
        measuredAt = c.optional(.measuredAt)
        byUser = c.value(.byUser, [])
        largest = c.value(.largest, [])
    }
}

/// One slice of a duplicate scan -- or, once `done`, its result.
public struct DuplicateScan: Codable, Sendable {
    public var path: String
    public var scope: String?
    public var done: Bool
    /// Present, and false, only in a GET before anything has been scanned.
    public var started: Bool
    public var scanned: Int
    public var candidates: Int
    public var hashed: Int
    public var computed: Int
    public var toHash: Int
    public var truncated: Bool
    public var groups: [DuplicateGroup]
    public var duplicateFiles: Int
    public var reclaimable: Int64
    public var startedAt: String?
    public var finishedAt: String?

    public init(path: String = "/", scope: String? = nil, done: Bool = false, started: Bool = true,
                scanned: Int = 0, candidates: Int = 0, hashed: Int = 0, computed: Int = 0, toHash: Int = 0,
                truncated: Bool = false, groups: [DuplicateGroup] = [], duplicateFiles: Int = 0,
                reclaimable: Int64 = 0, startedAt: String? = nil, finishedAt: String? = nil) {
        self.path = path
        self.scope = scope
        self.done = done
        self.started = started
        self.scanned = scanned
        self.candidates = candidates
        self.hashed = hashed
        self.computed = computed
        self.toHash = toHash
        self.truncated = truncated
        self.groups = groups
        self.duplicateFiles = duplicateFiles
        self.reclaimable = reclaimable
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.value(.path, "/")
        scope = c.optional(.scope)
        done = c.value(.done, false)
        started = c.value(.started, true)
        scanned = c.value(.scanned, 0)
        candidates = c.value(.candidates, 0)
        hashed = c.value(.hashed, 0)
        computed = c.value(.computed, 0)
        toHash = c.value(.toHash, 0)
        truncated = c.value(.truncated, false)
        groups = c.value(.groups, [])
        duplicateFiles = c.value(.duplicateFiles, 0)
        reclaimable = c.value(.reclaimable, Int64(0))
        startedAt = c.optional(.startedAt)
        finishedAt = c.optional(.finishedAt)
    }
}

/// One set of files that are byte-for-byte the same.
public struct DuplicateGroup: Codable, Hashable, Sendable {
    public var bytes: Int64
    public var count: Int
    public var reclaimable: Int64
    public var files: [DuplicateFile]
    /// "image", "video", "document", "audio", "archive" or "other"; nil from older servers.
    public var kind: String?

    public init(bytes: Int64 = 0, count: Int = 0, reclaimable: Int64 = 0, files: [DuplicateFile] = [], kind: String? = nil) {
        self.bytes = bytes
        self.count = count
        self.reclaimable = reclaimable
        self.files = files
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bytes = c.value(.bytes, Int64(0))
        count = c.value(.count, 0)
        reclaimable = c.value(.reclaimable, Int64(0))
        files = c.value(.files, [])
        kind = c.optional(.kind)
    }
}

/// One copy. The path is all the server sends.
public struct DuplicateFile: Codable, Hashable, Sendable {
    public var path: String
    public var bytes: Int64
    /// Seconds since the epoch.
    public var mtime: Int64

    public init(path: String = "", bytes: Int64 = 0, mtime: Int64 = 0) {
        self.path = path
        self.bytes = bytes
        self.mtime = mtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.value(.path, "")
        bytes = c.value(.bytes, Int64(0))
        mtime = c.value(.mtime, Int64(0))
    }
}
