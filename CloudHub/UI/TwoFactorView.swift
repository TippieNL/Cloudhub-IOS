import CloudHubCore
import SwiftUI
import UIKit

/// Settings › Two-step verification: whether it is on, and turning it on,
/// moving it, new recovery codes and turning it off -- each with the current
/// password and a texted code, as in the web app's Security panel.
struct TwoFactorView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var password = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var codesSaved = false
    @State private var confirmLeave = false

    private var model: TwoFactorModel { app.twoFactor }

    var body: some View {
        Form {
            if let message = model.message {
                Section {
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(message.isError ? Brand.danger : .primary)
                }
            }
            switch model.step {
            case .summary: summary
            case .start(let action): start(action)
            case .code(let step): codeStep(step)
            case .codes(let codes): recoveryCodes(codes)
            }
        }
        .navigationTitle("Two-step verification")
        .navigationBarBackButtonHidden(isCodes)
        .toolbar {
            if isCodes {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if codesSaved { model.codesSaved() } else { confirmLeave = true } }
                }
            }
        }
        .confirmationDialog("Leave without saving the codes?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { model.codesSaved() }
        } message: {
            Text("They are shown once. Without them, a lost phone means asking an administrator to let you in.")
        }
        .onAppear { model.open() }
        .onDisappear { model.cancel() }
        .disabled(model.busy)
    }

    private var isCodes: Bool {
        if case .codes = model.step { return true }
        return false
    }

    @ViewBuilder private var summary: some View {
        if model.loading {
            Section { ProgressView() }
        } else if let o = model.overview {
            Section {
                HStack {
                    Text(o.enabled ? "On" : "Off")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background((o.enabled ? Brand.primary : Color.secondary).opacity(0.15), in: Capsule())
                        .foregroundStyle(o.enabled ? Brand.primary : .secondary)
                    Spacer()
                }
                Text(TwoFactorText.summary(o)).font(.subheadline)
            }
            Section {
                if o.enabled {
                    Button("Change phone number") { begin(.changePhone) }
                    Button("New recovery codes") { begin(.newRecoveryCodes) }
                    Button("Turn off", role: .destructive) { begin(.turnOff) }
                } else if o.available {
                    Button("Turn on") { begin(.turnOn) }
                }
            }
        }
    }

    private func begin(_ action: TwoFactorAction) {
        password = ""
        phone = ""
        code = ""
        model.begin(action)
    }

    @ViewBuilder private func start(_ action: TwoFactorAction) -> some View {
        Section {
            Text(TwoFactorText.startIntro(action, model.overview)).font(.subheadline)
            if action.wire == "phone" {
                TextField("+31 6 12345678", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            }
            SecureField("Current password", text: $password).textContentType(.password)
        } header: {
            Text(action.title)
        }
        Section {
            Button {
                model.submitStart(password: password, phone: phone)
            } label: {
                HStack { Text("Send the code"); if model.busy { Spacer(); ProgressView() } }
            }
            // For a phone that is gone: answer it with a recovery code instead.
            if model.overview?.enabled == true && action != .turnOn {
                Button("No access to your phone?") { model.submitStart(password: password, phone: phone, useRecoveryCode: true) }
            }
            Button("Cancel", role: .cancel) { model.cancel() }
        }
    }

    @ViewBuilder private func codeStep(_ step: TwoFactorCode) -> some View {
        Section {
            Text(step.prompt).font(.subheadline)
            TextField(step.recovery ? "Recovery code" : "Code", text: $code)
                .textContentType(step.recovery ? nil : .oneTimeCode)
                .keyboardType(step.recovery ? .asciiCapable : .numberPad)
                .textInputAutocapitalization(.never)
                .font(.title3.monospacedDigit())
                .onChange(of: code) { _, typed in
                    let cleaned = CodeInput.clean(typed, recovery: step.recovery, length: step.stage.codeLength)
                    if cleaned != typed { code = cleaned }
                    if CodeInput.complete(cleaned, recovery: step.recovery, length: step.stage.codeLength) { model.confirm(cleaned) }
                }
                .onChange(of: step.rejected) { code = "" }
                .onChange(of: step.stage.stage) { code = "" }
        } header: {
            Text(step.action.title)
        }
        Section {
            Button {
                model.confirm(code)
            } label: {
                HStack { Text("Verify"); if model.busy { Spacer(); ProgressView() } }
            }
            if !step.recovery {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let wait = step.resendWait(now: model.clock())
                    Button(wait > 0 ? "Send a new code (\(wait)s)" : "Send a new code") { model.resend() }
                        .disabled(wait > 0)
                }
            }
            if step.stage.recoveryAllowed {
                Button(step.recovery ? "Use a texted code instead" : "Use a recovery code instead") {
                    code = ""
                    model.switchMethod()
                }
            }
            Button("Cancel", role: .cancel) { model.cancel() }
        }
    }

    @ViewBuilder private func recoveryCodes(_ codes: [String]) -> some View {
        let note = TwoFactorText.codesNote(codes, username: app.files.user?.username, server: displayServer(app.api.baseURL))
        Section {
            ForEach(Array(codes.enumerated()), id: \.offset) { i, c in
                LabeledContent("\(i + 1).") { Text(c).font(.body.monospaced()).textSelection(.enabled) }
            }
        } header: {
            Text("Recovery codes")
        } footer: {
            Text("Each signs you in once in place of a texted code. They are shown once: keep them in a password manager or somewhere safe.")
        }
        Section {
            Button {
                // Kept out of other devices' clipboards and expired after a while.
                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: note]],
                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                codesSaved = true
                app.show("Codes copied")
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            SwiftUI.ShareLink(item: note) { Label("Share", systemImage: "square.and.arrow.up") }
                .simultaneousGesture(TapGesture().onEnded { codesSaved = true })
            Button("I have saved them") {
                codesSaved = true
                model.codesSaved()
            }
        }
    }
}
