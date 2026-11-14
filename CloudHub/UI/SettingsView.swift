import CloudHubCore
import SwiftUI
import UIKit

/// Account, server, appearance, playback, what is kept on this device, and
/// signing out. Only what is destructive is red, and what cannot be undone asks.
struct SettingsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @State private var changingPassword = false
    @State private var confirmForget = false
    @State private var confirmSignOut = false
    @State private var thumbnails: Int64 = 0
    @State private var positions = 0

    var body: some View {
        Form {
            Section("Account") {
                LabeledRow(app.files.user?.username ?? "Not signed in", value: (app.files.user?.role ?? "").capitalized)
                Button { changingPassword = true } label: {
                    row("Change password", "Your current password is required", "key")
                }
                NavigationLink(destination: TwoFactorView()) {
                    row("Two-step verification", "A code by text message when you sign in", "lock.shield")
                }
            }
            Section("Server") {
                LabeledRow("Address", value: displayServer(app.api.baseURL))
                NavigationLink(destination: StorageView()) { row("Storage and space left", nil, "chart.pie") }
                NavigationLink(destination: DuplicatesView()) { row("Find duplicates", "Files stored more than once", "square.on.square") }
                Button { app.phase = .setup } label: { row("Use a different server", nil, "server.rack") }
            }
            Section("Appearance") {
                Picker("Theme", selection: $app.theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(get: { app.files.grid }, set: { app.files.grid = $0 })) {
                    row("Open folders in the grid", app.files.grid ? "Pictures first, in a grid" : "Names first, in a list", "square.grid.2x2")
                }
            }
            Section("Playback and history") {
                LabeledRow {
                    Text(positions == 0 ? "None" : "\(positions) video\(Format.plural(positions))")
                } label: {
                    row("Videos with a saved position", "Reopening one offers to carry on where you stopped", "play.circle")
                }
                if positions > 0 {
                    Button(role: .destructive) { confirmForget = true } label: {
                        Label("Forget saved positions", systemImage: "clock.arrow.circlepath")
                    }
                }
                if app.prefs.rememberedUsername != nil {
                    Button {
                        app.prefs.rememberedUsername = nil
                        app.show("Username forgotten")
                    } label: { row("Forget the remembered username", nil, "person.crop.circle.badge.minus") }
                }
            }
            Section("On this device") {
                Button {
                    app.images.clear()
                    thumbnails = 0
                    app.show("Image cache cleared")
                } label: {
                    LabeledRow {
                        Text(thumbnails == 0 ? "Empty" : Format.bytes(thumbnails))
                    } label: {
                        row("Cached thumbnails and photos", thumbnails == 0 ? "Nothing cached" : "Tap to clear", "photo.on.rectangle.angled")
                    }
                }
                .disabled(thumbnails == 0)
                LabeledRow {
                    Text(app.uploads.queued.isEmpty ? "None" : "\(app.uploads.queued.count) file\(Format.plural(app.uploads.queued.count))")
                } label: {
                    row("Uploads waiting", "Resumed whenever the app or iOS gets the chance", "arrow.up.circle")
                }
            }
            Section("About") {
                LabeledRow("CloudHub", value: app.appVersion)
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            positions = app.prefs.rememberedPositionCount
            thumbnails = app.images.diskBytes
        }
        .onChange(of: app.files.grid) { grid in app.prefs.gridView = grid }
        .confirmationDialog("Forget saved positions?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                app.prefs.forgetAllResumePositions()
                positions = 0
                app.show("Saved positions forgotten")
            }
        } message: {
            Text("Every video will start from the beginning next time.")
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { app.signOut() }
        } message: {
            Text("Uploads still waiting will stay queued until you sign in again.")
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet().environmentObject(app) }
    }

    private func row(_ title: String, _ detail: String?, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Brand.primary)
        }
    }
}

private struct ChangePasswordSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var replacement = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    /// The server's own minimum.
    static let minimum = 12

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("Current password", text: $current).textContentType(.password)
                    SecureField("New password", text: $replacement).textContentType(.newPassword)
                    SecureField("Repeat the new password", text: $confirm).textContentType(.newPassword)
                } footer: {
                    if let error { Text(error).foregroundStyle(Brand.danger) }
                    else { Text("At least \(Self.minimum) characters.") }
                }
            }
            .navigationTitle("Change password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Change", action: submit) }
                }
            }
            .onChange(of: current) { _ in error = nil }
            .onChange(of: replacement) { _ in error = nil }
            .onChange(of: confirm) { _ in error = nil }
        }
    }

    private func submit() {
        if current.isEmpty { error = "Enter your current password."; return }
        if replacement.count < Self.minimum { error = "The new password must be at least \(Self.minimum) characters."; return }
        if replacement != confirm { error = "The two new passwords do not match."; return }
        if replacement == current { error = "The new password is the same as the current one."; return }
        busy = true
        Task {
            do {
                _ = try await app.api.changePassword(current: current, replacement: replacement)
                app.show("Password changed")
                dismiss()
            } catch {
                self.error = describe(error, fallback: "Could not change the password.")
            }
            busy = false
        }
    }
}
