import CloudHubCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// Where the app is, at the top level.
enum Phase: Equatable {
    /// No server yet, or changing it.
    case setup
    /// Checking whether the stored session is still good.
    case restoring
    case signIn
    case files
}

/// Screens pushed over the file browser. Back pops one at a time, so opening
/// Storage from Settings and going back returns to Settings.
enum Route: Hashable {
    case favorites, trash, storage, duplicates, settings, twoFactor
}

/// The photos the viewer swipes through, and where it starts.
struct ViewerRequest: Identifiable {
    let id = UUID()
    let images: [FileEntry]
    let index: Int
}

/// A short message over the bottom of the screen, with an optional action.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var actionLabel: String?
    var action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Everything long-lived, wired once. No dependency-injection framework: this
/// app has one client, one API and one settings store.
@MainActor
@Observable
final class AppEnvironment {
    @ObservationIgnored let prefs: Preferences
    @ObservationIgnored let vault: CookieVault
    @ObservationIgnored let client: HTTPClient
    @ObservationIgnored let api: CloudHubAPI
    @ObservationIgnored let images: ImageLoader
    @ObservationIgnored let mediaTrust: MediaTrust
    let uploads: UploadCenter
    let files: FilesModel
    let signIn: SignInModel
    let twoFactor: TwoFactorModel

    var phase: Phase
    var path: [Route] = []
    var theme: ThemeChoice {
        didSet { prefs.theme = theme }
    }
    var toast: Toast?
    var viewer: ViewerRequest?
    var player: FileEntry?
    var sharing: FileEntry?
    var quickLook: URL?
    /// The file a viewer was closed on, so the list comes back to it.
    var reveal: String?
    /// A message for the sign-in screen: "Your session ended".
    var signInNotice: String?

    init() {
        let prefs = Preferences()
        let vault = CookieVault()
        let client = HTTPClient(vault: vault, pins: { prefs.pinnedCertificates })
        let api = CloudHubAPI(baseURL: prefs.serverURL ?? "", transport: client)
        self.prefs = prefs
        self.vault = vault
        self.client = client
        self.api = api
        self.images = ImageLoader(client: client, api: api)
        self.mediaTrust = MediaTrust(client: client)
        self.uploads = UploadCenter(api: api)
        self.files = FilesModel(api: api)
        self.signIn = SignInModel(calls: APISignInCalls(api: api))
        self.twoFactor = TwoFactorModel(calls: APITwoFactorCalls(api: api))
        self.theme = prefs.theme
        self.phase = (prefs.serverURL ?? "").isEmpty ? .setup : .restoring
        files.grid = prefs.gridView
        uploads.onFolderChanged = { [weak self] folder in self?.files.folderChanged(folder) }
    }

    /* ---- session ---------------------------------------------------------- */

    /// Straight to the files if the stored session is still good; on to the
    /// code step if the app was closed while a texted code was being fetched.
    func restore() async {
        guard phase == .restoring else { return }
        do {
            let status = try await api.status()
            if status.authenticated {
                enterFiles()
            } else if let waiting = status.twoFactor {
                signIn.resume(waiting)
                phase = .signIn
            } else {
                phase = .signIn
            }
        } catch {
            // Offline, or the server is down: the sign-in screen says so when used.
            phase = .signIn
        }
    }

    func useServer(_ url: String) {
        prefs.serverURL = url
        api.baseURL = url
        vault.clear()
        signIn.reset()
        path = []
        phase = .signIn
    }

    func signedIn(username: String, remember: Bool) {
        prefs.rememberedUsername = remember ? username : nil
        if let notice = signIn.takeRecoveryNotice() { show(notice) }
        enterFiles()
    }

    private func enterFiles() {
        path = []
        signInNotice = nil
        phase = .files
        files.start()
        uploads.kick()
    }

    func signOut() {
        Task {
            _ = try? await api.logout()
            endSession(notice: nil)
        }
    }

    /// The server ended the session under the app (timed out, disabled, or
    /// two-step verification turned on elsewhere): back to sign-in, saying so.
    func endSession(notice: String?) {
        vault.clear()
        signIn.reset()
        path = []
        viewer = nil
        player = nil
        signInNotice = notice
        phase = .signIn
    }

    /* ---- opening things --------------------------------------------------- */

    /// Photos in the viewer, swiping through the others beside them; sound and
    /// video in the player; anything else in Quick Look.
    func open(_ entry: FileEntry, among siblings: [FileEntry]) {
        switch entry.kind {
        case .folder:
            files.open(entry.path)
        case .image where entry.ext != "svg":
            let photos = siblings.filter { $0.kind == .image && $0.ext != "svg" }
            viewer = ViewerRequest(images: photos, index: photos.firstIndex { $0.path == entry.path } ?? 0)
        case .video, .audio:
            player = entry
        default:
            preview(entry)
        }
    }

    /// Fetched to a temporary file and handed to Quick Look, which draws PDFs,
    /// text, Office documents, SVG and most else.
    func preview(_ entry: FileEntry) {
        show("Opening \(entry.name)…")
        Task {
            do {
                let (tmp, response) = try await client.download(api.previewURL(entry.path, version: entry.modified))
                guard (200..<300).contains(response.statusCode) else {
                    throw ApiError.from(status: response.statusCode, body: try? Data(contentsOf: tmp))
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent(DownloadRules.safeName(entry.name))
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
                toast = nil
                quickLook = target
            } catch {
                show("Could not open \(entry.name): \(describe(error))")
            }
        }
    }

    /// Into the app's Documents folder, which the Files app shows under
    /// On My iPhone › CloudHub -- never replacing an earlier download.
    func download(_ entry: FileEntry) {
        show("Downloading \(entry.name)…")
        Task {
            do {
                let (tmp, response) = try await client.download(api.downloadURL(entry.path))
                guard (200..<300).contains(response.statusCode) else {
                    throw ApiError.from(status: response.statusCode, body: try? Data(contentsOf: tmp))
                }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let name = DownloadRules.freeName(DownloadRules.safeName(entry.name)) {
                    FileManager.default.fileExists(atPath: docs.appendingPathComponent($0).path)
                }
                try FileManager.default.moveItem(at: tmp, to: docs.appendingPathComponent(name))
                show("Saved \(name) to Files › On My iPhone › CloudHub")
            } catch {
                show("Could not download \(entry.name): \(describe(error))")
            }
        }
    }

    /// A local copy for the share sheet: a messaging app wants the picture,
    /// not a link to a server it cannot sign in to. Usually already cached.
    func localCopy(of entry: FileEntry) async throws -> URL {
        let url = api.previewURL(entry.path, version: entry.modified)
        let data = try await images.data(for: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(DownloadRules.safeName(entry.name))
        try data.write(to: target, options: .atomic)
        return target
    }

    /* ---- uploads ---------------------------------------------------------- */

    /// Queue picked files for the folder on screen and say what happened.
    func enqueue(_ files: [(url: URL, name: String)]) {
        let folder = self.files.path
        var queued = 0
        var full: (Int64, Int64)?
        var unreadable = 0
        for file in files {
            switch uploads.stage(file: file.url, name: file.name, to: folder) {
            case .staged: queued += 1
            case .noRoom(let needed, let free): full = (needed, free)
            case .unreadable: unreadable += 1
            }
        }
        report(queued: queued, full: full, unreadable: unreadable)
    }

    func enqueue(data: Data, name: String) {
        switch uploads.stage(data: data, name: name, to: files.path) {
        case .staged: report(queued: 1, full: nil, unreadable: 0)
        case .noRoom(let needed, let free): report(queued: 0, full: (needed, free), unreadable: 0)
        case .unreadable: report(queued: 0, full: nil, unreadable: 1)
        }
    }

    /// A subtitle goes up beside its video under the name the player looks for.
    func attachSubtitle(_ file: URL, to video: FileEntry, named name: String) {
        switch uploads.stage(file: file, name: name, to: Paths.parentOf(video.path)) {
        case .staged:
            uploads.kick()
            show("Adding \(name)")
        case .noRoom: show("Not enough space on this phone")
        case .unreadable: show("That file could not be read")
        }
    }

    private func report(queued: Int, full: (Int64, Int64)?, unreadable: Int) {
        if queued > 0 {
            uploads.kick()
            show(queued == 1 ? "1 file queued for upload" : "\(queued) files queued for upload")
        }
        // Space is the actionable failure, so it is the one that is named.
        if let full {
            let (needed, free) = full
            let what = needed >= 0 ? Format.bytes(needed) : "that file"
            show("Not enough space on this phone: \(what) to copy, \(Format.bytes(free)) free")
        } else if unreadable > 0 && queued == 0 {
            show("Nothing could be read from that")
        }
    }

    /// Files handed over by another app ("Open in CloudHub", the share sheet).
    func receive(_ url: URL) {
        guard phase == .files else {
            show("Sign in first, then share the file again.")
            return
        }
        enqueue([(url, url.lastPathComponent)])
    }

    /* ---- feedback --------------------------------------------------------- */

    func show(_ text: String, action: String? = nil, perform: (() -> Void)? = nil) {
        toast = Toast(text: text, actionLabel: action, action: perform)
    }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
