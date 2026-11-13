import Foundation

/// Turn a typed address into the base URL every request is built from.
///
/// People type "files.example.com", "https://files.example.com/" and
/// ".../index.php" and mean the same server. Returns nil when nothing usable
/// is left, so the caller can say so rather than failing later.
public enum ServerAddress {
    public static func normalise(_ input: String?) -> String? {
        guard var url = input?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        if url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil {
            url = "https://" + url
        }
        while url.hasSuffix("/") { url.removeLast() }
        if url.lowercased().hasSuffix("/index.php") { url.removeLast(10) }
        return canonical(url)
    }

    public static func isInsecure(_ url: String) -> Bool {
        url.lowercased().hasPrefix("http://")
    }

    /// One spelling per server: a lower-case scheme and host, default ports
    /// dropped, and the path percent-encoded exactly once -- a typed space and
    /// a typed %20 become the same value.
    static func canonical(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let scheme = url[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        var rest = String(url[schemeEnd.upperBound...])
        // A query or fragment has no place in a server address.
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
        let authority: String
        var path: String
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            path = String(rest[slash...])
        } else {
            authority = rest
            path = ""
        }
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains(" ") else { return nil }
        var host = authority.lowercased()
        if scheme == "https", host.hasSuffix(":443") { host.removeLast(4) }
        if scheme == "http", host.hasSuffix(":80") { host.removeLast(3) }
        guard !host.isEmpty, !host.hasPrefix(":") else { return nil }
        // A port, if any, is digits: "https://ftp://x" is not an address.
        if let colon = host.lastIndex(of: ":"), !host.hasPrefix("[") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isASCIIDigit), host[..<colon].firstIndex(of: ":") == nil else { return nil }
        }

        let decoded = path.removingPercentEncoding ?? path
        path = decoded.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(path)"
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=:@/")
        // Letters outside ASCII are encoded too, as OkHttp does.
        return set.intersection(CharacterSet(charactersIn: Unicode.Scalar(0x21)...Unicode.Scalar(0x7E)))
    }()
}

/// The server address as a person should read it: no scheme, no trailing
/// slash, and percent-escapes decoded -- "Cloud File Hub", not "Cloud%20File%20Hub".
/// Display only; the stored URL is never rewritten from this.
public func displayServer(_ url: String) -> String {
    var trimmed = url.trimmingCharacters(in: .whitespaces)
    for prefix in ["https://", "http://"] where trimmed.hasPrefix(prefix) {
        trimmed.removeFirst(prefix.count)
        break
    }
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    // removingPercentEncoding is not a form decoder, so a literal + stays a +.
    return trimmed.removingPercentEncoding ?? trimmed
}

/// Query-string encoding that leaves nothing for the server to misread.
///
/// URLComponents leaves "+" alone, and PHP reads an unescaped "+" in a query
/// as a space: a file called "a+b.jpg" would be asked for as "a b.jpg".
/// Everything but the unreserved characters is escaped.
enum QueryEncoding {
    static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
