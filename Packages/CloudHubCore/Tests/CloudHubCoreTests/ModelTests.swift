import XCTest
@testable import CloudHubCore

/// Scripted calls for the sign-in and two-factor state machines.
final class ScriptedSignIn: SignInCalls, @unchecked Sendable {
    var loginResult: Result<LoginResult, Error> = .success(LoginResult(success: true))
    var sendResult: Result<CodeSent, Error> = .success(CodeSent(sent: true, phoneEnding: "78", expiresIn: 300, resendIn: 60))
    var verifyResult: Result<LoginResult, Error> = .success(LoginResult(success: true))
    var logins = 0
    var sends = 0
    var cancels = 0

    func login(_ username: String, _ password: String) async throws -> LoginResult { logins += 1; return try loginResult.get() }
    func send() async throws -> CodeSent { sends += 1; return try sendResult.get() }
    func verify(_ code: String) async throws -> LoginResult { try verifyResult.get() }
    func verifyRecoveryCode(_ code: String) async throws -> LoginResult { try verifyResult.get() }
    func cancel() async throws { cancels += 1 }
}

@MainActor
final class SignInModelTests: XCTestCase {
    var now = 1000.0

    func make(_ calls: ScriptedSignIn) -> SignInModel { SignInModel(calls: calls, clock: { [unowned self] in self.now }) }

    func testValidationNamesTheField() {
        let model = make(ScriptedSignIn())
        model.submit(username: "  ", password: "x")
        XCTAssertEqual(model.state, .failed(SignInError("Enter your username.", field: .username)))
        model.failureShown()
        model.submit(username: "kevin ", password: "")
        XCTAssertEqual(model.state, .failed(SignInError("Enter your password.", field: .password)))
    }

    func testDoubleSubmitSendsOnce() async {
        let calls = ScriptedSignIn()
        let model = make(calls)
        model.submit(username: "k", password: "p")
        model.submit(username: "k", password: "p")
        await model.pending?.value
        XCTAssertEqual(calls.logins, 1)
        XCTAssertEqual(model.state, .success)
    }

    func testRightPasswordOpensTheCodeStepAndSendsOnce() async {
        let calls = ScriptedSignIn()
        calls.loginResult = .success(LoginResult(success: false, csrfToken: "t", twoFactor: SecondStep(phoneEnding: "12")))
        let model = make(calls)
        model.submit(username: "k", password: "p")
        await model.pending?.value
        await model.pending?.value
        XCTAssertEqual(calls.sends, 1)
        XCTAssertEqual(model.codeStep?.phoneEnding, "78")
        XCTAssertEqual(model.codeStep?.resendWait(now: now), 60)
        XCTAssertFalse(model.codeStep!.canResend(now: now))
        now += 61
        XCTAssertTrue(model.codeStep!.canResend(now: now))
    }

    func testWrongCodeIsCountedAndExpiryGoesBack() async {
        let calls = ScriptedSignIn()
        calls.loginResult = .success(LoginResult(twoFactor: SecondStep(codeSent: true, resendIn: 0)))
        calls.verifyResult = .failure(ApiError(status: 422, code: "BAD", message: "Wrong code; 2 tries left"))
        let model = make(calls)
        model.submit(username: "k", password: "p")
        await model.pending?.value
        model.verify("12 34 56.")
        await model.pending?.value
        XCTAssertEqual(model.codeStep?.rejected, 1)
        XCTAssertEqual(model.codeStep?.error, "Wrong code; 2 tries left")

        calls.verifyResult = .failure(ApiError(status: 401, code: "TWO_FACTOR_EXPIRED", message: "Sign in again"))
        model.verify("123456")
        await model.pending?.value
        XCTAssertEqual(model.state, .failed(SignInError("Sign in again", field: .password)))
    }

    func testNoSmsMeansRecoveryOnly() {
        let model = make(ScriptedSignIn())
        model.resume(SecondStep(smsAvailable: false))
        XCTAssertEqual(model.codeStep?.recovery, true)
        model.switchMethod()
        XCTAssertEqual(model.codeStep?.recovery, true, "no texted code to switch to")
    }

    func testCodeCleaning() {
        XCTAssertEqual(CodeInput.clean(" 12-34 56. ", recovery: false, length: 6), "123456")
        XCTAssertEqual(CodeInput.clean("1234567", recovery: false, length: 6), "123456")
        XCTAssertEqual(CodeInput.clean("abcd-efgh", recovery: true, length: 6), "abcd-efgh")
        XCTAssertTrue(CodeInput.complete("123456", recovery: false, length: 6))
        XCTAssertFalse(CodeInput.complete("123456", recovery: true, length: 6))
    }
}

final class ScriptedTwoFactor: TwoFactorCalls, @unchecked Sendable {
    var overviewValue = TwoFactorOverview(available: true, smsAvailable: true)
    var startResult: Result<TwoFactorStage, Error> = .success(TwoFactorStage(action: "phone", stage: "new", phoneEnding: "99", sent: true, resendIn: 30))
    var confirms: [Result<TwoFactorStage, Error>] = []

    func overview() async throws -> TwoFactorOverview { overviewValue }
    func start(action: String, password: String, phone: String?, useRecoveryCode: Bool) async throws -> TwoFactorStage { try startResult.get() }
    func resend() async throws -> TwoFactorStage { try startResult.get() }
    func confirm(_ code: String) async throws -> TwoFactorStage { try confirms.removeFirst().get() }
    func confirmRecoveryCode(_ code: String) async throws -> TwoFactorStage { try confirms.removeFirst().get() }
    func cancel() async throws {}
}

@MainActor
final class TwoFactorModelTests: XCTestCase {
    func testTurningOnShowsTheCodesOnce() async {
        let calls = ScriptedTwoFactor()
        calls.confirms = [.success(TwoFactorStage(done: true, enabled: true, recoveryCodes: ["a", "b"]))]
        let model = TwoFactorModel(calls: calls, clock: { 0 })
        model.open()
        await model.pending?.value
        model.begin(.turnOn)
        model.submitStart(password: "pw", phone: "")
        XCTAssertEqual(model.message?.isError, true, "a number is needed")
        model.submitStart(password: "pw", phone: "+31600000000")
        await model.pending?.value
        guard case .code(let code) = model.step else { return XCTFail("\(model.step)") }
        XCTAssertEqual(code.resendWait(now: 0), 30)
        model.confirm("123456")
        await model.pending?.value
        XCTAssertEqual(model.step, .codes(["a", "b"]))
        model.codesSaved()
        XCTAssertEqual(model.step, .summary)
    }

    func testMovingNumberTakesTwoCodes() async {
        let calls = ScriptedTwoFactor()
        calls.overviewValue.enabled = true
        calls.startResult = .success(TwoFactorStage(action: "phone", stage: "current", phoneEnding: "11", recoveryAllowed: true, sent: true))
        calls.confirms = [
            .success(TwoFactorStage(action: "phone", stage: "new", phoneEnding: "22", sent: true)),
            .success(TwoFactorStage(done: true, phoneEnding: "22", enabled: true)),
        ]
        let model = TwoFactorModel(calls: calls, clock: { 0 })
        model.open()
        await model.pending?.value
        model.begin(.changePhone)
        model.submitStart(password: "pw", phone: "+3162")
        await model.pending?.value
        model.confirm("111111")
        await model.pending?.value
        guard case .code(let second) = model.step else { return XCTFail() }
        XCTAssertEqual(second.stage.stage, "new")
        model.confirm("222222")
        await model.pending?.value
        XCTAssertEqual(model.step, .summary)
        XCTAssertEqual(model.message?.text, "Done. Codes now go to your phone number ending in 22.")
    }

    func testSummaryWording() {
        XCTAssertTrue(TwoFactorText.summary(TwoFactorOverview(smsAvailable: true, enabled: true, phoneEnding: "78", recoveryCodesLeft: 1))
            .contains("Create new ones soon"))
        XCTAssertTrue(TwoFactorText.summary(TwoFactorOverview(schemaReady: false)).contains("migrate.php"))
    }
}

@MainActor
final class FilesModelTests: XCTestCase {
    func server() -> FakeServer {
        let s = FakeServer()
        s.on("GET", "/api/auth/status") { _ in (200, ["authenticated": true, "user": ["username": "k", "role": "editor"], "csrfToken": "c"]) }
        s.on("GET", "/api/favorites") { _ in (200, ["favorites": [json(entry("a.jpg"))]]) }
        s.on("GET", "/api/files/list") { call in
            if call.query["path"] == "/gone" { return (404, ["error": ["code": "NF", "message": "missing"]]) }
            if call.query["path"] == "/broken" { return (500, ["error": ["code": "X", "message": "Disk on fire"]]) }
            if call.query["path"] == "/empty" { return (200, []) }
            return (200, [json(entry("b.jpg")), json(entry("a.jpg")), json(entry("Docs", dir: true))])
        }
        return s
    }

    func testStartListsTheRootAndFavorites() async {
        let model = FilesModel(api: CloudHubAPI(baseURL: "https://h", transport: server()))
        model.start()
        await model.pending?.value
        await model.pending?.value
        await model.pending?.value
        XCTAssertEqual(model.visible.map(\.name), ["Docs", "a.jpg", "b.jpg"])
        XCTAssertTrue(model.canWrite)
        XCTAssertEqual(model.favorites, ["/a.jpg"])
        XCTAssertEqual(model.shown, .content)
    }

    func testFailedIsNotEmpty() async {
        let model = FilesModel(api: CloudHubAPI(baseURL: "https://h", transport: server()))
        model.open("/broken")
        await model.pending?.value
        XCTAssertEqual(model.shown, .error)
        XCTAssertEqual(model.loadError, "Disk on fire")
        model.open("/empty")
        await model.pending?.value
        XCTAssertEqual(model.shown, .empty)
        model.setQuery("zz")
        XCTAssertEqual(model.shown, .noMatches, "as on Android: a filter over nothing says nothing matched")
    }

    func testMissingFolderFallsBackToTheRoot() async {
        let model = FilesModel(api: CloudHubAPI(baseURL: "https://h", transport: server()))
        model.open("/gone")
        await model.pending?.value
        await model.pending?.value
        XCTAssertEqual(model.path, "/")
        XCTAssertEqual(model.message, "That folder is no longer there")
    }

    func testFilterAndNoMatches() async {
        let model = FilesModel(api: CloudHubAPI(baseURL: "https://h", transport: server()))
        model.open("/")
        await model.pending?.value
        model.setQuery("A.J")
        XCTAssertEqual(model.visible.map(\.name), ["a.jpg"])
        model.setQuery("nothing")
        XCTAssertEqual(model.shown, .noMatches)
    }

    func testStarIsPutBackWhenRefused() async {
        let s = server()
        s.on("POST", "/api/favorites") { _ in (403, ["error": ["code": "LIMIT", "message": "Too many favorites"]]) }
        let model = FilesModel(api: CloudHubAPI(baseURL: "https://h", transport: s))
        model.toggleFavorite(entry("b.jpg"))
        XCTAssertTrue(model.favorites.contains("/b.jpg"), "the star changes at once")
        await model.pending?.value
        XCTAssertFalse(model.favorites.contains("/b.jpg"))
        XCTAssertEqual(model.message, "Too many favorites")
    }
}
