import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CloudHubCore

final class AddressTests: XCTestCase {
    func testNormalise() {
        let cases: [(String, String)] = [
            ("files.example.com", "https://files.example.com"),
            ("https://files.example.com/", "https://files.example.com"),
            ("https://Files.Example.com/index.php", "https://files.example.com"),
            ("http://host:8000/Cloud File Hub", "http://host:8000/Cloud%20File%20Hub"),
            ("http://host:8000/Cloud%20File%20Hub/", "http://host:8000/Cloud%20File%20Hub"),
            ("https://host:443/sub", "https://host/sub"),
        ]
        for (typed, expected) in cases {
            XCTAssertEqual(ServerAddress.normalise(typed), expected, "typed as: \(typed)")
        }
        XCTAssertNil(ServerAddress.normalise(nil))
        XCTAssertNil(ServerAddress.normalise("   "))
        XCTAssertNil(ServerAddress.normalise("ftp://x"))
        XCTAssertTrue(ServerAddress.isInsecure("http://192.168.1.10:8000"))
        XCTAssertFalse(ServerAddress.isInsecure("https://files.example.com"))
    }

    func testDisplayServer() {
        XCTAssertEqual(displayServer("https://example.com/Cloud%20File%20Hub/"), "example.com/Cloud File Hub")
        XCTAssertEqual(displayServer("http://h/a%2Bb"), "h/a+b")
    }

    func testURLsAddressTheFrontController() {
        let api = CloudHubAPI(baseURL: "http://host:8000/Cloud%20File%20Hub", transport: FakeServer())
        let url = api.url("/api/auth/login")
        XCTAssertEqual(url.path.isEmpty ? "/" : URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath,
                       "/Cloud%20File%20Hub/")
        XCTAssertEqual(CloudHubAPI(baseURL: "http://host:8000", transport: FakeServer()).url("/api/files/list").absoluteString,
                       "http://host:8000/?route=%2Fapi%2Ffiles%2Flist")
    }

    func testPlusAndSpacesSurviveTheQuery() {
        let api = CloudHubAPI(baseURL: "https://h", transport: FakeServer())
        let url = api.url("/api/files/list", [("path", "/Photos/a b+c&d.jpg"), ("skip", nil)])
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "path" }?.value, "/Photos/a b+c&d.jpg")
        XCTAssertFalse(url.absoluteString.contains("+"), "a bare + is a space to PHP")
        XCTAssertNil(items.first { $0.name == "skip" })
    }
}

final class APITests: XCTestCase {
    func testErrorEnvelope() {
        let body = #"{"error":{"code":"RATE","message":"Wait a bit","details":{"retryAfter":30,"attemptsLeft":2}},"requestId":"r1"}"#
        let e = ApiError.from(status: 429, body: Data(body.utf8))
        XCTAssertEqual(e.code, "RATE")
        XCTAssertEqual(e.message, "Wait a bit")
        XCTAssertEqual(e.retryAfter, 30)
        XCTAssertEqual(e.attemptsLeft, 2)
        XCTAssertEqual(e.requestId, "r1")
        let proxy = ApiError.from(status: 502, body: Data("<html>".utf8), headers: ["retry-after": " 5"])
        XCTAssertEqual(proxy.message, "The server had a problem handling that.")
        XCTAssertEqual(proxy.retryAfter, 5)
    }

    func testLenientDecoding() throws {
        let raw = #"[{"name":"a.jpg","path":"/a.jpg","isDirectory":false,"size":"oops","extra":1},{"name":"F","path":"/F","isDirectory":true}]"#
        let list = try JSONDecoder().decode([FileEntry].self, from: Data(raw.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].size, 0)
        XCTAssertEqual(list[0].kind, .image)
        XCTAssertEqual(list[1].kind, .folder)
        let storage = #"{"bytes":5,"folders":[{"path":"/x","bytes":1}],"byUser":[{"username":"k","bytes":3}]}"#
        let s = try JSONDecoder().decode(ServerStorage.self, from: Data(storage.utf8))
        XCTAssertEqual(s.byUser.first?.bytes, 3)
    }

    func testLoginCarriesCsrfAndTwoFactorIsAStep() async throws {
        let server = FakeServer()
        server.on("POST", "/api/auth/login") { call in
            XCTAssertEqual(call.body["username"] as? String, "kevin")
            XCTAssertEqual(call.header("X-CSRF-Token"), "t0")
            return (401, ["success": false, "csrfToken": "t1", "twoFactor": ["phoneEnding": "78", "codeLength": 6]])
        }
        let api = CloudHubAPI(baseURL: "https://h", transport: server)
        api.csrfToken = "t0"
        let result = try await api.login(username: "kevin", password: "pw")
        XCTAssertEqual(result.twoFactor?.phoneEnding, "78")
        XCTAssertEqual(api.csrfToken, "t1")
    }

    func testWrongPasswordThrows() async {
        let server = FakeServer()
        server.on("POST", "/api/auth/login") { _ in (401, ["error": ["code": "INVALID", "message": "Invalid username or password"]]) }
        let api = CloudHubAPI(baseURL: "https://h", transport: server)
        do {
            _ = try await api.login(username: "k", password: "x")
            XCTFail("should have thrown")
        } catch let e as ApiError {
            XCTAssertEqual(e.message, "Invalid username or password")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRedirectIsNamed() async {
        let server = FakeServer()
        server.on("DELETE", "/api/files/delete") { _ in (301, [:]) }
        let api = CloudHubAPI(baseURL: "https://h", transport: server)
        do {
            _ = try await api.delete("/a")
            XCTFail("should have thrown")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "REDIRECTED")
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class UploadEngineTests: XCTestCase {
    func testResumesFromWhatTheServerHoldsAndRecordsRefusals() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uq-\(UUID().uuidString)")
        let queue = UploadQueue(directory: dir)
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        try bytes.write(to: queue.stagingDirectory.appendingPathComponent("s1"))
        try Data("x".utf8).write(to: queue.stagingDirectory.appendingPathComponent("s2"))
        queue.add(QueuedUpload(id: "u1", name: "video.mp4", stagedName: "s1", targetPath: "/Films", size: 5000))
        queue.add(QueuedUpload(id: "u2", name: "big.iso", stagedName: "s2", targetPath: "/", size: 1))

        let server = FakeServer()
        let received = Locked(Data(bytes.prefix(1000)))
        server.on("GET", "/api/auth/status") { _ in (200, ["authenticated": true, "csrfToken": "c"]) }
        server.on("POST", "/api/uploads/init") { call in
            if call.body["uploadId"] as? String == "u2" {
                return (507, ["error": ["code": "QUOTA", "message": "Your quota is full"]])
            }
            XCTAssertEqual(call.body["conflict"] as? String, "rename")
            return (200, ["id": "u1", "received": 1000, "chunkBytes": 1500])
        }
        server.on("PUT", "/api/uploads/chunk") { call in
            let offset = Int(call.header("X-Upload-Offset") ?? "") ?? -1
            var held = received.get()
            XCTAssertEqual(offset, held.count, "sent from where the server is")
            held.append(call.raw ?? Data())
            received.set(held)
            return (200, ["id": "u1", "received": held.count, "chunkBytes": 1500])
        }
        server.on("POST", "/api/uploads/complete") { _ in (200, ["success": true]) }

        let api = CloudHubAPI(baseURL: "https://h", transport: server)
        let engine = UploadEngine(api: api, queue: queue, sleep: { _ in })
        let outcome = await engine.run { _ in }

        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(received.get(), bytes)
        XCTAssertEqual(server.calls("/api/uploads/chunk").count, 3, "1000 held, 4000 left in 1500-byte chunks")
        XCTAssertTrue(queue.all().isEmpty)
        XCTAssertEqual(queue.failures().map(\.reason), ["Your quota is full"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.stagingDirectory.appendingPathComponent("s1").path))
    }

    func testNetworkFailureKeepsTheQueue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uq-\(UUID().uuidString)")
        let queue = UploadQueue(directory: dir)
        try Data("abc".utf8).write(to: queue.stagingDirectory.appendingPathComponent("s"))
        queue.add(QueuedUpload(id: "u", name: "a", stagedName: "s", targetPath: "/", size: 3))
        let server = FakeServer()
        server.on("GET", "/api/auth/status") { _ in (200, ["authenticated": true]) }
        server.on("POST", "/api/uploads/init") { _ in throw URLError(.networkConnectionLost) }
        let engine = UploadEngine(api: CloudHubAPI(baseURL: "https://h", transport: server), queue: queue, sleep: { _ in })
        let outcome = await engine.run { _ in }
        XCTAssertEqual(outcome, .retryLater)
        XCTAssertEqual(queue.all().count, 1)
    }
}
