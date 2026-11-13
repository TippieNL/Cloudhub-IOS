import Foundation

/// The server's error envelope, kept as one type so every screen reports failures the same way.
///
/// CloudHub answers every failed request with
/// `{"error":{"code":"...","message":"..."},"requestId":"..."}` (Http::error()).
/// The message is written for a person, so it is shown as-is.
public struct ApiError: Error, LocalizedError, Sendable, Equatable {
    public var status: Int
    public var code: String
    public var message: String
    public var requestId: String?
    /// Seconds before trying again is worth it, from the details or Retry-After.
    public var retryAfter: Int?
    /// Wrong codes the code that was just refused can still take.
    public var attemptsLeft: Int?

    public init(status: Int, code: String, message: String, requestId: String? = nil,
                retryAfter: Int? = nil, attemptsLeft: Int? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.requestId = requestId
        self.retryAfter = retryAfter
        self.attemptsLeft = attemptsLeft
    }

    public var errorDescription: String? { message }

    /// Signing in again is what the caller should do.
    public var isUnauthorized: Bool { status == 401 }
    /// Signed in, but not allowed to do this.
    public var isForbidden: Bool { status == 403 }
    /// The store or the caller's quota is full; retrying will not help.
    public var isOutOfSpace: Bool { status == 507 }

    /// Build from a failed response, falling back when the body is not the envelope.
    public static func from(status: Int, body: Data?, headers: [String: String] = [:]) -> ApiError {
        var code: String?
        var message: String?
        var requestId: String?
        var retryAfter: Int?
        var attemptsLeft: Int?
        if let body, !body.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            requestId = object["requestId"] as? String
            if let error = object["error"] as? [String: Any] {
                code = error["code"] as? String
                message = error["message"] as? String
                if let details = error["details"] as? [String: Any] {
                    retryAfter = intValue(details["retryAfter"])
                    attemptsLeft = intValue(details["attemptsLeft"])
                }
            }
        }
        let header = { (name: String) -> String? in
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        return ApiError(
            status: status,
            code: code ?? "HTTP_\(status)",
            message: message ?? defaultMessage(status),
            requestId: requestId ?? header("X-Request-ID"),
            retryAfter: retryAfter ?? header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            attemptsLeft: attemptsLeft
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    static func defaultMessage(_ status: Int) -> String {
        switch status {
        case 401: return "Please sign in again."
        case 403: return "You do not have permission to do that."
        case 404: return "That file or folder no longer exists."
        case 409: return "Something with that name is already there."
        case 413: return "That file is too large for this server."
        case 419: return "Your session expired. Please sign in again."
        case 507: return "There is not enough space left."
        case 500...599: return "The server had a problem handling that."
        default: return "The request failed (HTTP \(status))."
        }
    }
}

/// A certificate the device does not trust: a question for the person, not a decision.
///
/// Carries the leaf's SHA-256 so the screen can show it and offer to pin it.
/// Pinning is per certificate, never per host.
public struct UntrustedCertificate: Error, LocalizedError, Sendable, Equatable {
    public var host: String
    public var fingerprint: String
    public var subject: String
    public var reason: String

    public init(host: String, fingerprint: String, subject: String, reason: String) {
        self.host = host
        self.fingerprint = fingerprint
        self.subject = subject
        self.reason = reason
    }

    public var errorDescription: String? { "The server's certificate is not trusted (\(reason))." }
}

/// What to show for any error, server or network.
public func describe(_ error: Error, fallback: String = "Could not reach the server.") -> String {
    if let api = error as? ApiError { return api.message }
    if let cert = error as? UntrustedCertificate { return cert.errorDescription ?? fallback }
    if error is CancellationError { return "Cancelled." }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "This device is offline."
        case NSURLErrorTimedOut: return "The server took too long to answer."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "That server could not be found."
        case NSURLErrorCannotConnectToHost: return "The server refused the connection."
        default: break
        }
    }
    return fallback
}
