import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one request. The app's is a URLSession that carries the session
/// cookie and the certificate decisions; tests use a fake.
///
/// A transport must not follow a redirect for anything but a GET -- the app's
/// refuses them -- so that a POST bounced to a GET reaches the API as the 3xx
/// it really was rather than as a misleading 404.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A thread-safe box, for the two values every request reads and sign-in writes.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// One function per endpoint the app uses.
///
/// Every call is addressed in the portable front-controller form the web
/// client uses -- `{base}/?route=%2Fapi%2Ffiles%2Flist&path=...` -- which works
/// whether or not the deployment has URL rewriting configured.
public final class CloudHubAPI: @unchecked Sendable {
    private let base: Locked<String>
    private let csrf = Locked("")
    private let transport: HTTPTransport

    public init(baseURL: String, transport: HTTPTransport) {
        self.base = Locked(baseURL)
        self.transport = transport
    }

    public var baseURL: String {
        get { base.get() }
        set { base.set(newValue) }
    }

    /// Set by status and sign-in; sent on every mutating request.
    public var csrfToken: String {
        get { csrf.get() }
        set { csrf.set(newValue) }
    }

    /* ---- URLs ---------------------------------------------------------- */

    /// Public so the image loader and the player can build authenticated URLs.
    ///
    /// The trailing slash is not cosmetic: the front controller is a directory,
    /// and asking for it without the slash makes a web server answer 301 --
    /// which turns every write into a GET on a subdirectory install.
    public func url(_ route: String, _ query: [(String, String?)] = []) -> URL {
        var front = baseURL
        if !front.hasSuffix("/") { front += "/" }
        var items: [(String, String)] = [("route", route)]
        for (key, value) in query { if let value { items.append((key, value)) } }
        return URL(string: front + "?" + QueryEncoding.query(items))!
    }

    public func thumbnailURL(_ entry: FileEntry) -> URL {
        url("/api/thumbnail", [("path", entry.path), ("v", entry.modified)])
    }

    /// For a path with no listing row behind it, as on the duplicates screen.
    public func thumbnailURL(path: String) -> URL { url("/api/thumbnail", [("path", path)]) }

    public func streamURL(_ path: String) -> URL { url("/api/files/stream", [("path", path)]) }

    public func downloadURL(_ path: String) -> URL { url("/api/files/download", [("path", path)]) }

    /// `version` -- the listing's modified time -- changes the URL when the
    /// file does, so a cache keyed on the URL never serves a replaced file's
    /// old bytes. The server ignores it.
    public func previewURL(_ path: String, version: String? = nil) -> URL {
        url("/api/files/preview", [("path", path), ("v", version)])
    }

    public func subtitleURL(_ path: String) -> URL { url("/api/files/subtitle", [("path", path)]) }

    /* ---- auth ---------------------------------------------------------- */

    public func status() async throws -> AuthStatus {
        let s: AuthStatus = try await get("/api/auth/status")
        csrfToken = s.csrfToken
        return s
    }

    /// Sign in with a password.
    ///
    /// For an account with two-step verification a right password answers 401
    /// TWO_FACTOR_REQUIRED with a session that is not signed in yet. That comes
    /// back as a LoginResult carrying `twoFactor`, because it is the next step,
    /// not a failure.
    public func login(username: String, password: String) async throws -> LoginResult {
        let request = try jsonRequest("/api/auth/login", method: "POST",
                                      body: ["username": username, "password": password])
        let result: LoginResult = try await execute(request) { status, data in
            guard status == 401, let r = try? JSONDecoder().decode(LoginResult.self, from: data),
                  r.twoFactor != nil, !r.csrfToken.isEmpty else { return nil }
            return r
        }
        csrfToken = result.csrfToken
        return result
    }

    public func logout() async throws -> SimpleResult { try await post("/api/auth/logout", [:]) }

    /// Text a code to the account's phone. Refused for a while after the last one.
    public func sendSignInCode() async throws -> CodeSent { try await post("/api/auth/two-factor/send", [:]) }

    /// Check the texted code; on success the session is signed in, with a new CSRF token.
    public func verifySignIn(code: String) async throws -> LoginResult {
        let r: LoginResult = try await post("/api/auth/two-factor/verify", ["code": code])
        csrfToken = r.csrfToken
        return r
    }

    public func verifySignIn(recoveryCode: String) async throws -> LoginResult {
        let r: LoginResult = try await post("/api/auth/two-factor/verify", ["recoveryCode": recoveryCode])
        csrfToken = r.csrfToken
        return r
    }

    /// Give the waiting sign-in up; a code already sent stops working.
    public func cancelSignIn() async throws -> SimpleResult { try await post("/api/auth/two-factor/cancel", [:]) }

    /* ---- managing two-step verification -------------------------------- */

    public func twoFactor() async throws -> TwoFactorOverview { try await get("/api/users/me/two-factor") }

    /// "phone" turns it on or moves it, "disable" turns it off, "recovery"
    /// replaces the recovery codes.
    public func startTwoFactorChange(action: String, currentPassword: String, phone: String? = nil,
                                     useRecoveryCode: Bool = false) async throws -> TwoFactorStage {
        var body: [String: Any] = [
            "action": action,
            "currentPassword": currentPassword,
            "method": useRecoveryCode ? "recovery" : "sms",
        ]
        if let phone { body["phone"] = phone }
        return try await post("/api/users/me/two-factor/start", body)
    }

    public func resendTwoFactorCode() async throws -> TwoFactorStage {
        try await post("/api/users/me/two-factor/resend", [:])
    }

    public func confirmTwoFactorChange(code: String) async throws -> TwoFactorStage {
        try await post("/api/users/me/two-factor/confirm", ["code": code])
    }

    public func confirmTwoFactorChange(recoveryCode: String) async throws -> TwoFactorStage {
        try await post("/api/users/me/two-factor/confirm", ["recoveryCode": recoveryCode])
    }

    public func cancelTwoFactorChange() async throws -> SimpleResult {
        try await post("/api/users/me/two-factor/cancel", [:])
    }

    public func config() async throws -> ServerConfigInfo { try await get("/api/files/config") }

    /// Change the signed-in account's own password. Open to every role.
    public func changePassword(current: String, replacement: String) async throws -> SimpleResult {
        try await post("/api/users/me/password", ["currentPassword": current, "newPassword": replacement])
    }

    /* ---- storage ------------------------------------------------------- */

    public func myStorage() async throws -> MyStorage { try await get("/api/storage/me") }

    /// Admins only, and the only place a fresh measurement can be asked for.
    public func serverStorage(refresh: Bool = false) async throws -> ServerStorage {
        try await get("/api/storage/usage", refresh ? [("refresh", "1")] : [])
    }

    /* ---- duplicates ---------------------------------------------------- */

    /// Start again from the beginning, and do the first slice of the work.
    public func startDuplicateScan(path: String = "/") async throws -> DuplicateScan {
        try await post("/api/duplicates/scan", ["path": path, "restart": true])
    }

    /// Carry on. Repeat while the reply says `done` is false.
    public func continueDuplicateScan(path: String = "/") async throws -> DuplicateScan {
        try await post("/api/duplicates/scan", ["path": path])
    }

    /// What the last scan found, without doing any work.
    public func lastDuplicateScan() async throws -> DuplicateScan { try await get("/api/duplicates/scan") }

    public func forgetDuplicateScan() async throws -> SimpleResult {
        try await send("/api/duplicates/scan", method: "DELETE", [:])
    }

    /* ---- browsing ------------------------------------------------------ */

    public func list(_ path: String) async throws -> [FileEntry] {
        try await get("/api/files/list", [("path", path)])
    }

    /// `budgetMs` asks the server to answer with what it has found after that
    /// long; see SearchResult.incomplete. A server without it ignores it.
    public func search(_ query: String, under: String = "/", budgetMs: Int? = nil) async throws -> SearchResult {
        try await get("/api/files/search", [("q", query), ("path", under), ("budget", budgetMs.map(String.init))])
    }

    /* ---- changing things ----------------------------------------------- */

    public func makeFolder(_ path: String) async throws -> SimpleResult {
        try await post("/api/files/mkdir", ["path": path])
    }

    public func rename(from: String, to: String) async throws -> SimpleResult {
        try await post("/api/files/rename", ["oldPath": from, "newPath": to])
    }

    public func move(_ paths: [String], to destination: String) async throws -> RelocateResult {
        try await post("/api/files/move", ["destination": destination, "paths": paths])
    }

    public func copy(_ paths: [String], to destination: String) async throws -> RelocateResult {
        try await post("/api/files/copy", ["destination": destination, "paths": paths])
    }

    /// Goes to the trash unless the server has it disabled; the reply says which.
    public func delete(_ path: String) async throws -> SimpleResult {
        try await send("/api/files/delete", method: "DELETE", ["path": path])
    }

    /* ---- trash --------------------------------------------------------- */

    public func trash() async throws -> TrashListing { try await get("/api/trash") }

    public func restore(_ id: String) async throws -> SimpleResult { try await post("/api/trash/restore", ["id": id]) }

    public func purge(_ id: String) async throws -> SimpleResult { try await post("/api/trash/purge", ["id": id]) }

    public func emptyTrash() async throws -> SimpleResult { try await post("/api/trash/purge", ["all": true]) }

    /* ---- favorites ----------------------------------------------------- */

    public func favorites() async throws -> FavoritesListing { try await get("/api/favorites") }

    public func addFavorite(_ path: String) async throws -> FavoriteResult {
        try await post("/api/favorites", ["path": path])
    }

    public func removeFavorite(_ path: String) async throws -> FavoriteResult {
        try await send("/api/favorites", method: "DELETE", ["path": path])
    }

    /* ---- share links --------------------------------------------------- */

    public func createShare(_ path: String, expiresInHours: Int?) async throws -> ShareLink {
        var body: [String: Any] = ["filePath": path]
        if let expiresInHours { body["expiresInHours"] = expiresInHours }
        return try await post("/api/shares/create", body)
    }

    /// Revoke by token: a link outlives renames, so the token is its identity.
    public func revokeShare(_ token: String) async throws -> SimpleResult {
        try await send("/api/shares/revoke", method: "DELETE", ["token": token])
    }

    /* ---- uploads ------------------------------------------------------- */

    public func uploadInit(id: String, targetPath: String, name: String, size: Int64) async throws -> UploadStatus {
        try await post("/api/uploads/init", [
            "uploadId": id, "targetPath": targetPath, "name": name, "size": size, "conflict": "rename",
        ])
    }

    public func uploadStatus(id: String) async throws -> UploadStatus {
        try await get("/api/uploads/status", [("id", id)])
    }

    /// Send one chunk from the given offset.
    public func uploadChunk(id: String, offset: Int64, body: Data) async throws -> UploadStatus {
        var request = URLRequest(url: url("/api/uploads/chunk", [("id", id)]))
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "X-Upload-Offset")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        request.timeoutInterval = 300
        return try await execute(request)
    }

    public func uploadComplete(id: String) async throws -> UploadComplete {
        try await post("/api/uploads/complete", ["id": id])
    }

    public func uploadCancel(id: String) async throws -> SimpleResult {
        try await send("/api/uploads/cancel", method: "DELETE", ["id": id])
    }

    /// Hand a locally decoded video frame back, so the web app benefits too.
    public func contributeVideoThumbnail(path: String, imageBase64: String) async throws -> SimpleResult {
        try await post("/api/thumbnail/video", ["path": path, "image": imageBase64])
    }

    /// The subtitle files beside a video. Playback never waits on this.
    public func subtitles(_ path: String) async throws -> [SubtitleTrack] {
        let listing: SubtitleListing = try await get("/api/files/subtitles", [("path", path)])
        return listing.tracks
    }

    /// The bytes behind a URL from this API, through the authenticated transport.
    public func fetch(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ApiError.from(status: response.statusCode, body: data, headers: headerMap(response))
        }
        return (data, response)
    }

    /* ---- plumbing ------------------------------------------------------ */

    private func get<T: Decodable>(_ route: String, _ query: [(String, String?)] = []) async throws -> T {
        var request = URLRequest(url: url(route, query))
        request.httpMethod = "GET"
        return try await execute(request)
    }

    private func post<T: Decodable>(_ route: String, _ body: [String: Any]) async throws -> T {
        try await send(route, method: "POST", body)
    }

    private func send<T: Decodable>(_ route: String, method: String, _ body: [String: Any]) async throws -> T {
        try await execute(try jsonRequest(route, method: method, body: body))
    }

    private func jsonRequest(_ route: String, method: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url(route))
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Every mutating route verifies this (Auth::verifyCsrf()).
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        return request
    }

    /// `onRefused` may turn a refusal into an answer -- sign-in's
    /// TWO_FACTOR_REQUIRED is a 401 that is really the next step.
    private func execute<T: Decodable>(
        _ request: URLRequest,
        onRefused: ((Int, Data) -> T?)? = nil
    ) async throws -> T {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            // A redirect drops a write; name the real problem instead of a 404.
            if (300..<400).contains(status) {
                throw ApiError(
                    status: status, code: "REDIRECTED",
                    message: "The server redirected this request, which drops it. Check the server address is exactly right.",
                    requestId: response.value(forHTTPHeaderField: "X-Request-ID")
                )
            }
            if let answer = onRefused?(status, data) { return answer }
            throw ApiError.from(status: status, body: data, headers: headerMap(response))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError(status: status, code: "BAD_RESPONSE",
                           message: "The server sent an answer this app could not read. Is this a CloudHub server?")
        }
    }

    private func headerMap(_ response: HTTPURLResponse) -> [String: String] {
        var map: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String, let v = v as? String { map[k] = v }
        }
        return map
    }
}
