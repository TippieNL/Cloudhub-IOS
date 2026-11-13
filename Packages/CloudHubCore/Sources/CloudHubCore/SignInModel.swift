import Foundation
import Observation

/// Why an attempt did not go through, and which field is at fault.
public struct SignInError: Equatable, Sendable {
    public enum Field: Sendable { case username, password }
    public var message: String
    public var field: Field?

    public init(_ message: String, field: Field? = nil) {
        self.message = message
        self.field = field
    }
}

/// The code step of signing in. Times are on the model's clock (seconds).
public struct CodeStep: Equatable, Sendable {
    public var phoneEnding: String?
    public var codeLength: Int = 6
    public var smsAvailable: Bool = true
    /// Entering one of the account's recovery codes rather than a texted code.
    public var recovery: Bool = false
    public var sending: Bool = false
    public var verifying: Bool = false
    /// When another code may be asked for.
    public var resendAt: Double = 0
    public var notice: String?
    public var error: String?
    /// Counts refused codes, so the screen shakes and clears the field once for each.
    public var rejected: Int = 0

    public init(phoneEnding: String? = nil, codeLength: Int = 6, smsAvailable: Bool = true, recovery: Bool = false) {
        self.phoneEnding = phoneEnding
        self.codeLength = codeLength
        self.smsAvailable = smsAvailable
        self.recovery = recovery
    }

    /// Whole seconds before "Send a new code" works again; 0 once it does.
    public func resendWait(now: Double) -> Int { resendAt <= now ? 0 : Int((resendAt - now).rounded(.up)) }

    public func canResend(now: Double) -> Bool {
        smsAvailable && !recovery && !sending && !verifying && resendWait(now: now) == 0
    }

    public var prompt: String {
        if recovery {
            return "Enter one of the recovery codes you saved when you turned on two-step verification. Each one works once."
        }
        if let phoneEnding { return "Enter the \(codeLength)-digit code we sent to your phone number ending in \(phoneEnding)." }
        return "Enter the \(codeLength)-digit code we sent to your phone."
    }
}

public enum SignInState: Equatable, Sendable {
    /// Nothing in flight; carries the last failure so the form can show it.
    case idle(SignInError?)
    case submitting
    /// Signed in; the screen plays its success animation before moving on.
    case success
    /// Distinct from idle so the shake fires exactly once.
    case failed(SignInError)
    /// The password was right, and a texted code is wanted too.
    case code(CodeStep)
}

/// What a typed code is cleaned to before it is sent.
public enum CodeInput {
    public static func clean(_ typed: String, recovery: Bool, length: Int) -> String {
        recovery ? String(typed.prefix(64)) : String(typed.filter(\.isASCIIDigit).prefix(length))
    }

    /// Complete enough to check without the Verify button.
    public static func complete(_ cleaned: String, recovery: Bool, length: Int) -> Bool {
        !recovery && cleaned.count == length
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Whether the form can be sent. A username pasted from a password manager
/// often arrives with a trailing space; a password is never trimmed.
public enum SignInForm {
    public enum Result: Equatable {
        case valid(username: String, password: String)
        case invalid(SignInError)
    }

    public static func validate(username: String, password: String) -> Result {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .invalid(SignInError("Enter your username.", field: .username)) }
        if password.isEmpty { return .invalid(SignInError("Enter your password.", field: .password)) }
        return .valid(username: name, password: password)
    }
}

/// The calls the sign-in screen makes, so its rules can be driven from a test.
public protocol SignInCalls: Sendable {
    func login(_ username: String, _ password: String) async throws -> LoginResult
    func send() async throws -> CodeSent
    func verify(_ code: String) async throws -> LoginResult
    func verifyRecoveryCode(_ code: String) async throws -> LoginResult
    func cancel() async throws
}

public struct APISignInCalls: SignInCalls {
    let api: CloudHubAPI
    public init(api: CloudHubAPI) { self.api = api }
    public func login(_ username: String, _ password: String) async throws -> LoginResult {
        try await api.login(username: username, password: password)
    }
    public func send() async throws -> CodeSent { try await api.sendSignInCode() }
    public func verify(_ code: String) async throws -> LoginResult { try await api.verifySignIn(code: code) }
    public func verifyRecoveryCode(_ code: String) async throws -> LoginResult { try await api.verifySignIn(recoveryCode: code) }
    public func cancel() async throws { _ = try await api.cancelSignIn() }
}

/// Sign-in, kept off the screen: the view renders `state` and calls in.
@MainActor
@Observable
public final class SignInModel {
    public private(set) var state: SignInState = .idle(nil)

    @ObservationIgnored private let calls: SignInCalls
    /// Seconds, monotonic, for the resend countdown.
    @ObservationIgnored public let clock: () -> Double
    @ObservationIgnored private var recoveryCodesLeft: Int?
    /// The most recent background work, so a test can wait for it.
    @ObservationIgnored public private(set) var pending: Task<Void, Never>?

    public init(calls: SignInCalls, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.calls = calls
        self.clock = clock
    }

    public var codeStep: CodeStep? {
        if case .code(let step) = state { return step }
        return nil
    }

    /// Set when the sign-in that just succeeded spent a recovery code. Taken once.
    public func takeRecoveryNotice() -> String? {
        guard let left = recoveryCodesLeft else { return nil }
        recoveryCodesLeft = nil
        return "Signed in with a recovery code; \(left) left. If your phone is gone, change the number in Settings under Two-step verification."
    }

    public func submit(username: String, password: String) {
        // The guard for a double tap and a keyboard Go on the same press.
        if state == .submitting { return }
        if codeStep != nil { return }
        switch SignInForm.validate(username: username, password: password) {
        case .invalid(let error):
            state = .failed(error)
        case .valid(let name, let pass):
            state = .submitting
            pending = Task { state = await attempt(name, pass) }
        }
    }

    private func attempt(_ username: String, _ password: String) async -> SignInState {
        do {
            let result = try await calls.login(username, password)
            if result.success { return .success }
            if let second = result.twoFactor { return codeStep(second) }
            return .failed(SignInError("Sign in failed. Check your username and password."))
        } catch let e as ApiError {
            return .failed(SignInError(e.message))
        } catch {
            return .failed(SignInError(describe(error)))
        }
    }

    /// Carry on with a sign-in the server is still waiting on. Only from rest.
    public func resume(_ info: SecondStep) {
        switch state {
        case .idle, .failed: state = codeStep(info)
        default: break
        }
    }

    private func codeStep(_ info: SecondStep) -> SignInState {
        var step = CodeStep(phoneEnding: info.phoneEnding, codeLength: info.codeLength,
                            smsAvailable: info.smsAvailable, recovery: !info.smsAvailable)
        if !info.smsAvailable {
            step.notice = "This server cannot send text messages right now. Use one of your recovery codes, or ask your administrator."
            return .code(step)
        }
        if info.codeSent {
            step.notice = "A code was already sent, and still works."
            step.resendAt = clock() + Double(info.resendIn)
            return .code(step)
        }
        step.sending = true
        step.notice = "Sending a code…"
        pending = Task { await deliver() }
        return .code(step)
    }

    /// "Send a new code": a fresh code, and the one before it stops working.
    public func sendCode() {
        guard var step = codeStep, step.canResend(now: clock()) else { return }
        step.sending = true
        step.notice = "Sending a code…"
        step.error = nil
        state = .code(step)
        pending = Task { await deliver() }
    }

    private func deliver() async {
        let outcome: Result<CodeSent, Error>
        do { outcome = .success(try await calls.send()) } catch { outcome = .failure(error) }
        guard var step = codeStep else { return }
        let now = clock()
        switch outcome {
        case .success(let sent):
            let minutes = max(1, ((sent.expiresIn ?? 300) + 30) / 60)
            step.sending = false
            step.phoneEnding = sent.phoneEnding ?? step.phoneEnding
            step.notice = "Code sent. It works for \(minutes) minute\(Format.plural(minutes))."
            step.error = nil
            step.resendAt = now + Double(sent.resendIn)
            state = .code(step)
        case .failure(let e):
            if let api = e as? ApiError, api.isUnauthorized { return backToPassword(api) }
            step.sending = false
            step.notice = nil
            step.error = (e as? ApiError)?.message ?? "Could not reach the server."
            step.resendAt = now + Double((e as? ApiError)?.retryAfter ?? 0)
            state = .code(step)
        }
    }

    /// Check what was typed: the texted code, or a recovery code.
    public func verify(_ typed: String) {
        guard var step = codeStep, !step.verifying else { return }
        let code = CodeInput.clean(typed.trimmingCharacters(in: .whitespaces), recovery: step.recovery, length: step.codeLength)
        if code.trimmingCharacters(in: .whitespaces).isEmpty {
            step.error = step.recovery ? "Enter a recovery code." : "Enter the code from the text message."
            state = .code(step)
            return
        }
        step.verifying = true
        step.error = nil
        state = .code(step)
        let recovery = step.recovery
        pending = Task {
            let outcome: Result<LoginResult, Error>
            do {
                outcome = .success(recovery ? try await calls.verifyRecoveryCode(code) : try await calls.verify(code))
            } catch {
                outcome = .failure(error)
            }
            guard var now = codeStep else { return }
            switch outcome {
            case .success(let result):
                if result.success {
                    recoveryCodesLeft = result.recoveryCodesLeft
                    state = .success
                } else {
                    now.verifying = false
                    now.error = "That did not work."
                    now.rejected += 1
                    state = .code(now)
                }
            case .failure(let e):
                if let api = e as? ApiError, api.isUnauthorized { return backToPassword(api) }
                now.verifying = false
                now.error = (e as? ApiError)?.message ?? "Could not reach the server."
                if e is ApiError { now.rejected += 1 }
                state = .code(now)
            }
        }
    }

    /// Between a texted code and a recovery code. Without SMS, recovery is all there is.
    public func switchMethod() {
        guard var step = codeStep, !step.verifying, step.smsAvailable else { return }
        step.recovery.toggle()
        step.error = nil
        state = .code(step)
    }

    /// "Back to sign in". The server forgets the waiting sign-in too; best effort.
    public func cancelCode() {
        guard codeStep != nil else { return }
        state = .idle(nil)
        let calls = self.calls
        pending = Task { try? await calls.cancel() }
    }

    private func backToPassword(_ e: ApiError) {
        state = .failed(SignInError(e.message.isEmpty ? "Your sign-in timed out. Enter your password again." : e.message,
                                    field: .password))
    }

    /// Forget the last sign-in, for the next visit to the screen.
    public func reset() {
        recoveryCodesLeft = nil
        state = .idle(nil)
    }

    /// Settle back to idle once the failure animation has played, keeping the message.
    public func failureShown() {
        if case .failed(let error) = state { state = .idle(error) }
    }

    /// Clear the error as soon as the user starts fixing it.
    public func editing() {
        if case .idle(let error) = state, error != nil { state = .idle(nil) }
    }
}
