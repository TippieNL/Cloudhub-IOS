import CloudHubCore
import SwiftUI

/// Deleted items, restorable until the trash is emptied or they age out.
struct TrashView: View {
    @EnvironmentObject private var app: AppEnvironment
    @State private var listing: TrashListing?
    @State private var error: String?
    @State private var confirmingEmpty = false

    var body: some View {
        Group {
            if let error, listing == nil {
                MessageView(systemImage: "exclamationmark.triangle", title: "Could not read the trash", detail: error,
                            actionLabel: "Retry") { Task { await load() } }
            } else if let listing {
                List {
                    Section {
                        Text(!listing.enabled ? "This server deletes files permanently; nothing is kept here."
                             : listing.retentionDays > 0 ? "Deleted items are kept for \(listing.retentionDays) days."
                             : "Deleted items are kept until the trash is emptied.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if listing.entries.isEmpty {
                        Text("The trash is empty.").foregroundStyle(.secondary)
                    }
                    ForEach(listing.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                            Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if app.files.canWrite {
                                Button(role: .destructive) { act { _ = try await app.api.purge(entry.id) } } label: {
                                    Label("Delete forever", systemImage: "trash.slash")
                                }
                                Button { act { _ = try await app.api.restore(entry.id); app.show("Restored \(entry.name)") } } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(Brand.primary)
                            }
                        }
                        .contextMenu {
                            if app.files.canWrite {
                                Button { act { _ = try await app.api.restore(entry.id); app.show("Restored \(entry.name)") } } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) { act { _ = try await app.api.purge(entry.id) } } label: {
                                    Label("Delete forever", systemImage: "trash.slash")
                                }
                            }
                        }
                    }
                }
                .refreshable { await load() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Trash")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if app.files.canWrite, !(listing?.entries.isEmpty ?? true) {
                    Button("Empty", role: .destructive) { confirmingEmpty = true }
                }
            }
        }
        .confirmationDialog("Empty the trash?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Empty the trash", role: .destructive) { act { _ = try await app.api.emptyTrash() } }
        } message: {
            Text("Everything in it is deleted for good.")
        }
        .task { await load() }
        .onDisappear { app.files.refresh() }
    }

    private func detail(_ entry: TrashEntry) -> String {
        var text = entry.isDirectory ? "Folder · \(entry.files) files" : Format.bytes(entry.bytes)
        text += " · from \(Paths.parentOf(entry.originalPath))"
        if let by = entry.deletedBy { text += " · by \(by)" }
        if !entry.deletedAt.isEmpty { text += " · \(shortDate(entry.deletedAt))" }
        return text
    }

    private func load() async {
        do {
            listing = try await app.api.trash()
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { app.show(describe(error)) }
            await load()
        }
    }
}

/// Starred files, most recently starred first, filtered by kind.
struct FavoritesView: View {
    @EnvironmentObject private var app: AppEnvironment
    @State private var chosen: KindFilter = .all

    var body: some View {
        let model = app.files
        let entries = model.favoriteEntries
        let filter = FavoriteRules.effective(chosen, entries)
        let shown = entries.filter(filter.matches)
        let counts = FavoriteRules.counts(entries)

        Group {
            if model.favoritesLoad == .failed && entries.isEmpty {
                MessageView(systemImage: "star.slash", title: "Could not load your favorites",
                            detail: model.favoritesError ?? "The server did not answer.", actionLabel: "Retry", action: { model.loadFavorites() })
            } else if model.favoritesLoad == .loading && entries.isEmpty {
                ProgressView()
            } else if entries.isEmpty {
                MessageView(systemImage: "star", title: "No favorites yet",
                            detail: "Star a photo, a video or any file from its menu, or from the viewer, and it will be kept here.")
            } else {
                ScrollView {
                    Picker("Show", selection: $chosen) {
                        ForEach(KindFilter.allCases) { f in
                            Text("\(f.label) (\(counts[f] ?? 0))").tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    LazyVGrid(columns: FilesLayout.columns, spacing: 16) {
                        ForEach(shown) { entry in
                            Button { app.open(entry, among: shown) } label: {
                                FileTile(entry: entry, selected: false, favorite: true)
                            }
                            .buttonStyle(PressStyle())
                            .contextMenu {
                                Button {
                                    // The folder is asked for first, so it is on its way by the time the list is back.
                                    model.open(entry.parent)
                                    app.reveal = entry.path
                                    app.route = nil
                                } label: { Label("Show in folder", systemImage: "folder") }
                                Button { app.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                Button { app.sharing = entry } label: { Label("Share link", systemImage: "link") }
                                Button(role: .destructive) { model.toggleFavorite(entry) } label: {
                                    Label("Remove from favorites", systemImage: "star.slash")
                                }
                            }
                        }
                    }
                    .padding(16)
                    .animation(.easeInOut(duration: 0.25), value: shown.map(\.path))
                }
                .refreshable { model.loadFavorites() }
            }
        }
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { model.loadFavorites() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
            }
        }
    }
}

/// How much is left, in words, above a bar -- against whichever ceiling applies.
struct StorageView: View {
    @EnvironmentObject private var app: AppEnvironment
    @State private var mine: MyStorage?
    @State private var server: ServerStorage?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Group {
            if let mine {
                List {
                    Section { meter(StorageMeter.of(mine)) }
                    Section("What is stored") {
                        line("Files", "\(mine.files)")
                        line("Folders", "\(mine.folders)")
                        if mine.quotaBytes > 0 { line("Your files", Format.bytes(mine.usedBytes)) }
                        line("In the trash", "\(Format.bytes(mine.trash.bytes)) · \(mine.trash.entries) item\(Format.plural(mine.trash.entries))")
                        line("Previous versions", "\(Format.bytes(mine.versions.bytes)) · \(mine.versions.files) file\(Format.plural(mine.versions.files))")
                    }
                    Section("The disk") {
                        line("Free", Format.bytes(mine.diskFreeBytes))
                        line("Total", Format.bytes(mine.diskTotalBytes))
                        if mine.storageLimitBytes > 0 { line("Store limit", Format.bytes(mine.storageLimitBytes)) }
                        if mine.quotaBytes > 0 { line("Your quota", Format.bytes(mine.quotaBytes)) }
                    }
                    if let server, !server.byUser.isEmpty {
                        Section("By account") {
                            ForEach(server.byUser, id: \.self) { u in
                                line(u.username ?? "Unknown", "\(Format.bytes(u.bytes)) · \(u.files) file\(Format.plural(u.files))")
                            }
                        }
                    }
                    if let server, !server.largest.isEmpty {
                        Section("Largest files") {
                            ForEach(server.largest, id: \.self) { f in line(Paths.nameOf(f.path), Format.bytes(f.bytes)) }
                        }
                    }
                    Section {
                        Text(mine.measuredAt.map { mine.cached ? "Measured \($0). Figures are cached between measurements." : "Measured just now." }
                             ?? "Measured just now.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .refreshable { await load(refresh: false) }
            } else if let error {
                MessageView(systemImage: "exclamationmark.triangle", title: "Could not read storage", detail: error,
                            actionLabel: "Retry") { Task { await load(refresh: false) } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Storage")
        .toolbar {
            // Walking the whole store stays an admin action.
            ToolbarItem(placement: .navigationBarTrailing) {
            if mine?.isAdmin == true {
                Button { Task { await load(refresh: true) } } label: {
                    if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("Recalculate")
                .disabled(busy)
            }
            }
        }
        .task { await load(refresh: false) }
    }

    private func meter(_ r: StorageMeter.Reading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Format.bytes(r.remainingBytes)) free").font(.title2.bold())
            ProgressView(value: r.fraction).tint(r.nearlyFull ? Brand.danger : Brand.primary)
            Text("\(Format.bytes(r.usedBytes)) of \(Format.bytes(r.totalBytes)) used · against \(against(r.against))")
                .font(.footnote).foregroundStyle(.secondary)
            if r.nearlyFull {
                Text("Nearly full. Emptying the trash or discarding old versions frees space.")
                    .font(.footnote).foregroundStyle(Brand.danger)
            }
        }
        .padding(.vertical, 6)
    }

    private func against(_ a: StorageMeter.Against) -> String {
        switch a {
        case .quota: return "your quota"
        case .store: return "the server's limit"
        case .disk: return "the disk, with no limit set"
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        LabeledRow(label, value: value)
    }

    private func load(refresh: Bool) async {
        busy = true
        do {
            let own = try await app.api.myStorage()
            mine = own
            error = nil
            // Only asked for when it will be allowed.
            if own.isAdmin {
                server = try? await app.api.serverStorage(refresh: refresh)
            } else {
                server = nil
            }
        } catch {
            self.error = describe(error)
        }
        busy = false
    }
}
