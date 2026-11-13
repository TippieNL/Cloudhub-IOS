import AVFoundation
import CloudHubCore
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Thumbnails and photos: fetched through the shared client, kept on disk,
/// decoded at the size they are drawn.
///
/// The bytes are kept as the server sent them rather than as decoded bitmaps:
/// a tile and the photo viewer can then decode the same file at different
/// sizes, and Details reads the EXIF from it without another request.
final class ImageLoader: @unchecked Sendable {
    private let client: HTTPClient
    private let api: CloudHubAPI
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let inFlight = InFlight()
    /// Bounded; pruned oldest-first at launch.
    static let diskLimit: Int64 = 300 * 1024 * 1024

    init(client: HTTPClient, api: CloudHubAPI) {
        self.client = client
        self.api = api
        memory.totalCostLimit = 96 * 1024 * 1024
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task.detached(priority: .background) { [directory] in Self.prune(directory) }
    }

    /* ---- the cache -------------------------------------------------------- */

    func fileURL(for url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key)
    }

    /// The bytes behind `url`, from disk if they are there.
    func data(for url: URL) async throws -> Data {
        let file = fileURL(for: url)
        if let cached = try? Data(contentsOf: file) { return cached }
        return try await inFlight.run(url.absoluteString) { [client] in
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await client.send(request)
            guard (200..<300).contains(response.statusCode), !data.isEmpty else {
                throw ApiError.from(status: response.statusCode, body: data)
            }
            try? data.write(to: file, options: .atomic)
            return data
        }
    }

    func cachedData(for url: URL) -> Data? { try? Data(contentsOf: fileURL(for: url)) }

    /// A still image no larger than `maxPixels` on its long edge.
    func image(for url: URL, maxPixels: CGFloat) async throws -> UIImage {
        let key = "\(url.absoluteString)|\(Int(maxPixels))" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let bytes = try await data(for: url)
        guard let image = Self.downsample(bytes, maxPixels: maxPixels) else {
            throw ApiError(status: 0, code: "UNDECODABLE", message: "This picture could not be drawn.")
        }
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    func memoryImage(for url: URL, maxPixels: CGFloat) -> UIImage? {
        memory.object(forKey: "\(url.absoluteString)|\(Int(maxPixels))" as NSString)
    }

    /// Decoded at the size it is drawn: a 12 MP photo in a 120 pt tile does
    /// not need 48 MB of bitmap. Orientation is applied.
    static func downsample(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// An animated GIF (or animated WebP/HEIF) as an animating UIImage; nil for a still.
    static func animated(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var duration = 0.0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        for i in 0..<min(count, 600) {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? 0.1
            duration += delay < 0.02 ? 0.1 : delay
        }
        return frames.isEmpty ? nil : UIImage.animatedImage(with: frames, duration: duration)
    }

    /* ---- video frames ----------------------------------------------------
     *
     * A video the server has no frame for is drawn from a frame decoded here.
     * AVFoundation asks for byte ranges, so it reads the index and the first
     * frames rather than the whole film -- and the frame is handed back to the
     * server, so it happens once per file rather than once per device.
     */

    func videoFrame(for entry: FileEntry, maxPixels: CGFloat, trust: MediaTrust) async throws -> UIImage {
        let key = "frame:\(entry.path)|\(entry.modified)|\(Int(maxPixels))" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let asset = AVURLAsset(url: api.streamURL(entry.path), options: [
            AVURLAssetHTTPCookiesKey: client.vault.cookies(for: api.streamURL(entry.path)),
        ])
        asset.resourceLoader.setDelegate(trust, queue: trust.queue)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let (cg, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let image = UIImage(cgImage: cg)
        memory.setObject(image, forKey: key)
        contribute(image, for: entry)
        return image
    }

    /// Best effort: a thumbnail nobody could store is still a thumbnail.
    private func contribute(_ frame: UIImage, for entry: FileEntry) {
        guard VideoThumbnails.markContributed(entry.path), let cg = frame.cgImage else { return }
        let (w, h) = VideoThumbnails.scaledSize(width: cg.width, height: cg.height)
        guard w > 0, h > 0 else { return }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            return f
        }())
        let scaled = renderer.image { _ in frame.draw(in: CGRect(x: 0, y: 0, width: w, height: h)) }
        // The server takes WebP, JPEG or PNG; iOS writes JPEG natively.
        guard let jpeg = scaled.jpegData(compressionQuality: VideoThumbnails.jpegQuality) else { return }
        let api = self.api
        Task.detached(priority: .utility) {
            _ = try? await api.contributeVideoThumbnail(path: entry.path, imageBase64: jpeg.base64EncodedString())
        }
    }

    /* ---- housekeeping ----------------------------------------------------- */

    var diskBytes: Int64 { Self.size(of: directory) }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
        return total
    }

    private static func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let names = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files = names.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        guard total > diskLimit else { return }
        files.sort { $0.2 < $1.2 }
        for (url, size, _) in files where total > diskLimit * 3 / 4 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

/// One request per URL at a time: twenty tiles asking for one thumbnail share it.
private actor InFlight {
    private var tasks: [String: Task<Data, Error>] = [:]

    func run(_ key: String, _ work: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let existing = tasks[key] { return try await existing.value }
        let task = Task { try await work() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}

/// AVFoundation's own networking, given the same certificate decisions as
/// everything else. Without it a self-signed server would list and draw
/// photos, and then refuse to play a single video.
final class MediaTrust: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "nl.tippie.cloudhub.media-trust")
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge) -> Bool {
        let (disposition, credential) = client.evaluate(authenticationChallenge)
        switch disposition {
        case .useCredential:
            authenticationChallenge.sender?.use(credential!, for: authenticationChallenge)
        case .performDefaultHandling:
            authenticationChallenge.sender?.performDefaultHandling?(for: authenticationChallenge)
        default:
            authenticationChallenge.sender?.cancel(authenticationChallenge)
        }
        return true
    }
}
