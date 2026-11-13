import Foundation

/// One queued upload.
///
/// The bytes are copied into the app's own storage when queued: a file handed
/// over by the photo picker or the share sheet is only readable for a moment,
/// and by the time the uploader gets to it the original can be gone. The copy
/// is deleted once the server has the file.
///
/// `stagedName` is a file name inside the staging folder rather than a full
/// path, because iOS moves an app's container on reinstall and update.
public struct QueuedUpload: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var stagedName: String
    public var targetPath: String
    public var size: Int64
    public var queuedAt: Date

    public init(id: String, name: String, stagedName: String, targetPath: String, size: Int64, queuedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.stagedName = stagedName
        self.targetPath = targetPath
        self.size = size
        self.queuedAt = queuedAt
    }
}

/// An upload the server refused for good: over quota, too large, forbidden.
/// Kept, with the server's own words, until it is dismissed.
public struct UploadFailure: Codable, Hashable, Sendable {
    public var name: String
    public var reason: String
    public var at: Date

    public init(name: String, reason: String, at: Date = Date()) {
        self.name = name
        self.reason = reason
        self.at = at
    }
}

/// Whether there is room to copy a file into app storage.
public enum StagingSpace {
    /// Left free after a staged copy, so the app is not the thing that fills the phone.
    public static let headroomBytes: Int64 = 64 * 1024 * 1024

    public static func hasRoom(freeBytes: Int64, neededBytes: Int64) -> Bool {
        if neededBytes < 0 { return freeBytes > headroomBytes }
        return freeBytes - neededBytes >= headroomBytes
    }
}

/// The queue itself, persisted as one small JSON file, written atomically.
public final class UploadQueue: @unchecked Sendable {
    public let directory: URL
    public var stagingDirectory: URL { directory.appendingPathComponent("staged", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("upload-queue.json") }
    private var failureFile: URL { directory.appendingPathComponent("upload-failures.json") }

    /// One lock for every instance: the uploader and the screens each hold one.
    private static let lock = NSLock()
    private static let maxFailures = 20

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    public func stagedURL(_ item: QueuedUpload) -> URL { stagingDirectory.appendingPathComponent(item.stagedName) }

    public func all() -> [QueuedUpload] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return read(file) ?? []
    }

    public func add(_ item: QueuedUpload) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        write((read(file) ?? []) + [item], to: file)
    }

    public func remove(_ id: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        write((read(file) ?? [QueuedUpload]()).filter { $0.id != id }, to: file)
    }

    public func failures() -> [UploadFailure] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return read(failureFile) ?? []
    }

    public func recordFailure(_ failure: UploadFailure) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let kept = ((read(failureFile) ?? []) + [failure]).suffix(Self.maxFailures)
        write(Array(kept), to: failureFile)
    }

    public func clearFailures() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try? FileManager.default.removeItem(at: failureFile)
    }

    /// Staged files the queue no longer mentions -- left by a crash mid-stage.
    public func sweepOrphans() {
        let known = Set(all().map(\.stagedName))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        for name in names where !known.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(name))
        }
    }

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    /// Written beside the file and moved over it: a process killed mid-write
    /// must not leave half a document that reads back as an empty queue.
    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A new staging id, like the Android client's: "a" and 20 hex digits.
    public static func newId() -> String {
        "a" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
    }
}

/// Whether a video or a photo is on screen right now.
///
/// An upload made of back-to-back chunks takes the whole connection, so the
/// uploader is told when someone is watching. A counter rather than a flag:
/// the player can be opened over the viewer.
public enum ForegroundMedia {
    private static let lock = NSLock()
    private static var open = 0

    public static var inUse: Bool {
        lock.lock(); defer { lock.unlock() }
        return open > 0
    }

    public static func enter() {
        lock.lock(); defer { lock.unlock() }
        open += 1
    }

    /// Clamped at zero: an unbalanced leave must not hide a later enter.
    public static func leave() {
        lock.lock(); defer { lock.unlock() }
        open = max(0, open - 1)
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        open = 0
    }
}

/// How much of the link an upload may take.
public enum UploadPacing {
    /// Sent per request while a video or photo is open, then a pause.
    public static let yieldChunkBytes: Int64 = 256 * 1024
    public static let yieldPauseMs: UInt64 = 1500
    /// Below the server's 8 MB so that opening a video is noticed within seconds.
    public static let idleChunkBytes: Int64 = 2 * 1024 * 1024
    public static let fallbackChunkBytes: Int64 = 1 * 1024 * 1024

    /// Never more than the server said it would take: that is a 413.
    public static func chunkBytes(serverChunkBytes: Int64, mediaOnScreen: Bool) -> Int64 {
        let allowed = serverChunkBytes > 0 ? serverChunkBytes : fallbackChunkBytes
        return min(mediaOnScreen ? yieldChunkBytes : idleChunkBytes, allowed)
    }

    public static func pauseMs(mediaOnScreen: Bool) -> UInt64 { mediaOnScreen ? yieldPauseMs : 0 }

    public static func approximateRate(serverChunkBytes: Int64, mediaOnScreen: Bool) -> Int64 {
        let chunk = chunkBytes(serverChunkBytes: serverChunkBytes, mediaOnScreen: mediaOnScreen)
        let pause = pauseMs(mediaOnScreen: mediaOnScreen)
        if pause == 0 { return .max }
        return chunk * 1000 / Int64(pause)
    }
}

/// How far a batch of uploads has got, in bytes, with a denominator that never shrinks.
public enum UploadProgress {
    public struct Summary: Equatable, Sendable {
        public var active: Bool
        public var filesLeft: Int
        public var currentName: String?
        public var doneBytes: Int64
        public var totalBytes: Int64
        public var fraction: Double

        public var finished: Bool { !active && totalBytes > 0 }

        public static let idle = Summary(active: false, filesLeft: 0, currentName: nil, doneBytes: 0, totalBytes: 0, fraction: 0)
    }

    /// A high-water mark: finishing files must not shrink it, added ones must raise it.
    public static func batchTotal(previous: Int64, remainingBytes: Int64) -> Int64 { max(previous, remainingBytes) }

    public static func summarise(remaining: [QueuedUpload], currentId: String?, currentSent: Int64, batchTotal: Int64) -> Summary {
        if remaining.isEmpty {
            var s = Summary.idle
            s.totalBytes = batchTotal
            return s
        }
        let remainingBytes = remaining.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let current = remaining.first { $0.id == currentId }
        let sent = current.map { min(max(currentSent, 0), $0.size) } ?? 0
        let total = max(batchTotal, remainingBytes)
        let done = min(max(total - remainingBytes + sent, 0), total)
        return Summary(active: true, filesLeft: remaining.count, currentName: current?.name,
                       doneBytes: done, totalBytes: total,
                       fraction: total <= 0 ? 0 : min(max(Double(done) / Double(total), 0), 1))
    }
}

/// Where the uploader has got, published after every chunk.
public struct UploadTick: Sendable, Equatable {
    public var id: String?
    public var sent: Int64
    public var running: Bool

    public init(id: String?, sent: Int64, running: Bool) {
        self.id = id
        self.sent = sent
        self.running = running
    }
}

/// Sends queued uploads, resuming from what the server confirms.
///
/// Drained rather than iterated: a file queued while the batch runs is picked
/// up by the same run. Every pass either removes the item or ends the run.
public actor UploadEngine {
    public enum Outcome: Sendable, Equatable {
        /// The queue is empty.
        case drained
        /// Something went wrong that a later attempt may get past.
        case retryLater
        /// Stopped from outside.
        case cancelled
    }

    private let api: CloudHubAPI
    private let queue: UploadQueue
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var running = false

    public init(api: CloudHubAPI, queue: UploadQueue,
                sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0 * 1_000_000) }) {
        self.api = api
        self.queue = queue
        self.sleep = sleep
    }

    public var isRunning: Bool { running }

    /// Run until the queue is empty or something stops it. A second call while
    /// one is running returns at once: one uploader draining in order.
    public func run(onTick: @escaping @Sendable (UploadTick) -> Void) async -> Outcome {
        if running { return .drained }
        running = true
        defer { running = false; onTick(UploadTick(id: nil, sent: 0, running: false)) }

        // The token can be stale after a restart; refreshing it saves every write failing with 419.
        do { _ = try await api.status() } catch { return .retryLater }

        while let item = queue.all().first {
            if Task.isCancelled { return .cancelled }
            let source = queue.stagedURL(item)
            guard FileManager.default.fileExists(atPath: source.path) else {
                queue.remove(item.id)
                continue
            }
            do {
                var status = try await api.uploadInit(id: item.id, targetPath: item.targetPath, name: item.name, size: item.size)
                var offset = min(status.received, item.size)
                onTick(UploadTick(id: item.id, sent: offset, running: true))
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }

                while offset < item.size {
                    if Task.isCancelled { return .cancelled }
                    // Asked every chunk, so a video opened part-way through is noticed.
                    let watching = ForegroundMedia.inUse
                    let slice = UploadPacing.chunkBytes(serverChunkBytes: status.chunkBytes, mediaOnScreen: watching)
                    let end = min(offset + slice, item.size)
                    try handle.seek(toOffset: UInt64(offset))
                    let body = handle.readData(ofLength: Int(end - offset))
                    if body.count != Int(end - offset) {
                        throw ApiError(status: 0, code: "STAGED_FILE", message: "The staged copy of \(item.name) ended early.")
                    }
                    status = try await api.uploadChunk(id: item.id, offset: offset, body: body)
                    if status.received <= offset { return .retryLater }   // no progress; back off
                    offset = status.received
                    onTick(UploadTick(id: item.id, sent: offset, running: true))
                    let pause = UploadPacing.pauseMs(mediaOnScreen: watching)
                    if pause > 0 { try await sleep(pause) }
                }

                _ = try await api.uploadComplete(id: item.id)
                queue.remove(item.id)
                try? FileManager.default.removeItem(at: source)
            } catch let error as ApiError {
                // Over quota, too large or forbidden: retrying changes nothing.
                // Dropped -- but recorded, so the file does not vanish unexplained.
                if error.isOutOfSpace || error.status == 413 || error.isForbidden {
                    queue.recordFailure(UploadFailure(name: item.name, reason: error.message))
                    queue.remove(item.id)
                    try? FileManager.default.removeItem(at: source)
                    continue
                }
                return .retryLater
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .retryLater   // the network went away; try again later
            }
        }
        return .drained
    }
}
