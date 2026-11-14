import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CloudHubCore

/// A server in memory: answers by route, records what was asked.
final class FakeServer: HTTPTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var route: String
        var query: [String: String]
        var body: [String: Any]
        var headers: [String: String]
        var raw: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    typealias Handler = (Call) throws -> (Int, Any)

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private(set) var calls: [Call] = []

    func on(_ method: String, _ route: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers["\(method) \(route)"] = handler
    }

    func calls(_ route: String) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.route == route }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let method = request.httpMethod ?? "GET"
        var body: [String: Any] = [:]
        if let data = request.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = object
        }
        let call = Call(method: method, route: query["route"] ?? "", query: query, body: body,
                        headers: request.allHTTPHeaderFields ?? [:], raw: request.httpBody)
        let handler = record(call)
        guard let handler else {
            return respond(url, 404, ["error": ["code": "NOT_FOUND", "message": "API endpoint not found"]])
        }
        let (status, json) = try handler(call)
        return respond(url, status, json)
    }

    /// Synchronous, so the lock is never held across an await.
    private func record(_ call: Call) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
        return handlers["\(call.method) \(call.route)"]
    }

    private func respond(_ url: URL, _ status: Int, _ json: Any) -> (Data, HTTPURLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

func entry(_ name: String, dir: Bool = false, size: Int64 = 0, modified: String = "", in folder: String = "") -> FileEntry {
    FileEntry(name: name, path: "\(folder)/\(name)", isDirectory: dir, size: size, modified: modified)
}

func json(_ entry: FileEntry) -> [String: Any] {
    ["name": entry.name, "path": entry.path, "isDirectory": entry.isDirectory, "size": entry.size, "modified": entry.modified]
}
