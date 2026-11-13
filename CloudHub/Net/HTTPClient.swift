import CloudHubCore
import CryptoKit
import Foundation
import Security

/// The one URLSession every part of the app shares.
///
/// Shared on purpose: thumbnails and photos are ordinary authenticated
/// requests to the same server, so they need the same cookies and the same
/// certificate decisions as the API. Separate sessions are how you get a file
/// list that loads and thumbnails that all fail with 401.
final class HTTPClient: NSObject, HTTPTransport, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let vault: CookieVault
    private let pins: () -> Set<String>
    /// The last certificate refused per host, so the caller can show it.
    private let refused = NSLock()
    private var refusedByHost: [String: UntrustedCertificate] = [:]
    private(set) var session: URLSession!

    init(vault: CookieVault, pins: @escaping () -> Set<String>) {
        self.vault = vault
        self.pins = pins
        super.init()
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        // Revalidated with the ETag the server sends; thumbnails carry a version in the URL.
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 0)
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            vault.persist()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        } catch {
            if let host = request.url?.host, let untrusted = takeRefusal(host) { throw untrusted }
            throw error
        }
    }

    /// Bytes of a URL streamed to a file, for downloads and Quick Look.
    func download(_ url: URL) async throws -> (URL, HTTPURLResponse) {
        do {
            let (file, response) = try await session.download(from: url)
            vault.persist()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (file, http)
        } catch {
            if let host = url.host, let untrusted = takeRefusal(host) { throw untrusted }
            throw error
        }
    }

    private func takeRefusal(_ host: String) -> UntrustedCertificate? {
        refused.lock(); defer { refused.unlock() }
        return refusedByHost.removeValue(forKey: host)
    }

    /* ---- certificates ---------------------------------------------------
     *
     * A certificate the device does not trust is a question, not a decision:
     *   1. the system gets first refusal, so a properly issued certificate --
     *      or a private CA installed as a profile -- works with no prompt;
     *   2. failing that, the leaf's SHA-256 is checked against what the
     *      person has accepted before;
     *   3. failing that the connection is refused, and the fingerprint kept
     *      so the screen can show it and offer to pin it.
     * Pinning is per certificate, never per host.
     */

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = evaluate(challenge)
        completionHandler(disposition, credential)
    }

    func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return (.useCredential, URLCredential(trust: trust)) }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let fingerprint = Self.fingerprint(of: leaf)
        if pins().contains(fingerprint) { return (.useCredential, URLCredential(trust: trust)) }

        let host = challenge.protectionSpace.host
        let untrusted = UntrustedCertificate(
            host: host,
            fingerprint: fingerprint,
            subject: (SecCertificateCopySubjectSummary(leaf) as String?) ?? host,
            reason: error.map { CFErrorCopyDescription($0) as String } ?? "not signed by a trusted authority"
        )
        refused.lock()
        refusedByHost[host] = untrusted
        refused.unlock()
        return (.cancelAuthenticationChallenge, nil)
    }

    /// Uppercase colon-separated SHA-256, the form certificate tools print.
    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /* ---- redirects --------------------------------------------------------
     *
     * A redirect turns a POST into a GET with the body dropped; the route then
     * matches nothing and the reply is a confusing 404. Writes are not
     * followed, so the API sees the 3xx and can name the real problem.
     */

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let method = task.originalRequest?.httpMethod ?? "GET"
        completionHandler(method == "GET" || method == "HEAD" ? request : nil)
    }
}
