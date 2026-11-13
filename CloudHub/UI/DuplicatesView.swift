import CloudHubCore
import SwiftUI

/// The same photo, twice -- byte-for-byte, never merely similar.
///
/// The scan is a poll loop: the server does a slice of the work per request
/// and says how far it has got, so sets appear while it runs. Nothing is
/// deleted without being asked for, every set keeps a copy, and deleting goes
/// to the trash.
struct DuplicatesView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var scan: DuplicateScan?
    @State private var error: String?
    @State private var busy = true
    @State private var supported: Bool?
    @State private var minBytes: Int64?
    @State private var gaveUp = false
    @State private var keeping: [String: String] = [:]
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var chosen: KindFilter = .all
    @State private var scanTask: Task<Void, Never>?

    private var canWrite: Bool { app.files.canWrite }

    var body: some View {
        let found = scan?.groups ?? []
        let filter = DuplicateRules.effective(chosen, found)
        let groups = DuplicateRules.shown(found, filter)
        let picked = DuplicateRules.selected(in: groups, selected)
        let freed = DuplicateRules.freed(by: groups, selected: selected)
        let counts = DuplicateRules.counts(found)

        List {
            Section { header(groups) }
            if !found.isEmpty {
                Picker("Show", selection: $chosen) {
                    ForEach(KindFilter.allCases) { f in Text("\(f.label) (\(counts[f] ?? 0))").tag(f) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.self) { group in
                let id = DuplicateRules.groupId(group)
                let keeper = DuplicateRules.keeper(for: group, chosen: keeping[id])
                Section {
                    ForEach(group.files, id: \.path) { file in
                        let kept = file.path == keeper
                        HStack(spacing: 12) {
                            Thumbnail(entry: FileEntry(name: DuplicateRules.nameOf(file.path), path: file.path, size: file.bytes,
                                                       hasThumbnail: true), side: 44)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DuplicateRules.nameOf(file.path)).lineLimit(1)
                                Text(kept ? "In \(DuplicateRules.folderOf(file.path)) · kept" : "In \(DuplicateRules.folderOf(file.path))")
                                    .font(.caption).foregroundStyle(kept ? Brand.primary : .secondary).lineLimit(1)
                            }
                            Spacer()
                            if canWrite {
                                if kept {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("Kept")
                                } else {
                                    Button {
                                        if selected.contains(file.path) { selected.remove(file.path) } else { selected.insert(file.path) }
                                    } label: {
                                        Image(systemName: selected.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selected.contains(file.path) ? Brand.danger : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(selected.contains(file.path) ? "Deselect" : "Select for deletion")
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if canWrite && !kept {
                                Button("Keep") {
                                    keeping[id] = file.path
                                    selected.remove(file.path)
                                }
                                .tint(Brand.primary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(group.count) copies · \(Format.bytes(group.bytes)) each")
                        Spacer()
                        Text("\(Format.bytes(group.reclaimable)) to reclaim")
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { selected.formUnion(DuplicateRules.removable(in: groups, keeping: keeping)) } label: {
                    Image(systemName: "checklist.checked")
                }
                .accessibilityLabel("Select every extra copy")
                .disabled(!canWrite || groups.isEmpty)
                Button { runScan() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Scan again")
                    .disabled(!canWrite || busy || supported != true)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !picked.isEmpty {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(picked.count) selected").font(.subheadline.weight(.medium))
                        Text("\(Format.bytes(freed)) to reclaim").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { confirming = true } label: { Label("Move to trash", systemImage: "trash") }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.danger)
                }
                .padding(16)
                .background(.bar)
            }
        }
        .alert(DuplicateRules.wouldEmptyAGroup(groups, Set(picked)) ? "That would delete a file" : "Move \(picked.count) to the trash?",
               isPresented: $confirming) {
            if DuplicateRules.wouldEmptyAGroup(groups, Set(picked)) {
                Button("OK", role: .cancel) {}
            } else {
                Button("Cancel", role: .cancel) {}
                Button("Move to trash", role: .destructive) { delete(picked) }
            }
        } message: {
            Text(DuplicateRules.wouldEmptyAGroup(groups, Set(picked))
                 ? "One set has every copy selected, which would delete the file itself. Leave one copy of each unselected."
                 : "\(Format.bytes(freed)) will be reclaimed. Every set keeps a copy, and anything moved to the trash can be restored from there.")
        }
        .task { await start() }
        .onDisappear {
            scanTask?.cancel()
            app.files.refresh()
        }
    }

    @ViewBuilder private func header(_ shown: [DuplicateGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if supported == false {
                Text("This server does not have the duplicate finder. It needs a newer CloudHub than the one it is running.")
            } else if let scan, scan.started || busy {
                Text(DuplicateRules.summary(groupCount: shown.count, reclaimable: shown.reduce(0) { $0 + $1.reclaimable }))
                    .font(.headline)
                Text("Files that are byte for byte identical. A photo saved again at another size is a different file and is not counted."
                     + (minBytes.map { $0 > 0 ? " Anything under \(Format.bytes($0)) is skipped." : "" } ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(DuplicateRules.activity(scan)).font(.footnote)
                if busy {
                    if let fraction = DuplicateRules.progress(scan) { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
                if scan.truncated { notice("The store has more files than one scan covers, so there may be more duplicates.") }
                if gaveUp { notice("The scan did not finish. What is listed is real; scan again to carry on.") }
                if !canWrite { notice("Your account can see duplicates but not start a scan or delete anything.") }
                if scan.done && scan.groups.isEmpty { Text("Nothing here is stored twice.").foregroundStyle(.secondary) }
            } else if busy {
                ProgressView()
            } else {
                Text(canWrite ? "Nothing has been scanned yet. Tap the refresh button to start."
                              : "Nothing has been scanned yet, and your account cannot start a scan.")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(Brand.danger).font(.footnote) }
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
    }

    private func start() async {
        busy = true
        do {
            // A server without a duplicate finder does not publish its limits.
            let config = try await app.api.config()
            supported = config.duplicateScanSeconds != nil
            minBytes = config.duplicateMinBytes
            if supported == true {
                let last = try await app.api.lastDuplicateScan()
                scan = last
                if !last.started && canWrite {
                    runScan()
                    return
                }
            }
        } catch {
            self.error = describe(error)
            supported = supported ?? false
        }
        busy = false
    }

    /// Slices until the server says it is done. Leaving the screen cancels the
    /// loop; the server keeps the scan, and coming back reads it.
    private func runScan() {
        scanTask?.cancel()
        busy = true
        error = nil
        gaveUp = false
        scanTask = Task {
            do {
                var slices = 1
                var latest = try await app.api.startDuplicateScan()
                scan = latest
                keeping = [:]
                selected = []
                while DuplicateRules.shouldContinue(latest, slicesSoFar: slices), !Task.isCancelled {
                    latest = try await app.api.continueDuplicateScan()
                    scan = latest
                    slices += 1
                }
                gaveUp = !latest.done && !Task.isCancelled
            } catch let e as ApiError {
                error = e.status == 403 ? "Your account can see a scan but not start one." : e.message
            } catch is CancellationError {
            } catch {
                self.error = describe(error)
            }
            busy = false
        }
    }

    private func delete(_ paths: [String]) {
        Task {
            var gone = Set<String>()
            for path in paths {
                if (try? await app.api.delete(path)) != nil { gone.insert(path) }
            }
            if let current = scan { scan = DuplicateRules.without(current, removed: gone) }
            selected.subtract(gone)
            app.show(gone.count == paths.count ? "Moved \(gone.count) to the trash" : "\(paths.count - gone.count) could not be deleted")
        }
    }
}
