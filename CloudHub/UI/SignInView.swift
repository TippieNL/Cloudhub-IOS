import CloudHubCore
import SwiftUI

/// First run: where is the server? Checked before it is accepted, because a
/// typo otherwise shows up much later as a blank screen.
struct SetupView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var certificate: UntrustedCertificate?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("files.example.com", text: $input)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .disabled(busy)
                } header: {
                    Text("Server address")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter the address of your CloudHub server, exactly as in a browser. You can change it later.")
                        if let error {
                            Text(error).foregroundStyle(Brand.danger)
                        }
                        if ServerAddress.isInsecure(input.trimmingCharacters(in: .whitespaces)) {
                            Text("Over plain http nothing is encrypted, including your password. Prefer https:// where you can.")
                        }
                    }
                }
                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Connect").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("Connect to your server")
            .toolbar {
                if !(app.prefs.serverURL ?? "").isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { app.phase = .signIn }
                    }
                }
            }
        }
        .onAppear { if input.isEmpty { input = app.prefs.serverURL.map(displayServer) ?? "" } }
        .alert("Certificate not trusted", isPresented: Binding(get: { certificate != nil }, set: { if !$0 { certificate = nil } }),
               presenting: certificate) { cert in
            Button("Trust this certificate") {
                app.prefs.pin(cert.fingerprint)
                certificate = nil
                connect()
            }
            Button("Cancel", role: .cancel) { certificate = nil }
        } message: { cert in
            Text("\(cert.host) presented a certificate this device does not trust (\(cert.reason)).\n\nSHA-256\n\(cert.fingerprint)\n\nOnly continue if this is your server's fingerprint. It will be remembered, and you will be asked again if it ever changes.")
        }
    }

    private func connect() {
        guard let url = ServerAddress.normalise(input) else {
            error = "Enter a server address."
            return
        }
        busy = true
        error = nil
        Task {
            let previous = app.api.baseURL
            app.api.baseURL = url
            do {
                // Answers without a session and returns JSON, so a captive
                // portal or an unrelated web server is not taken for a CloudHub.
                _ = try await app.api.status()
                app.useServer(url)
            } catch let e as ApiError where e.code != "BAD_RESPONSE" {
                // Any structured reply means a CloudHub answered.
                app.useServer(url)
            } catch let cert as UntrustedCertificate {
                app.api.baseURL = previous
                certificate = cert
            } catch {
                app.api.baseURL = previous
                self.error = describe(error, fallback: "Could not reach that server.")
            }
            busy = false
        }
    }
}

/// Sign in: a gradient, a translucent card, the mark, and the form rising
/// into place. Reduce Motion stops all of it; the states still change.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var password = ""
    @State private var reveal = false
    @State private var remember = true
    @State private var shake = 0
    @State private var appeared = false
    @FocusState private var focus: Field?

    enum Field { case username, password, code }

    private var model: SignInModel { app.signIn }

    var body: some View {
        ZStack {
            SignInBackground()
            ScrollView {
                VStack(spacing: 20) {
                    BrandMark().frame(width: 76, height: 76).padding(.top, 48)
                    VStack(spacing: 4) {
                        Text("CloudHub").font(.largeTitle.bold())
                        Text(displayServer(app.api.baseURL))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .rise(appeared, delay: 0.05)

                    Group {
                        if let step = model.codeStep {
                            CodeStepCard(step: step, focus: $focus)
                        } else {
                            passwordCard
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .modifier(Shake(count: shake))
                    .rise(appeared, delay: 0.12)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 480)

                    if model.codeStep == nil {
                        Button("Use a different server") { app.phase = .setup }
                            .font(.subheadline)
                            .rise(appeared, delay: 0.2)
                    }
                }
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            username = app.prefs.rememberedUsername ?? ""
            remember = app.prefs.rememberedUsername != nil || username.isEmpty
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { appeared = true }
            if case .idle = model.state, model.codeStep == nil { focus = username.isEmpty ? .username : .password }
        }
        .onChange(of: model.state) { _, state in
            switch state {
            case .failed:
                if !reduceMotion { withAnimation(.default) { shake += 1 } }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                model.failureShown()
                if case .failed(let e) = state, e.field == .password { password = "" }
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    // Long enough to read the check mark, not long enough to wait for.
                    try? await Task.sleep(nanoseconds: reduceMotion ? 0 : 450_000_000)
                    app.signedIn(username: username.trimmingCharacters(in: .whitespaces), remember: remember)
                }
            default:
                break
            }
        }
        .onChange(of: model.codeStep?.rejected ?? 0) { old, new in
            if new > old {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                if !reduceMotion { withAnimation(.default) { shake += 1 } }
            }
        }
    }

    private var error: SignInError? {
        if case .idle(let e) = model.state { return e }
        if case .failed(let e) = model.state { return e }
        return nil
    }

    @ViewBuilder private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = app.signInNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .fieldStyle(error: error?.field == .username)
                if error?.field == .username, let e = error { FieldError(text: e.message) }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Group {
                        if reveal {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
                .fieldStyle(error: error?.field == .password)
                if error?.field == .password, let e = error { FieldError(text: e.message) }
            }
            .onChange(of: username) { model.editing() }
            .onChange(of: password) { model.editing() }

            Toggle("Remember my username", isOn: $remember).font(.subheadline)

            if let e = error, e.field == nil { FieldError(text: e.message) }

            Button(action: submit) {
                ZStack {
                    switch model.state {
                    case .submitting: ProgressView().tint(.white)
                    case .success: Image(systemName: "checkmark").font(.headline.bold()).transition(.scale)
                    default: Text("Sign in").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.state == .submitting || model.state == .success)
            .animation(.snappy, value: model.state)
        }
    }

    private func submit() {
        focus = nil
        model.submit(username: username, password: password)
    }
}

/// The code step: texted to the phone as it opens; the sixth digit checks it.
private struct CodeStepCard: View {
    @Environment(AppEnvironment.self) private var app
    let step: CodeStep
    var focus: FocusState<SignInView.Field?>.Binding
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two-step verification").font(.title3.bold())
            Text(step.prompt).font(.subheadline).foregroundStyle(.secondary)
            if let notice = step.notice {
                Label(notice, systemImage: step.sending ? "paperplane" : "checkmark.message")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TextField(step.recovery ? "Recovery code" : "Code", text: $code)
                .textContentType(step.recovery ? nil : .oneTimeCode)
                .keyboardType(step.recovery ? .asciiCapable : .numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(step.recovery ? .body.monospaced() : .title2.monospacedDigit())
                .focused(focus, equals: .code)
                .fieldStyle(error: step.error != nil)
                .onChange(of: code) { _, typed in
                    let cleaned = CodeInput.clean(typed, recovery: step.recovery, length: step.codeLength)
                    if cleaned != typed { code = cleaned }
                    if CodeInput.complete(cleaned, recovery: step.recovery, length: step.codeLength) { app.signIn.verify(cleaned) }
                }
                .onSubmit { app.signIn.verify(code) }
            if let error = step.error { FieldError(text: error) }

            Button { app.signIn.verify(code) } label: {
                ZStack {
                    if step.verifying { ProgressView().tint(.white) } else { Text("Verify").font(.headline) }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(step.verifying)

            if step.smsAvailable && !step.recovery {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let wait = step.resendWait(now: app.signIn.clock())
                    Button(wait > 0 ? "Send a new code (\(wait)s)" : "Send a new code") { app.signIn.sendCode() }
                        .disabled(!step.canResend(now: app.signIn.clock()))
                }
                .font(.subheadline)
            }
            if step.smsAvailable {
                Button(step.recovery ? "Use a texted code instead" : "Use a recovery code instead") {
                    code = ""
                    app.signIn.switchMethod()
                }
                .font(.subheadline)
            }
            Button("Back to sign in") { app.signIn.cancelCode() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onAppear { focus.wrappedValue = .code }
        .onChange(of: step.rejected) { code = "" }
    }
}

private struct FieldError: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Brand.danger).fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    func fieldStyle(error: Bool) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground).opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(error ? Brand.danger : Color.clear, lineWidth: 1.5))
    }

    func rise(_ appeared: Bool, delay: Double) -> some View {
        modifier(Rise(appeared: appeared, delay: delay))
    }
}

private struct Rise: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(delay), value: appeared)
    }
}

/// A rejected password shakes the card.
private struct Shake: GeometryEffect {
    var count: Int
    var animatableData: CGFloat

    init(count: Int) {
        self.count = count
        animatableData = CGFloat(count)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Two soft colour fields drifting behind the card.
private struct SignInBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Brand.background
                    Circle()
                        .fill(Brand.primary.opacity(0.35))
                        .frame(width: geo.size.width * 1.1)
                        .blur(radius: 80)
                        .offset(x: -geo.size.width * 0.3 + sin(t / 7) * 30, y: -geo.size.height * 0.3 + cos(t / 9) * 40)
                    Circle()
                        .fill(Brand.accent.opacity(0.3))
                        .frame(width: geo.size.width)
                        .blur(radius: 90)
                        .offset(x: geo.size.width * 0.35 + cos(t / 8) * 30, y: geo.size.height * 0.35 + sin(t / 6) * 40)
                }
            }
            .ignoresSafeArea()
        }
    }
}
