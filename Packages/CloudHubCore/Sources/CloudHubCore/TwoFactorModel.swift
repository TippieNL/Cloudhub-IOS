import Foundation
#if canImport(Combine)
import Combine
#endif

/// What a change does. Turning it on and moving it are the same call on the server.
public enum TwoFactorAction: Sendable, Equatable {
    case turnOn, changePhone, newRecoveryCodes, turnOff

    public var wire: String {
        switch self {
        case .turnOn, .changePhone: return "phone"
        case .newRecoveryCodes: return "recovery"
        case .turnOff: return "disable"
        }
    }

    public var title: String {
        switch self {
        case .turnOn: return "Turn on two-step verification"
        case .changePhone: return "Change phone number"
        case .newRecoveryCodes: return "New recovery codes"
        case .turnOff: return "Turn off two-step verification"
        }
    }
}

public enum TwoFactorStep: Equatable, Sendable {
    case summary
    /// Asking for the password -- and for a number, the number.
    case start(TwoFactorAction)
    /// Waiting for the texted code, or a recovery code.
    case code(TwoFactorCode)
    /// New recovery codes, shown once.
    case codes([String])
}

public struct TwoFactorCode: Equatable, Sendable {
    public var action: TwoFactorAction
    public var stage: TwoFactorStage
    public var recovery: Bool = false
    public var resendAt: Double = 0
    public var rejected: Int = 0

    public func resendWait(now: Double) -> Int { resendAt <= now ? 0 : Int((resendAt - now).rounded(.up)) }

    public var prompt: String {
        if recovery { return "Enter one of your recovery codes in place of a code from your current phone." }
        let ending = stage.phoneEnding ?? "••"
        if stage.stage == "current" { return "Enter the code we sent to your current phone number, ending in \(ending)." }
        return "Enter the code we sent to the number ending in \(ending)."
    }
}

public struct TwoFactorMessage: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public protocol TwoFactorCalls: Sendable {
    func overview() async throws -> TwoFactorOverview
    func start(action: String, password: String, phone: String?, useRecoveryCode: Bool) async throws -> TwoFactorStage
    func resend() async throws -> TwoFactorStage
    func confirm(_ code: String) async throws -> TwoFactorStage
    func confirmRecoveryCode(_ code: String) async throws -> TwoFactorStage
    func cancel() async throws
}

public struct APITwoFactorCalls: TwoFactorCalls {
    let api: CloudHubAPI
    public init(api: CloudHubAPI) { self.api = api }
    public func overview() async throws -> TwoFactorOverview { try await api.twoFactor() }
    public func start(action: String, password: String, phone: String?, useRecoveryCode: Bool) async throws -> TwoFactorStage {
        try await api.startTwoFactorChange(action: action, currentPassword: password, phone: phone, useRecoveryCode: useRecoveryCode)
    }
    public func resend() async throws -> TwoFactorStage { try await api.resendTwoFactorCode() }
    public func confirm(_ code: String) async throws -> TwoFactorStage { try await api.confirmTwoFactorChange(code: code) }
    public func confirmRecoveryCode(_ code: String) async throws -> TwoFactorStage {
        try await api.confirmTwoFactorChange(recoveryCode: code)
    }
    public func cancel() async throws { _ = try await api.cancelTwoFactorChange() }
}

/// Words for the screen, decided without one.
public enum TwoFactorText {
    public static func summary(_ o: TwoFactorOverview) -> String {
        if o.enabled {
            let left = o.recoveryCodesLeft
            var text = "Signing in asks for a code texted to your phone number ending in \(o.phoneEnding ?? "••"). "
            text += "\(left) recovery code\(Format.plural(left)) left."
            if !o.smsAvailable {
                text += " This server cannot send text messages right now: sign in with a recovery code until it can."
            } else if left <= 2 {
                text += " Create new ones soon."
            }
            return text
        }
        if !o.schemaReady { return "Not available yet: the server's database needs updating (php database/migrate.php)." }
        if !o.smsAvailable { return "Not available: no text-message service is set up on this server. An administrator can configure one." }
        return "Off. Turn it on to be asked, after your password, for a code texted to your phone."
    }

    public static func startIntro(_ action: TwoFactorAction, _ o: TwoFactorOverview?) -> String {
        let ending = o?.phoneEnding ?? "••"
        switch action {
        case .turnOn:
            return "Enter the mobile number to send codes to, and your password. We will text a code to that number to make sure it is yours."
        case .changePhone:
            return "Enter your new mobile number and your password. We will text a code to the new number, and first to your current one unless you have just used it."
        case .turnOff:
            return "Enter your password. We will text a code to your phone number ending in \(ending) to confirm it is you."
        case .newRecoveryCodes:
            return "Enter your password. We will text a code to your phone number ending in \(ending). Your current recovery codes then stop working."
        }
    }

    public static func codesNote(_ codes: [String], username: String?, server: String) -> String {
        var text = "Recovery codes for \(username ?? "your account") (\(server))\n"
        text += "Each signs you in once in place of a texted code. Keep them somewhere safe.\n\n"
        for code in codes { text += code + "\n" }
        return text
    }
}

/// The account's own SMS two-step verification, as Settings shows it.
@MainActor
public final class TwoFactorModel: ObservableObject {
    @Published public private(set) var loading = true
    @Published public private(set) var overview: TwoFactorOverview?
    @Published public private(set) var step: TwoFactorStep = .summary
    @Published public private(set) var busy = false
    @Published public var message: TwoFactorMessage?

    private let calls: TwoFactorCalls
    public let clock: () -> Double
    public private(set) var pending: Task<Void, Never>?

    private static let noPendingChange = "TWO_FACTOR_NO_PENDING_CHANGE"

    public init(calls: TwoFactorCalls, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.calls = calls
        self.clock = clock
    }

    /// Arriving on the screen: whatever was half done last time is gone.
    public func open() {
        loading = true
        overview = nil
        step = .summary
        busy = false
        message = nil
        load()
    }

    private func load(keeping kept: TwoFactorMessage? = nil) {
        let calls = self.calls
        pending = Task {
            do {
                let o = try await calls.overview()
                loading = false
                overview = o
                message = kept ?? message
            } catch {
                loading = false
                message = TwoFactorMessage(describe(error), isError: true)
            }
        }
    }

    public func begin(_ action: TwoFactorAction) {
        guard !busy, step == .summary else { return }
        step = .start(action)
        message = nil
    }

    public func submitStart(password: String, phone: String, useRecoveryCode: Bool = false) {
        guard case .start(let action) = step, !busy else { return }
        let wantsPhone = action.wire == "phone"
        let number = phone.trimmingCharacters(in: .whitespaces)
        if wantsPhone && number.isEmpty {
            message = TwoFactorMessage("Enter your mobile number, starting with + and the country code.", isError: true)
            return
        }
        if password.isEmpty {
            message = TwoFactorMessage("Enter your current password.", isError: true)
            return
        }
        busy = true
        message = nil
        let startedFrom = step
        let calls = self.calls
        pending = Task {
            let outcome: Result<TwoFactorStage, Error>
            do {
                outcome = .success(try await calls.start(action: action.wire, password: password,
                                                         phone: wantsPhone ? number : nil, useRecoveryCode: useRecoveryCode))
            } catch {
                outcome = .failure(error)
            }
            busy = false
            guard step == startedFrom else { return }
            switch outcome {
            case .success(let stage):
                let wait = stage.sent ? stage.resendIn : (stage.error?.retryAfter ?? 0)
                step = .code(TwoFactorCode(action: action, stage: stage,
                                           recovery: useRecoveryCode && stage.recoveryAllowed,
                                           resendAt: clock() + Double(wait)))
                message = stage.error.map { TwoFactorMessage($0.message, isError: true) }
            case .failure(let e):
                message = TwoFactorMessage(describe(e), isError: true)
            }
        }
    }

    public func resend() {
        guard case .code(let code) = step, !busy, !code.recovery, code.resendWait(now: clock()) == 0 else { return }
        busy = true
        message = nil
        let calls = self.calls
        pending = Task {
            let outcome: Result<TwoFactorStage, Error>
            do { outcome = .success(try await calls.resend()) } catch { outcome = .failure(error) }
            busy = false
            guard case .code(var current) = step else { return }
            switch outcome {
            case .success(let stage):
                current.stage = stage
                current.resendAt = clock() + Double(stage.resendIn)
                step = .code(current)
                message = TwoFactorMessage("A new code is on its way to the number ending in \(stage.phoneEnding ?? "••").", isError: false)
            case .failure(let e):
                if (e as? ApiError)?.code == Self.noPendingChange {
                    step = .summary
                } else {
                    current.resendAt = clock() + Double((e as? ApiError)?.retryAfter ?? 0)
                    step = .code(current)
                }
                message = TwoFactorMessage(describe(e), isError: true)
            }
        }
    }

    public func confirm(_ typed: String) {
        guard case .code(let code) = step, !busy else { return }
        let value = CodeInput.clean(typed.trimmingCharacters(in: .whitespaces), recovery: code.recovery, length: code.stage.codeLength)
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            message = TwoFactorMessage(code.recovery ? "Enter a recovery code." : "Enter the code from the text message.", isError: true)
            return
        }
        let wasOn = overview?.enabled == true
        busy = true
        message = nil
        let calls = self.calls
        pending = Task {
            let outcome: Result<TwoFactorStage, Error>
            do {
                outcome = .success(code.recovery ? try await calls.confirmRecoveryCode(value) : try await calls.confirm(value))
            } catch {
                outcome = .failure(error)
            }
            busy = false
            guard case .code = step else { return }
            switch outcome {
            case .success(let stage):
                if !stage.done {
                    // The current phone is proven; now the new number's own code.
                    let wait = stage.sent ? stage.resendIn : (stage.error?.retryAfter ?? 0)
                    step = .code(TwoFactorCode(action: code.action, stage: stage, resendAt: clock() + Double(wait)))
                    message = stage.error.map { TwoFactorMessage($0.message, isError: true) }
                        ?? TwoFactorMessage("Thanks. Now enter the code we sent to your new number ending in \(stage.phoneEnding ?? "••").", isError: false)
                } else if let codes = stage.recoveryCodes {
                    step = .codes(codes)
                    message = TwoFactorMessage(
                        wasOn ? "New recovery codes are ready. The old ones no longer work."
                              : "Two-step verification is on. Signing in will now ask for a code texted to your phone.",
                        isError: false)
                } else {
                    step = .summary
                    message = TwoFactorMessage(
                        stage.enabled == true ? "Done. Codes now go to your phone number ending in \(stage.phoneEnding ?? "••")."
                                              : "Two-step verification is off. Signing in takes your password only.",
                        isError: false)
                }
                if stage.done { load(keeping: message) }
            case .failure(let e):
                if (e as? ApiError)?.code == Self.noPendingChange {
                    step = .summary
                } else {
                    var again = code
                    if e is ApiError { again.rejected += 1 }
                    step = .code(again)
                }
                message = TwoFactorMessage(describe(e), isError: true)
            }
        }
    }

    public func switchMethod() {
        guard case .code(var code) = step, !busy, code.stage.recoveryAllowed else { return }
        code.recovery.toggle()
        step = .code(code)
        message = nil
    }

    /// Leave a change half done; the server forgets it too (best effort).
    public func cancel() {
        switch step {
        case .code:
            let calls = self.calls
            Task { try? await calls.cancel() }
            fallthrough
        case .start:
            step = .summary
            busy = false
            message = nil
        default:
            break
        }
    }

    /// The recovery codes were kept; they are not shown again.
    public func codesSaved() {
        if case .codes = step {
            step = .summary
            message = nil
        }
    }
}
