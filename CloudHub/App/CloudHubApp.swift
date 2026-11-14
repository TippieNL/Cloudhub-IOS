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
                .environmentObject(delegate.app)
                .onOpenURL { delegate.app.receive($0) }
        }
        .onChange(of: scenePhase) { phase in
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
    @EnvironmentObject private var app: AppEnvironment

    var body: some View {
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
                NavigationView {
                    FilesView()
                }
                .navigationViewStyle(.stack)
                .fullScreenCover(item: $app.viewer) { request in
                    PhotoViewer(images: request.images, startAt: request.index)
                        .environmentObject(app)
                }
                .fullScreenCover(item: $app.player) { entry in
                    PlayerView(entry: entry)
                        .environmentObject(app)
                }
                .sheet(item: $app.sharing) { entry in
                    ShareLinkSheet(entry: entry)
                        .environmentObject(app)
                }
                .sheet(item: Binding(get: { app.quickLook.map(PreviewItem.init) }, set: { app.quickLook = $0?.url })) { item in
                    QuickLookView(url: item.url).ignoresSafeArea()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.phase)
        .toastOverlay()
        .preferredColorScheme(app.theme.colorScheme)
        .tint(Brand.primary)
        // The session ended under the app: back to sign-in, saying so.
        .onChange(of: app.files.signedOut) { ended in
            if ended && app.phase == .files { app.endSession(notice: "Your session ended. Sign in again.") }
        }
    }
}

/// The pushed screens, as links the file browser keeps out of sight. One
/// tagged link per route: NavigationStack's value-based navigation is iOS 16.
struct RouteLinks: View {
    @EnvironmentObject private var app: AppEnvironment

    var body: some View {
        VStack {
            link(.favorites) { FavoritesView() }
            link(.trash) { TrashView() }
            link(.storage) { StorageView() }
            link(.duplicates) { DuplicatesView() }
            link(.settings) { SettingsView() }
            link(.twoFactor) { TwoFactorView() }
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityHidden(true)
    }

    private func link<Destination: View>(_ route: Route, @ViewBuilder _ destination: @escaping () -> Destination) -> some View {
        NavigationLink(tag: route, selection: $app.route, destination: destination) { EmptyView() }
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
