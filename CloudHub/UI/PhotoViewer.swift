import CloudHubCore
import SwiftUI
import UIKit

/// The immersive photo viewer: swipe between photos, pinch and double-tap to
/// zoom, Share, Download, Details and More.
///
/// The pager is a UIPageViewController and each page a zooming UIScrollView --
/// the arrangement Photos itself uses -- so a photo that fits the screen hands
/// a sideways drag to the pager, and a zoomed one keeps it until its edge
/// reaches the screen's.
struct PhotoViewer: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var photos: [FileEntry]
    @State private var index: Int
    @State private var chrome = true
    @State private var details: FileEntry?
    @State private var detailFacts: PhotoDetails?
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var deleting: FileEntry?
    @State private var shareItem: ShareItem?
    /// The public link is a different thing from sending the photo.
    @State private var linkFor: FileEntry?
    @State private var preparing = false
    /// A rename or delete changed the folder underneath.
    @State private var changed = false

    init(images: [FileEntry], startAt: Int) {
        _photos = State(initialValue: images)
        _index = State(initialValue: min(max(startAt, 0), max(0, images.count - 1)))
    }

    private var current: FileEntry? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoPager(photos: photos, index: $index, onTap: { withAnimation(fade) { chrome.toggle() } },
                       onZoomed: { if chrome { withAnimation(fade) { chrome = false } } })
                .ignoresSafeArea()

            if chrome, let current {
                VStack(spacing: 0) {
                    topBar(current)
                    Spacer()
                    bottomBar(current)
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .toastOverlay()
        // Photos and a queued upload share one connection: while this is up
        // the uploader sends small slices and waits between them.
        .onAppear { ForegroundMedia.enter() }
        .onDisappear {
            ForegroundMedia.leave()
            if changed { app.files.refresh() }
            app.reveal = current?.path
        }
        .sheet(item: $details) { entry in
            PropertiesSheet(entry: entry, photo: detailFacts)
        }
        .sheet(item: $linkFor) { entry in
            ShareLinkSheet(entry: entry).environment(app)
        }
        .sheet(item: $shareItem) { item in
            ActivitySheet(items: [item.url]).presentationDetents([.medium, .large])
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { entry in
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(entry, to: renameText.trimmingCharacters(in: .whitespaces)) }
        }
        .confirmationDialog("Delete this photo?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
        } message: { entry in
            Text("\(entry.name) goes to the trash, where it can be restored — unless this server is set to delete files permanently.")
        }
    }

    private var fade: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }

    /* ---- the controls ------------------------------------------------------ */

    private func topBar(_ entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline).lineLimit(1)
                if let counter = ViewerRules.counter(index: index, count: photos.count) {
                    Text(counter).font(.caption).opacity(0.8)
                }
            }
            Spacer()
            Button { app.files.toggleFavorite(entry) } label: {
                let starred = app.files.favorites.contains(entry.path)
                Image(systemName: starred ? "star.fill" : "star")
                    .foregroundStyle(starred ? Brand.favorite : .white)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(app.files.favorites.contains(entry.path) ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.horizontal, 8)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func bottomBar(_ entry: FileEntry) -> some View {
        HStack {
            action("Share", "square.and.arrow.up") { share(entry) }.disabled(preparing)
            action("Download", "arrow.down.circle") { app.download(entry) }
            action("Details", "info.circle") { showDetails(entry) }
            Menu {
                Button { linkFor = entry } label: { Label("Share link…", systemImage: "link") }
                if app.files.canWrite {
                    Divider()
                    Button {
                        renameText = entry.name
                        renaming = entry
                    } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle").font(.title3)
                    Text("More").font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .overlay(alignment: .top) { if preparing { ProgressView().tint(.white).offset(y: -24) } }
    }

    private func action(_ label: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /* ---- what they do ------------------------------------------------------ */

    /// The photo itself, not a link: usually already in the cache.
    private func share(_ entry: FileEntry) {
        preparing = true
        Task {
            do { shareItem = ShareItem(url: try await app.localCopy(of: entry)) } catch {
                app.show("Could not get \(entry.name) ready: \(describe(error))")
            }
            preparing = false
        }
    }

    /// Read from the cached bytes, so asking costs no request.
    private func showDetails(_ entry: FileEntry) {
        let url = app.api.previewURL(entry.path, version: entry.modified)
        detailFacts = app.images.cachedData(for: url).flatMap(PhotoDetails.read)
        details = entry
    }

    /// Delete, then offer Undo while the message is up.
    private func delete(_ entry: FileEntry) {
        guard let at = photos.firstIndex(where: { $0.path == entry.path }) else { return }
        Task {
            do {
                let result = try await app.api.delete(entry.path)
                changed = true
                let said = result.message.isEmpty ? (result.trashed ? "Moved to trash" : "Deleted") : result.message
                photos = ViewerRules.without(photos, path: entry.path)
                if photos.isEmpty {
                    app.show(said)
                    dismiss()
                    return
                }
                index = ViewerRules.pageAfterRemoval(index: index, remaining: photos.count)
                if result.trashed, let trashId = result.id {
                    app.show(said, action: "Undo") { undo(entry, trashId: trashId, at: at) }
                } else {
                    app.show(said)
                }
            } catch {
                app.show(describe(error, fallback: "That did not work"))
            }
        }
    }

    private func undo(_ entry: FileEntry, trashId: String, at: Int) {
        Task {
            do {
                let back = try await app.api.restore(trashId)
                var restored = entry
                restored.path = back.path ?? entry.path
                restored.name = Paths.nameOf(restored.path)
                photos = ViewerRules.restored(photos, restored, at: at)
                index = photos.firstIndex { $0.path == restored.path } ?? index
                app.show(back.message.isEmpty ? "Restored" : back.message)
            } catch {
                app.show(describe(error, fallback: "Could not undo that. It is in the trash."))
            }
        }
    }

    private func rename(_ entry: FileEntry, to newName: String) {
        guard isRename(current: entry.name, requested: newName) else { return }
        let asked = Paths.join(entry.parent, newName)
        Task {
            do {
                let result = try await app.api.rename(from: entry.path, to: asked)
                changed = true
                let path = result.path ?? asked
                photos = ViewerRules.renamed(photos, old: entry, newPath: path, newName: result.name ?? Paths.nameOf(path))
                let said = result.message.isEmpty ? "Renamed" : result.message
                if photos.isEmpty {
                    app.show(said)
                    dismiss()
                    return
                }
                index = ViewerRules.pageAfterRemoval(index: index, remaining: photos.count)
                app.show(said)
            } catch {
                app.show(describe(error, fallback: "That did not work"))
            }
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, for the photo's own bytes.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/* ---- the pager ------------------------------------------------------------- */

private struct PhotoPager: UIViewControllerRepresentable {
    @Environment(AppEnvironment.self) private var app
    let photos: [FileEntry]
    @Binding var index: Int
    let onTap: () -> Void
    let onZoomed: () -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 16])
        pager.view.backgroundColor = .black
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        if let page = context.coordinator.page(at: index) {
            pager.setViewControllers([page], direction: .forward, animated: false)
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // A delete or a rename changed the row; show what is now at `index`.
        let shown = (pager.viewControllers?.first as? PhotoPageController)?.entry
        guard photos.indices.contains(index), shown?.path != photos[index].path || shown?.name != photos[index].name,
              let page = context.coordinator.page(at: index) else { return }
        pager.setViewControllers([page], direction: .forward, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager

        init(parent: PhotoPager) { self.parent = parent }

        func page(at i: Int) -> PhotoPageController? {
            guard parent.photos.indices.contains(i) else { return nil }
            let entry = parent.photos[i]
            return PhotoPageController(entry: entry, app: parent.app,
                                       onTap: { [weak self] in self?.parent.onTap() },
                                       onZoomed: { [weak self] in self?.parent.onZoomed() })
        }

        private func indexOf(_ controller: UIViewController) -> Int? {
            guard let page = controller as? PhotoPageController else { return nil }
            return parent.photos.firstIndex { $0.path == page.entry.path }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            indexOf(viewController).flatMap { page(at: $0 - 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            indexOf(viewController).flatMap { page(at: $0 + 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let shown = pageViewController.viewControllers?.first, let i = indexOf(shown) else { return }
            parent.index = i
        }
    }
}

/// One photo: the grid's thumbnail at once, then the photo at screen size,
/// then -- zoomed past 1.3x -- a sharper decode for the photo on show.
final class PhotoPageController: UIViewController, UIScrollViewDelegate {
    let entry: FileEntry
    private let app: AppEnvironment
    private let onTap: () -> Void
    private let onZoomed: () -> Void
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failure = UILabel()
    private var sharpened = false
    private var animatedPhoto = false
    private var loadTask: Task<Void, Never>?

    init(entry: FileEntry, app: AppEnvironment, onTap: @escaping () -> Void, onZoomed: @escaping () -> Void) {
        self.entry = entry
        self.app = app
        self.onTap = onTap
        self.onZoomed = onZoomed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        view.addSubview(scroll)

        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = entry.name
        scroll.addSubview(imageView)

        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)

        failure.textColor = .white
        failure.numberOfLines = 0
        failure.textAlignment = .center
        failure.frame = view.bounds.insetBy(dx: 32, dy: 0)
        failure.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        failure.isHidden = true
        view.addSubview(failure)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        single.require(toFail: double)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)

        load()
    }

    private func load() {
        failure.isHidden = true
        let thumb = app.api.thumbnailURL(entry)
        let full = app.api.previewURL(entry.path, version: entry.modified)
        let screenPixels = max(view.bounds.width, view.bounds.height) * UIScreen.main.scale
        // The grid's thumbnail stands in, usually still in memory.
        if let placeholder = app.images.memoryImage(for: thumb, maxPixels: 104 * UIScreen.main.scale) {
            imageView.image = placeholder
        }
        if imageView.image == nil { spinner.startAnimating() }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.app.images.data(for: full)
                if self.entry.ext == "gif" || self.entry.ext == "webp",
                   let animated = ImageLoader.animated(data, maxPixels: screenPixels) {
                    self.animatedPhoto = true
                    self.imageView.image = animated
                } else {
                    self.imageView.image = try await self.app.images.image(for: full, maxPixels: screenPixels)
                }
                self.spinner.stopAnimating()
            } catch {
                guard !Task.isCancelled else { return }
                self.spinner.stopAnimating()
                self.imageView.image = nil
                self.failure.text = "\(self.entry.name) could not be loaded.\n\(describe(error))\n\nTap twice to retry."
                self.failure.isHidden = false
            }
        }
    }

    deinit { loadTask?.cancel() }

    @objc private func tapped() { onTap() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if !failure.isHidden {
            load()
            return
        }
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
            return
        }
        // Far enough to fill the screen, so a landscape photo loses its bands.
        let fill = fillScale()
        let scale = min(scroll.maximumZoomScale, max(2, fill))
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                    animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func fillScale() -> CGFloat {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return 2 }
        let bounds = scroll.bounds.size
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fill = max(bounds.width / image.size.width, bounds.height / image.size.height)
        return fill / fit
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centreImage()
        if scrollView.zoomScale > 1.05 { onZoomed() }
        if scrollView.zoomScale > 1.3 { sharpen() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.zoomScale <= 1.001 { imageView.frame = scroll.bounds }
        centreImage()
    }

    /// Pan only over the photo as drawn, not into its own black bars.
    private func centreImage() {
        guard let image = imageView.image, image.size.width > 0 else { return }
        let bounds = scroll.bounds.size
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let drawn = CGSize(width: image.size.width * fit * scroll.zoomScale, height: image.size.height * fit * scroll.zoomScale)
        let barX = max(0, (scroll.contentSize.width - drawn.width) / 2)
        let barY = max(0, (scroll.contentSize.height - drawn.height) / 2)
        let padX = max(0, (bounds.width - drawn.width) / 2)
        let padY = max(0, (bounds.height - drawn.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: padY - barY, left: padX - barX, bottom: padY - barY, right: padX - barX)
    }

    /// Up to 4096 px on the long edge, from the bytes already cached, and
    /// never for an animation.
    private func sharpen() {
        guard !sharpened, !animatedPhoto else { return }
        sharpened = true
        let full = app.api.previewURL(entry.path, version: entry.modified)
        Task { [weak self] in
            guard let self, let data = self.app.images.cachedData(for: full) else { return }
            let sharp = await Task.detached(priority: .userInitiated) { ImageLoader.downsample(data, maxPixels: 4096) }.value
            if let sharp { self.imageView.image = sharp }
        }
    }
}
