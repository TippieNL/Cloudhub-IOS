import Foundation
import Security

/// The few bytes that are credentials, kept where credentials belong.
enum Keychain {
    private static let service = "nl.tippie.cloudhub"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, for account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            // Readable once the phone has been unlocked after a restart, so an
            // upload resumed in the background can still sign its requests.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
    }
}

/// The session cookie, kept across launches.
///
/// CloudHub's session cookie has no expiry (PHP's lifetime 0), and iOS drops
/// such cookies when the app exits -- so without this the app would ask for a
/// password every time it was opened. The server rotates the session now and
/// then; whatever arrives in Set-Cookie simply replaces what is held.
final class CookieVault: @unchecked Sendable {
    private struct Stored: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Double?
        var secure: Bool
    }

    private let storage: HTTPCookieStorage
    private let lock = NSLock()
    private static let account = "cookies"

    init(storage: HTTPCookieStorage = .shared) {
        self.storage = storage
        restore()
    }

    private func restore() {
        guard let data = Keychain.read(Self.account),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        for s in stored where (s.expires ?? .infinity) > now {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: s.name, .value: s.value, .domain: s.domain, .path: s.path,
            ]
            if let expires = s.expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if s.secure { properties[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) { storage.setCookie(cookie) }
        }
    }

    /// Called after every response; cheap when nothing changed.
    func persist() {
        lock.lock(); defer { lock.unlock() }
        let cookies = (storage.cookies ?? []).map {
            Stored(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                   expires: $0.expiresDate?.timeIntervalSince1970, secure: $0.isSecure)
        }
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        if Keychain.read(Self.account) != data { Keychain.write(data, for: Self.account) }
    }

    /// Signing out: the server's session is over, and so is ours.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
        Keychain.delete(Self.account)
    }

    func cookies(for url: URL) -> [HTTPCookie] { storage.cookies(for: url) ?? [] }
}
