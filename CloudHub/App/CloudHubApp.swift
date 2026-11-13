import BackgroundTasks
import CloudHubCore
import SwiftUI
import UIKit

@main
struct CloudHubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.app)
                .preferredColorScheme(delegate.app.theme.colorScheme)
                .tint(Brand.primary)
                .onOpenURL { delegate.app.receive($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: delegate.app.uploads.kick()
            case .background: delegate.app.uploads.scheduleBackground()
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var app = AppEnvironment()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Registered before launch finishes, as BGTaskScheduler requires.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: UploadCenter.backgroundTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in self.app.uploads.runInBackground(task) }
        }
        return true
    }
}

extension ThemeChoice {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The phase decides the screen; everything signed-in lives under one stack.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            switch app.phase {
            case .setup:
                SetupView()
                    .transition(.opacity)
            case .restoring:
                RestoringView()
                    .task { await app.restore() }
            case .signIn:
                SignInView()
                    .transition(.opacity)
            case .files:
                NavigationStack(path: $app.path) {
                    FilesView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .favorites: FavoritesView()
                            case .trash: TrashView()
                            case .storage: StorageView()
                            case .duplicates: DuplicatesView()
                            case .settings: SettingsView()
                            case .twoFactor: TwoFactorView()
                            }
                        }
                }
                .fullScreenCover(item: $app.viewer) { request in
                    PhotoViewer(images: request.images, startAt: request.index)
                        .environment(app)
                }
                .fullScreenCover(item: $app.player) { entry in
                    PlayerView(entry: entry)
                        .environment(app)
                }
                .sheet(item: $app.sharing) { entry in
                    ShareLinkSheet(entry: entry)
                        .environment(app)
                }
                .sheet(item: Binding(get: { app.quickLook.map(PreviewItem.init) }, set: { app.quickLook = $0?.url })) { item in
                    QuickLookView(url: item.url).ignoresSafeArea()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.phase)
        .toastOverlay()
        // The session ended under the app: back to sign-in, saying so.
        .onChange(of: app.files.signedOut) { _, ended in
            if ended && app.phase == .files { app.endSession(notice: "Your session ended. Sign in again.") }
        }
    }
}

struct PreviewItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The mark, while the stored session is checked -- not a flash of the login form.
struct RestoringView: View {
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            VStack(spacing: 24) {
                BrandMark().frame(width: 88, height: 88)
                ProgressView()
            }
        }
    }
}
