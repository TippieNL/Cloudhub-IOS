import BackgroundTasks
import CloudHubCore
import Foundation
import Observation
import UIKit

/// The upload queue as the screens see it, and the thing that keeps it moving.
///
/// iOS has no WorkManager. What keeps an upload going here:
///   - in the foreground, the engine simply runs, retrying with a backoff
///     after a network failure;
///   - leaving the app asks for background time to finish the chunk in flight;
///   - a background processing task, wanted with a network connection, is
///     scheduled whenever something is still queued, so the system resumes the
///     queue later -- typically when the phone is idle and charging.
/// The queue is on disk and the server reports what it already holds, so
/// nothing is sent twice however the work is interrupted.
@MainActor
@Observable
final class UploadCenter {
    static let backgroundTaskId = "nl.tippie.cloudhub.uploads"

    private(set) var queued: [QueuedUpload] = []
    private(set) var failures: [UploadFailure] = []
    private(set) var summary: UploadProgress.Summary = .idle
    private(set) var currentId: String?
    private(set) var currentSent: Int64 = 0
    private(set) var justFinished = false

    @ObservationIgnored let queue: UploadQueue
    @ObservationIgnored private let engine: UploadEngine
    @ObservationIgnored private var batchTotal: Int64 = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: UInt64 = 15
    @ObservationIgnored private var lingering: Task<Void, Never>?
    /// Told when a folder gained a file, so the list on screen can refresh.
    @ObservationIgnored var onFolderChanged: ((String) -> Void)?

    init(api: CloudHubAPI) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uploads", isDirectory: true)
        queue = UploadQueue(directory: dir)
        engine = UploadEngine(api: api, queue: queue)
        queue.sweepOrphans()
        reload()
    }

    var visible: Bool { summary.active || justFinished || !failures.isEmpty }

    /* ---- staging ---------------------------------------------------------- */

    enum StageResult {
        case staged
        case noRoom(needed: Int64, free: Int64)
        case unreadable
    }

    /// Copy a file into the queue's own storage and queue it for `folder`.
    /// `name` is what it will be called on the server.
    func stage(file source: URL, name: String, to folder: String) -> StageResult {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let needed = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        let free = Self.freeSpace(at: queue.stagingDirectory)
        if !StagingSpace.hasRoom(freeBytes: free, neededBytes: needed) { return .noRoom(needed: needed, free: free) }

        let id = UploadQueue.newId()
        let target = queue.stagingDirectory.appendingPathComponent(id)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            // Not backed up: it is a copy on its way somewhere else.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var t = target
            try? t.setResourceValues(values)
            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            queue.add(QueuedUpload(id: id, name: name, stagedName: id, targetPath: folder, size: size))
            return .staged
        } catch {
            try? FileManager.default.removeItem(at: target)
            if Self.freeSpace(at: queue.stagingDirectory) < StagingSpace.headroomBytes { return .noRoom(needed: needed, free: 0) }
            return .unreadable
        }
    }

    /// Bytes made here -- a photo just taken -- written straight into the queue.
    func stage(data: Data, name: String, to folder: String) -> StageResult {
        let free = Self.freeSpace(at: queue.stagingDirectory)
        if !StagingSpace.hasRoom(freeBytes: free, neededBytes: Int64(data.count)) {
            return .noRoom(needed: Int64(data.count), free: free)
        }
        let id = UploadQueue.newId()
        do {
            try data.write(to: queue.stagingDirectory.appendingPathComponent(id), options: .atomic)
            queue.add(QueuedUpload(id: id, name: name, stagedName: id, targetPath: folder, size: Int64(data.count)))
            return .staged
        } catch {
            return .unreadable
        }
    }

    private static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /* ---- running ---------------------------------------------------------- */

    /// Start the uploader if it is not already running.
    func kick() {
        reload()
        guard runner == nil, !queue.all().isEmpty else { return }
        let engine = self.engine
        runner = Task { [weak self] in
            // Finish the chunk in flight if the app is left mid-upload.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Uploads") {
                Task { @MainActor in self?.runner?.cancel() }
            }
            let outcome = await engine.run { tick in
                Task { @MainActor in self?.progress(tick) }
            }
            UIApplication.shared.endBackgroundTask(background)
            guard let self else { return }
            self.runner = nil
            self.reload()
            switch outcome {
            case .drained:
                self.retryDelay = 15
            case .retryLater:
                self.scheduleBackground()
                let delay = self.retryDelay
                self.retryDelay = min(self.retryDelay * 2, 300)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if UIApplication.shared.applicationState != .background { self.kick() }
            case .cancelled:
                self.scheduleBackground()
            }
        }
    }

    func stop() { runner?.cancel() }

    /// Ask the system to carry on later; harmless when nothing is queued.
    func scheduleBackground() {
        guard !queue.all().isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The system's background slot: drain until it says stop.
    func runInBackground(_ task: BGProcessingTask) {
        let engine = self.engine
        let work = Task {
            let outcome = await engine.run { _ in }
            await MainActor.run {
                self.reload()
                self.scheduleBackground()
            }
            task.setTaskCompleted(success: outcome == .drained)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func progress(_ tick: UploadTick) {
        let before = queued
        currentId = tick.running ? tick.id : nil
        currentSent = tick.sent
        reload()
        // Something left the queue: its folder now has a file in it.
        let still = Set(queued.map(\.id))
        let folders = Set(before.filter { !still.contains($0.id) }.map(\.targetPath))
        for folder in folders { onFolderChanged?(folder) }
    }

    func reload() {
        queued = queue.all()
        failures = queue.failures()
        let remaining = queued.reduce(Int64(0)) { $0 + max(0, $1.size) }
        if queued.isEmpty {
            let hadBatch = batchTotal > 0
            batchTotal = 0
            if hadBatch { finishedMoment() }
        } else {
            batchTotal = UploadProgress.batchTotal(previous: batchTotal, remainingBytes: remaining)
            justFinished = false
        }
        summary = UploadProgress.summarise(remaining: queued, currentId: currentId, currentSent: currentSent, batchTotal: batchTotal)
    }

    /// "All uploads finished" is worth a glance, not a permanent fixture.
    private func finishedMoment() {
        justFinished = true
        lingering?.cancel()
        lingering = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { self?.justFinished = false }
        }
    }

    func clearFailures() {
        queue.clearFailures()
        reload()
    }
}
