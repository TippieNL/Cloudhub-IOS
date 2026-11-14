import CloudHubCore
import ImageIO
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// New folder, rename, move/copy, properties and add-subtitles, for the browser.
struct FileDialogs: ViewModifier {
    @EnvironmentObject private var app: AppEnvironment
    @Binding var prompt: PromptRequest?
    @Binding var relocating: FilesView.Relocation?
    @Binding var properties: FileEntry?
    @Binding var subtitlesFor: FileEntry?

    func body(content: Content) -> some View {
        content
            .sheet(item: $prompt) { request in
                TextPromptSheet(title: request.title, placeholder: request.placeholder, initial: request.initial,
                                message: request.message, confirm: request.confirm, onConfirm: request.onConfirm)
            }
            .sheet(item: $relocating) { request in
                FolderPicker(startAt: app.files.path, confirm: request.moving ? "Move here" : "Copy here") { destination in
                    if request.moving { app.files.move(request.paths, to: destination) }
                    else { app.files.copy(request.paths, to: destination) }
                }
                .environmentObject(app)
            }
            .sheet(item: $properties) { entry in
                PropertiesSheet(entry: entry, photo: nil)
            }
            // A subtitle is found by sitting beside the film under the right
            // name, so adding one is an upload with the name decided here.
            .fileImporter(isPresented: Binding(get: { subtitlesFor != nil }, set: { if !$0 { subtitlesFor = nil } }),
                          allowedContentTypes: [.item]) { result in
                guard let video = subtitlesFor, case .success(let file) = result else { return }
                subtitlesFor = nil
                if !SubtitleRules.isSubtitleFile(file.lastPathComponent) {
                    app.show("Subtitles have to be a .srt or .vtt file")
                    return
                }
                let request = PromptRequest(
                    title: "Add subtitles", placeholder: "en, nl, de… (blank for none)",
                    initial: SubtitleRules.guessLanguage(file.lastPathComponent),
                    message: "The language code the player shows for this track.", confirm: "Add"
                ) { language in
                    let name = SubtitleRules.fileName(forVideo: video.name, language: language,
                                                      extension: Paths.extensionOf(file.lastPathComponent))
                    app.attachSubtitle(file, to: video, named: name)
                }
                // After the document picker has finished leaving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { prompt = request }
            }
    }
}

/// Choose a destination by browsing, not by typing a path. Folders only.
struct FolderPicker: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State var path: String
    let confirm: String
    let onPick: (String) -> Void
    @State private var folders: [FileEntry] = []
    @State private var loading = true
    @State private var error: String?

    init(startAt: String, confirm: String, onPick: @escaping (String) -> Void) {
        _path = State(initialValue: startAt)
        self.confirm = confirm
        self.onPick = onPick
    }

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    MessageView(systemImage: "exclamationmark.triangle", title: "Could not list this folder", detail: error)
                } else if folders.isEmpty {
                    MessageView(systemImage: "folder", title: "No folders here", detail: "Items will go into this one.")
                } else {
                    List(folders) { folder in
                        Button { path = folder.path } label: {
                            Label(folder.name, systemImage: "folder.fill").foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle(path == "/" ? "Root" : Paths.nameOf(path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
                        onPick(path)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if path != "/" {
                        Button { path = Paths.parentOf(path) } label: { Label("Up one folder", systemImage: "arrow.up") }
                    }
                }
            }
            .task(id: path) {
                loading = true
                error = nil
                do { folders = try await app.api.list(path).filter(\.isDirectory) } catch { self.error = describe(error) }
                loading = false
            }
        }
    }
}

/// Size, type, when it changed and where it lives -- and, from the viewer,
/// what the photo says about itself.
struct PropertiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: FileEntry
    let photo: PhotoDetails?

    var body: some View {
        NavigationView {
            List {
                if let photo {
                    row("Taken", photo.taken)
                    row("Dimensions", photo.dimensions)
                    row("Camera", photo.camera)
                    row("Exposure", photo.exposure)
                }
                row("Type", entry.kindDescription)
                if !entry.isDirectory { row("Size", Format.bytes(entry.size)) }
                row("Modified", entry.modified.isEmpty ? nil : entry.modified)
                row("Location", entry.parent)
                row("Full path", entry.path)
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .mediumDetents()
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

/// What the photo viewer reads from the cached bytes, formatted by PhotoFacts.
struct PhotoDetails {
    var taken: String?
    var dimensions: String?
    var camera: String?
    var exposure: String?

    static func read(_ data: Data) -> PhotoDetails? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var width = props[kCGImagePropertyPixelWidth] as? Int
        var height = props[kCGImagePropertyPixelHeight] as? Int
        // Stored as the sensor saw it, with a note saying to turn it.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, [5, 6, 7, 8].contains(orientation) {
            swap(&width, &height)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        return PhotoDetails(
            taken: PhotoFacts.taken((exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)),
            dimensions: PhotoFacts.dimensions(width: width, height: height),
            camera: PhotoFacts.camera(make: tiff?[kCGImagePropertyTIFFMake] as? String, model: tiff?[kCGImagePropertyTIFFModel] as? String),
            exposure: PhotoFacts.exposure(
                fNumber: exif?[kCGImagePropertyExifFNumber] as? Double,
                seconds: exif?[kCGImagePropertyExifExposureTime] as? Double,
                iso: iso,
                focalMm: exif?[kCGImagePropertyExifFocalLength] as? Double))
    }
}

/// A share link is a public URL: anyone holding it can open the file without
/// an account, so the link, its lifetime and the way to revoke it are shown.
struct ShareLinkSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let entry: FileEntry
    @State private var hours: Int? = 24
    @State private var link: CloudHubCore.ShareLink?
    @State private var busy = false
    @State private var error: String?
    @State private var shareURL: URL?

    private let lifetimes: [(String, Int?)] = [("1 hour", 1), ("1 day", 24), ("1 week", 168), ("30 days", 720), ("Never", nil)]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Anyone with this link can view \(entry.name) without signing in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Expires after") {
                    Picker("Lifetime", selection: $hours) {
                        ForEach(lifetimes, id: \.0) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: hours) { _ in create() }
                }
                Section {
                    if busy {
                        ProgressView()
                    } else if let error {
                        Text(error).foregroundStyle(Brand.danger)
                    } else if let link {
                        Text(link.url).font(.footnote.monospaced()).textSelection(.enabled)
                        Text(link.expiresAt.map { "Expires \($0)" } ?? "Does not expire")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = link.url
                            app.show("Link copied")
                            dismiss()
                        } label: { Label("Copy link", systemImage: "doc.on.doc") }
                        if let url = URL(string: link.url) {
                            Button { shareURL = url } label: { Label("Share link…", systemImage: "square.and.arrow.up") }
                        }
                        Button(role: .destructive) {
                            Task {
                                _ = try? await app.api.revokeShare(link.token)
                                app.show("Link revoked")
                                dismiss()
                            }
                        } label: { Label("Revoke", systemImage: "link.badge.plus") }
                    }
                }
            }
            .navigationTitle("Share link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .mediumDetents()
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            ActivitySheet(items: [shareURL as Any])
        }
        .task { create() }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            do { link = try await app.api.createShare(entry.path, expiresInHours: hours) } catch { self.error = describe(error) }
            busy = false
        }
    }
}

/// Quick Look, for everything the app has no viewer of its own for.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// The camera, at full resolution. Unlike Android, iOS asks for the camera
/// (and, for video, the microphone) the first time this opens.
struct CameraPicker: UIViewControllerRepresentable {
    enum Mode: String, Identifiable {
        case photo, video
        var id: String { rawValue }
    }

    enum Captured {
        case photo(Data, String)
        case video(URL, String)
    }

    let mode: Mode
    let onDone: (Captured?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [mode == .photo ? UTType.image.identifier : UTType.movie.identifier]
        if mode == .video {
            picker.cameraCaptureMode = .video
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (Captured?) -> Void
        init(onDone: @escaping (Captured?) -> Void) { self.onDone = onDone }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let stamp = Self.stamp()
            if let url = info[.mediaURL] as? URL {
                onDone(.video(url, "VID_\(stamp).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased())"))
            } else if let image = info[.originalImage] as? UIImage {
                let metadata = info[.mediaMetadata] as? [CFString: Any]
                guard let data = Self.jpeg(image, metadata: metadata) else { return onDone(nil) }
                onDone(.photo(data, "IMG_\(stamp).jpg"))
            } else {
                onDone(nil)
            }
        }

        /// The camera's own metadata kept -- the time, the exposure -- with the
        /// orientation it was shot at.
        static func jpeg(_ image: UIImage, metadata: [CFString: Any]?) -> Data? {
            guard let cg = image.cgImage else { return image.jpegData(compressionQuality: 0.92) }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            var properties = metadata ?? [:]
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
            properties[kCGImagePropertyOrientation] = cgOrientation(image.imageOrientation).rawValue
            CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }

        static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
            switch o {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            case .upMirrored: return .upMirrored
            case .downMirrored: return .downMirrored
            case .leftMirrored: return .leftMirrored
            case .rightMirrored: return .rightMirrored
            @unknown default: return .up
            }
        }

        static func stamp() -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd_HHmmss"
            return f.string(from: Date())
        }
    }
}
