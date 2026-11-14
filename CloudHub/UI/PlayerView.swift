import AVFoundation
import AVKit
import CloudHubCore
import Combine
import SwiftUI

/// Video and audio playback, in AVKit's own player -- speed, AirPlay,
/// picture in picture and fullscreen come with it -- plus the subtitle files
/// found beside the film, and an offer to carry on where you stopped.
struct PlayerView: View {
    @EnvironmentObject private var app: AppEnvironment
    let entry: FileEntry
    @State private var session: PlaybackSession?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                PlayerScreen(entry: entry, session: session)
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .toastOverlay()
        .onAppear {
            ForegroundMedia.enter()
            UIApplication.shared.isIdleTimerDisabled = true
            if session == nil { session = PlaybackSession(app: app, entry: entry) }
        }
        .onDisappear {
            ForegroundMedia.leave()
            UIApplication.shared.isIdleTimerDisabled = false
            session?.stop()
            app.reveal = entry.path
        }
    }
}

/// The screen around the player, watching the session for subtitles.
private struct PlayerScreen: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let entry: FileEntry
    @ObservedObject var session: PlaybackSession

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                PlayerController(session: session, cue: session.cue).ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("Back")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !session.tracks.isEmpty {
                        Menu {
                            Picker("Subtitles", selection: Binding(get: { session.chosen?.id ?? "" },
                                                                   set: { id in session.choose(session.tracks.first { $0.id == id }) })) {
                                Text("Off").tag("")
                                ForEach(session.tracks) { track in
                                    Text(track.label.isEmpty ? (track.language.isEmpty ? track.name : track.language) : track.label)
                                        .tag(track.id)
                                }
                            }
                        } label: {
                            Image(systemName: session.chosen == nil ? "captions.bubble" : "captions.bubble.fill")
                        }
                        .accessibilityLabel("Subtitles")
                    }
                    Button { app.files.toggleFavorite(entry) } label: {
                        Image(systemName: app.files.favorites.contains(entry.path) ? "star.fill" : "star")
                            .foregroundStyle(app.files.favorites.contains(entry.path) ? Brand.favorite : .white)
                    }
                    .accessibilityLabel(app.files.favorites.contains(entry.path) ? "Remove from favorites" : "Add to favorites")
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// The player, the resume offer, the remembered position and the subtitles.
@MainActor
final class PlaybackSession: ObservableObject {
    let player: AVPlayer
    @Published private(set) var tracks: [SubtitleTrack] = []
    @Published private(set) var chosen: SubtitleTrack?
    @Published private(set) var cue: String?

    private let app: AppEnvironment
    private let entry: FileEntry
    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var offeredResume = false
    private var lastSaved = Date.distantPast

    init(app: AppEnvironment, entry: FileEntry) {
        self.app = app
        self.entry = entry
        let url = app.api.streamURL(entry.path)
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: app.vault.cookies(for: url)])
        asset.resourceLoader.setDelegate(app.mediaTrust, queue: app.mediaTrust.queue)
        let item = AVPlayerItem(asset: asset)
        // On a local network a second of video arrives in well under a second.
        item.preferredForwardBufferDuration = 15
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.ready(item) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            // A finished video is finished, not paused near the end.
            Task { @MainActor in
                guard let self else { return }
                self.app.prefs.forgetResumePosition(self.entry.path)
                self.offeredResume = true
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        player.play()
        loadSubtitles()
    }

    /// Whether the saved position is worth returning to depends on the duration.
    private func ready(_ item: AVPlayerItem) {
        guard !offeredResume else { return }
        offeredResume = true
        let saved = app.prefs.resumePosition(of: entry.path)
        let duration = item.duration.isNumeric ? Int64(item.duration.seconds * 1000) : 0
        guard saved > 0, ResumePolicy.shouldResume(positionMs: saved, durationMs: duration) else { return }
        player.seek(to: CMTime(value: saved, timescale: 1000))
        app.show("Resumed at \(Format.time(milliseconds: saved))", action: "Start over") { [weak self] in
            guard let self else { return }
            self.player.seek(to: .zero)
            self.app.prefs.forgetResumePosition(self.entry.path)
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        let showing = chosen == nil ? nil : WebVTT.cue(at: seconds, in: cues)?.text
        // Five ticks a second; the screen only hears about a new line.
        if showing != cue { cue = showing }
        // Written while playing, not only on the way out: an app killed in the
        // background never gets to say goodbye.
        if player.timeControlStatus == .playing, Date().timeIntervalSince(lastSaved) > 5 {
            lastSaved = Date()
            app.prefs.rememberResumePosition(entry.path, ms: Int64(seconds * 1000))
        }
    }

    /* ---- subtitles --------------------------------------------------------
     *
     * Asked for after playback has started: a film that stalls on a subtitle
     * lookup is a worse player than one with none, and a lookup that fails is
     * not worth telling anyone about.
     */

    private func loadSubtitles() {
        Task {
            guard let found = try? await app.api.subtitles(entry.path), !found.isEmpty else { return }
            tracks = found
            // The language chosen last time, if this film has it.
            if let language = app.prefs.subtitleLanguage,
               let match = found.first(where: { $0.language.caseInsensitiveCompare(language) == .orderedSame }) ?? found.first(where: \.forced) {
                await select(match, remember: false)
            } else if let forced = found.first(where: \.forced) {
                await select(forced, remember: false)
            }
        }
    }

    func choose(_ track: SubtitleTrack?) {
        Task { await select(track, remember: true) }
    }

    private func select(_ track: SubtitleTrack?, remember: Bool) async {
        // Only a film with tracks counts: one with none must not forget the language.
        if remember { app.prefs.subtitleLanguage = track?.language }
        guard let track else {
            chosen = nil
            cues = []
            cue = nil
            return
        }
        do {
            let (data, _) = try await app.api.fetch(app.api.subtitleURL(track.path))
            cues = WebVTT.parse(String(decoding: data, as: UTF8.self))
            chosen = track
        } catch {
            app.show("Could not load the subtitles: \(describe(error))")
        }
    }

    func stop() {
        if player.currentItem.map({ $0.currentTime() < $0.duration - CMTime(value: 1, timescale: 1) }) ?? false {
            app.prefs.rememberResumePosition(entry.path, ms: Int64(player.currentTime().seconds * 1000))
        }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// AVPlayerViewController, with the subtitle cue drawn in its overlay view.
private struct PlayerController: UIViewControllerRepresentable {
    let session: PlaybackSession
    /// Passed in, so the view is redrawn when the cue changes.
    let cue: String?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = session.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = true

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .title3)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.shadowColor = .black
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = controller.contentOverlayView {
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -64),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
            ])
        }
        context.coordinator.label = label
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let text = cue
        context.coordinator.label?.text = text.map { " \($0) " }
        context.coordinator.label?.isHidden = text == nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var label: UILabel?
    }
}
