import CloudHubCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The file browser. Grid by default because a phone showing photos wants
/// pictures; the list is there for folders of documents.
struct FilesView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var search = ""
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var relocating: Relocation?
    @State private var properties: FileEntry?
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var capture: CameraPicker.Mode?
    @State private var subtitlesFor: FileEntry?
    @State private var subtitleFile: URL?
    @State private var subtitleLanguage = ""
    @State private var showingUploads = false
    @State private var skeletonAllowed = false

    private var model: FilesModel { app.files }

    struct Relocation: Identifiable {
        let id = UUID()
        let paths: [String]
        let moving: Bool
    }

    var body: some View {
        content
            .navigationTitle(model.path == "/" ? "CloudHub" : Paths.nameOf(model.path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
            .onSubmit(of: .search) { model.searchEverywhere() }
            .onChange(of: search) { _, q in model.setQuery(q) }
            .onChange(of: model.query) { _, q in if q != search { search = q } }
            .refreshable { model.refresh() }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .onChange(of: model.message) { _, message in
                if let message {
                    app.show(message)
                    model.message = nil
                }
            }
            .onChange(of: model.grid) { _, grid in app.prefs.gridView = grid }
            // Skeletons only for a load that takes a moment: a folder that
            // lists in 40 ms never shows one.
            .task(id: model.loading) {
                skeletonAllowed = false
                guard model.loading else { return }
                try? await Task.sleep(nanoseconds: SkeletonTiming.delayMs * 1_000_000)
                skeletonAllowed = true
            }
            .modifier(FileDialogs(
                showingNewFolder: $showingNewFolder, newFolderName: $newFolderName,
                renaming: $renaming, renameText: $renameText,
                relocating: $relocating, properties: $properties,
                subtitlesFor: $subtitlesFor, subtitleFile: $subtitleFile, subtitleLanguage: $subtitleLanguage))
            .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 50,
                          matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await stagePicked(items) }
            }
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let picked: [(url: URL, name: String)] = urls.map { (url: $0, name: $0.lastPathComponent) }
                    app.enqueue(picked)
                }
            }
            .fullScreenCover(item: $capture) { mode in
                CameraPicker(mode: mode) { captured in
                    capture = nil
                    switch captured {
                    case .photo(let data, let name): app.enqueue(data: data, name: name)
                    case .video(let url, let name): app.enqueue([(url, name)])
                    case nil: break
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingUploads) { UploadsSheet().environment(app) }
    }

    /* ---- content ----------------------------------------------------------- */

    @ViewBuilder private var content: some View {
        switch model.shown {
        case .skeleton:
            if skeletonAllowed { SkeletonGrid(grid: model.grid) } else { Color.clear }
        case .error:
            MessageView(systemImage: "icloud.slash", title: "Could not load this folder",
                        detail: model.loadError ?? "The server did not answer.",
                        actionLabel: "Retry", action: { model.retry() })
        case .empty:
            if model.canWrite {
                MessageView(systemImage: "folder", title: "This folder is empty",
                            detail: "Add files with the + button, or create a folder to organise them.",
                            actionLabel: "Create a folder",
                            action: { showingNewFolder = true })
            } else {
                MessageView(systemImage: "folder", title: "This folder is empty",
                            detail: "Nothing has been put here yet.")
            }
        case .noMatches:
            noMatches
        case .content:
            EntryCollection(
                entries: model.visible,
                onOpen: open,
                menu: { AnyView(menu(for: $0)) }
            )
        }
    }

    @ViewBuilder private var noMatches: some View {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        if model.searching {
            MessageView(systemImage: "magnifyingglass", title: "Searching…",
                        detail: "Looking in every folder for \u{201C}\(query)\u{201D}.")
        } else if model.searchMode {
            MessageView(systemImage: "magnifyingglass", title: "Nothing matched",
                        detail: "Check the spelling, or try part of the name.")
        } else if SearchRules.canSearch(query) {
            MessageView(systemImage: "magnifyingglass", title: "Nothing matched",
                        detail: "No file here is called \u{201C}\(query)\u{201D}. Try All folders to search everywhere.",
                        actionLabel: "Search all folders",
                        action: { model.searchEverywhere() })
        } else {
            MessageView(systemImage: "magnifyingglass", title: "Nothing matched",
                        detail: "No file here is called \u{201C}\(query)\u{201D}.")
        }
    }

    private func open(_ entry: FileEntry) {
        if !model.selected.isEmpty {
            model.toggleSelected(entry.path)
            return
        }
        app.open(entry, among: model.visible)
    }

    /* ---- around the content ----------------------------------------------- */

    @ViewBuilder private var header: some View {
        VStack(spacing: 0) {
            if model.searchMode {
                HStack {
                    if model.searching { ProgressView().controlSize(.small) }
                    Text(SearchRules.summary(query: model.query.trimmingCharacters(in: .whitespaces),
                                             count: model.searchResults?.count ?? 0, truncated: model.searchTruncated,
                                             scanned: model.searchScanned, searching: model.searching, error: model.searchError))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.clearSearch() }.font(.footnote)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if SearchRules.canSearch(model.query) {
                Button { model.searchEverywhere() } label: {
                    Label("Search all folders for \u{201C}\(model.query.trimmingCharacters(in: .whitespaces))\u{201D}", systemImage: "magnifyingglass")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if model.path != "/" {
                Breadcrumbs(path: model.path) { model.open($0) }
            }
            if model.loading && model.shown == .content {
                ProgressView().progressViewStyle(.linear).tint(Brand.primary)
            }
        }
        .background(.bar)
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 8) {
            if !model.selected.isEmpty {
                SelectionBar(
                    count: model.selected.count,
                    canWrite: model.canWrite,
                    onClear: model.clearSelection,
                    onMove: { relocating = Relocation(paths: Array(model.selected), moving: true) },
                    onCopy: { relocating = Relocation(paths: Array(model.selected), moving: false) },
                    onDelete: { model.delete(Array(model.selected)) }
                )
            }
            if app.uploads.visible {
                UploadTrackerBar { showingUploads = true }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .animation(.snappy, value: model.selected.isEmpty)
        .animation(.snappy, value: app.uploads.visible)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.path != "/" {
                Button { model.goUp() } label: {
                    Label(Paths.parentOf(model.path) == "/" ? "Root" : Paths.nameOf(Paths.parentOf(model.path)),
                          systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Up one folder")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.canWrite {
                Menu {
                    Button { pickingPhotos = true } label: { Label("Photos & videos", systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { capture = .photo } label: { Label("Take a photo", systemImage: "camera") }
                        Button { capture = .video } label: { Label("Record a video", systemImage: "video") }
                    }
                    Button { pickingFiles = true } label: { Label("Any file", systemImage: "doc.badge.plus") }
                    Divider()
                    Button {
                        newFolderName = ""
                        showingNewFolder = true
                    } label: { Label("New folder", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to this folder")
            }
            Button { model.grid.toggle() } label: {
                Image(systemName: model.grid ? "list.bullet" : "square.grid.2x2")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(model.grid ? "Switch to list view" : "Switch to grid view")
            Menu {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Picker(selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    Label("Name", systemImage: "textformat").tag(FileSort.name)
                    Label("Natural Number", systemImage: "list.number").tag(FileSort.natural)
                    Label("Newest", systemImage: "clock").tag(FileSort.newest)
                    Label("Largest", systemImage: "chart.pie").tag(FileSort.largest)
                } label: {
                    Label("Sort by \(model.sort.label)", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                Divider()
                Button { app.path.append(.favorites) } label: { Label("Favorites", systemImage: "star") }
                Button { app.path.append(.trash) } label: { Label("Trash", systemImage: "trash") }
                Button { app.path.append(.storage) } label: { Label("Storage", systemImage: "chart.pie") }
                Button { app.path.append(.duplicates) } label: { Label("Duplicates", systemImage: "square.on.square") }
                Button { app.path.append(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                Divider()
                Button(role: .destructive) { app.signOut() } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    /* ---- a file's menu ------------------------------------------------------ */

    @ViewBuilder private func menu(for entry: FileEntry) -> some View {
        Button { open(entry) } label: {
            Label(entry.isDirectory ? "Open" : "Preview", systemImage: entry.isDirectory ? "folder" : "eye")
        }
        Button { model.toggleSelected(entry.path) } label: {
            Label(model.selected.contains(entry.path) ? "Deselect" : "Select", systemImage: "checkmark.circle")
        }
        if model.searchResults != nil {
            Button { model.open(entry.isDirectory ? entry.path : entry.parent) } label: {
                Label("Show in folder", systemImage: "folder")
            }
        }
        if !entry.isDirectory {
            Button { app.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
            Button { app.sharing = entry } label: { Label("Share link", systemImage: "link") }
            Button { model.toggleFavorite(entry) } label: {
                model.favorites.contains(entry.path)
                    ? Label("Remove from favorites", systemImage: "star.slash")
                    : Label("Add to favorites", systemImage: "star")
            }
        }
        if model.canWrite {
            if entry.kind == .video {
                Button { subtitlesFor = entry } label: { Label("Add subtitles…", systemImage: "captions.bubble") }
            }
            Button {
                renameText = entry.name
                renaming = entry
            } label: { Label("Rename", systemImage: "pencil") }
            Button { relocating = Relocation(paths: [entry.path], moving: true) } label: {
                Label("Move to…", systemImage: "folder.badge.gearshape")
            }
            Button { relocating = Relocation(paths: [entry.path], moving: false) } label: {
                Label("Copy to…", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) { model.delete([entry.path]) } label: { Label("Delete", systemImage: "trash") }
        }
        Button { properties = entry } label: { Label("Properties", systemImage: "info.circle") }
    }

    /* ---- picked photos ----------------------------------------------------- */

    private func stagePicked(_ items: [PhotosPickerItem]) async {
        var files: [(URL, String)] = []
        for item in items {
            if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                files.append((picked.url, picked.url.lastPathComponent))
            }
        }
        if files.isEmpty {
            app.show("Nothing could be read from that")
            return
        }
        app.enqueue(files.map { (url: $0.0, name: $0.1) })
        for (url, _) in files { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

/// The grid or list of entries, with each one's context menu, coming back to
/// the file a viewer was closed on.
private struct EntryCollection: View {
    @Environment(AppEnvironment.self) private var app
    let entries: [FileEntry]
    let onOpen: (FileEntry) -> Void
    let menu: (FileEntry) -> AnyView

    var body: some View {
        let model = app.files
        ScrollViewReader { proxy in
            Group {
                if model.grid {
                    ScrollView {
                        LazyVGrid(columns: FilesLayout.columns, spacing: 16) {
                            ForEach(entries) { entry in
                                Button { onOpen(entry) } label: {
                                    FileTile(entry: entry, selected: model.selected.contains(entry.path),
                                             favorite: model.favorites.contains(entry.path))
                                }
                                .buttonStyle(PressStyle())
                                .contextMenu { menu(entry) }
                                .id(entry.path)
                            }
                        }
                        .padding(16)
                        .animation(.snappy, value: entries.map(\.path))
                    }
                } else {
                    List(entries) { entry in
                        Button { onOpen(entry) } label: {
                            FileRow(entry: entry, selected: model.selected.contains(entry.path),
                                    favorite: model.favorites.contains(entry.path))
                        }
                        .foregroundStyle(.primary)
                        .contextMenu { menu(entry) }
                        .swipeActions(edge: .trailing) {
                            if model.canWrite {
                                Button(role: .destructive) { model.delete([entry.path]) } label: { Label("Delete", systemImage: "trash") }
                            }
                            if !entry.isDirectory {
                                Button { model.toggleFavorite(entry) } label: { Label("Favorite", systemImage: "star") }
                                    .tint(Brand.favorite)
                            }
                        }
                        .id(entry.path)
                    }
                    .listStyle(.plain)
                }
            }
            .onChange(of: app.reveal) { _, path in
                guard let path, entries.contains(where: { $0.path == path }) else { return }
                withAnimation { proxy.scrollTo(path, anchor: .center) }
                app.reveal = nil
            }
        }
    }
}

/// Cards give slightly under the finger.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Root › Photos › 2024 -- each one a target.
private struct Breadcrumbs: View {
    let path: String
    let onOpen: (String) -> Void

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("Root") { onOpen("/") }
                    ForEach(parts.indices, id: \.self) { i in
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        let target = "/" + parts[0...i].joined(separator: "/")
                        Button(parts[i]) { onOpen(target) }
                            .fontWeight(i == parts.count - 1 ? .semibold : .regular)
                            .foregroundStyle(i == parts.count - 1 ? Color.primary : Brand.primary)
                            .id(i)
                    }
                }
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(parts.count - 1, anchor: .trailing) }
            .onChange(of: path) { proxy.scrollTo(parts.count - 1, anchor: .trailing) }
        }
    }
}

private struct SelectionBar: View {
    let count: Int
    let canWrite: Bool
    let onClear: () -> Void
    let onMove: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onClear) { Image(systemName: "xmark") }.accessibilityLabel("Clear selection")
            Text("\(count) selected").font(.subheadline.weight(.medium))
            Spacer()
            if canWrite {
                Button("Move", action: onMove)
                Button("Copy", action: onCopy)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A file from the photo library, copied out while the picker still allows it.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try PickedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try PickedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .item) { try PickedFile(copying: $0.file) }
    }

    /// The picker's file lives only as long as the closure; it is copied into
    /// a folder of its own so its name survives.
    init(copying source: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        url = target
    }
}
