import Foundation
#if canImport(Combine)
import Combine
#endif

/// The file browser's state and everything it does, kept off the screen.
@MainActor
public final class FilesModel: ObservableObject {
    @Published public private(set) var path = "/"
    @Published public private(set) var entries: [FileEntry] = []
    @Published public private(set) var load: LoadState = .loading
    /// Why the listing failed, kept until it is retried -- not a toast.
    @Published public private(set) var loadError: String?
    /// Transient feedback for an action ("Renamed", "Moved to trash").
    @Published public var message: String?
    @Published public private(set) var selected: Set<String> = []
    @Published public private(set) var user: User?
    @Published public private(set) var query = ""
    /// Nil while browsing; set while showing results from the server.
    @Published public private(set) var searchResults: [FileEntry]?
    @Published public private(set) var searchTruncated = false
    /// An All folders search is on.
    @Published public private(set) var searchMode = false
    /// A request for the search is out; results so far stay on screen.
    @Published public private(set) var searching = false
    @Published public private(set) var searchScanned = 0
    @Published public private(set) var searchError: String?
    @Published public var sort: FileSort = .name
    @Published public var grid = true

    /// The paths this account has starred, kept in step with every star and unstar.
    @Published public private(set) var favorites: Set<String> = []
    @Published public private(set) var favoriteEntries: [FileEntry] = []
    @Published public private(set) var favoritesLoad: LoadState = .loading
    @Published public private(set) var favoritesError: String?

    /// The server no longer knows this session; the app goes back to sign-in.
    @Published public private(set) var signedOut = false

    private let api: CloudHubAPI
    private var searchTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    /// One favorites request at a time, in the order they were made.
    private var favoriteChain: Task<Void, Never>?
    private var favoriteEdits = 0
    public private(set) var pending: Task<Void, Never>?

    public init(api: CloudHubAPI) {
        self.api = api
    }

    /* ---- what the screen draws ------------------------------------------ */

    /// Search results when searching, else the folder filtered by the query; sorted.
    public var visible: [FileEntry] {
        let base = searchResults ?? entries.filter {
            query.trimmingCharacters(in: .whitespaces).isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        return sort.sorted(base)
    }

    public var canWrite: Bool { user?.canWrite == true }
    public var filtering: Bool { searchMode || searchResults != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty }
    public var loading: Bool { load == .loading }

    public var shown: Shown {
        browserState(load: load, hasEntries: !entries.isEmpty, hasVisible: !visible.isEmpty, filtering: filtering)
    }

    /* ---- browsing -------------------------------------------------------- */

    /// A new sign-in, possibly as somebody else.
    public func start() {
        favorites = []
        favoriteEntries = []
        signedOut = false
        user = nil
        entries = []
        path = "/"
        let api = self.api
        pending = Task {
            if let status = try? await api.status() { user = status.user }
            open("/")
            loadFavorites()
        }
    }

    public func open(_ target: String) {
        endSearch()
        let movingOn = target != path
        load = .loading
        loadError = nil
        selected = []
        if movingOn { entries = [] }
        listTask?.cancel()
        let api = self.api
        listTask = Task {
            do {
                let listed = try await api.list(target)
                if Task.isCancelled { return }
                path = target
                entries = listed
                load = .ready
            } catch is CancellationError {
                return
            } catch let e as ApiError {
                if Task.isCancelled { return }
                if target != "/" && e.status == 404 {
                    message = "That folder is no longer there"
                    open("/")
                } else {
                    path = target
                    load = .failed
                    loadError = e.message
                    if e.isUnauthorized { signedOut = true }
                }
            } catch {
                if Task.isCancelled { return }
                path = target
                load = .failed
                loadError = describe(error)
            }
        }
        pending = listTask
    }

    public func refresh() {
        open(path)
        loadFavorites()
    }

    public func retry() { open(path) }

    public func goUp() { open(Paths.parentOf(path)) }

    /// Typing filters the folder on screen, until All folders has been asked for.
    public func setQuery(_ newQuery: String) {
        query = newQuery
        guard searchMode else { return }
        if SearchRules.canSearch(newQuery) { runSearch(debounceMs: SearchRules.debounceMs) } else { endSearch() }
    }

    /// All folders: the explicit search.
    public func searchEverywhere() {
        guard SearchRules.canSearch(query) else {
            message = "Enter at least two characters"
            return
        }
        runSearch(debounceMs: 0)
    }

    private func runSearch(debounceMs: UInt64) {
        searchTask?.cancel()
        searchMode = true
        searching = true
        searchError = nil
        let api = self.api
        searchTask = Task {
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
                if Task.isCancelled { return }
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            var scanned = -1
            var slices = 0
            do {
                while true {
                    let found = try await api.search(q, under: SearchRules.scope, budgetMs: SearchRules.sliceMs)
                    if Task.isCancelled { return }
                    slices += 1
                    let more = SearchRules.shouldContinue(found, scannedBefore: scanned, slicesSoFar: slices)
                    searchResults = found.results
                    searchTruncated = found.truncated
                    searchScanned = found.scanned
                    searching = more
                    selected = []
                    if !more { break }
                    scanned = found.scanned
                }
            } catch {
                if Task.isCancelled { return }
                searching = false
                searchError = describe(error)
            }
        }
        pending = searchTask
    }

    private func endSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchMode = false
        searching = false
        searchResults = nil
        searchTruncated = false
        searchScanned = 0
        searchError = nil
    }

    public func clearSearch() {
        endSearch()
        query = ""
    }

    public func toggleSelected(_ p: String) {
        if selected.contains(p) { selected.remove(p) } else { selected.insert(p) }
    }

    public func clearSelection() { selected = [] }

    /* ---- favorites ------------------------------------------------------- */

    /// Queue `work` behind every favorites request before it.
    private func serialised(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = favoriteChain
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        favoriteChain = task
        return task
    }

    public func loadFavorites() {
        favoritesLoad = .loading
        favoritesError = nil
        let edits = favoriteEdits
        let api = self.api
        pending = serialised { [weak self] in
            guard let self else { return }
            do {
                let listing = try await api.favorites()
                // A star changed while this was being fetched: ask again, behind it.
                if edits != self.favoriteEdits {
                    self.loadFavorites()
                    return
                }
                self.favoriteEntries = listing.favorites
                self.favorites = Set(listing.favorites.map(\.path))
                self.favoritesLoad = .ready
            } catch {
                self.favoritesLoad = .failed
                self.favoritesError = describe(error)
            }
        }
    }

    /// The star changes at once, and is put back with the reason if the server refuses.
    public func toggleFavorite(_ entry: FileEntry) {
        guard !entry.isDirectory else { return }
        let starring = !favorites.contains(entry.path)
        favoriteEdits += 1
        applyFavorite(entry, starring)
        let api = self.api
        pending = serialised { [weak self] in
            do {
                if starring { _ = try await api.addFavorite(entry.path) } else { _ = try await api.removeFavorite(entry.path) }
            } catch {
                guard let self else { return }
                self.applyFavorite(entry, !starring)
                self.message = describe(error, fallback: "That did not work")
                self.loadFavorites()
            }
        }
    }

    private func applyFavorite(_ entry: FileEntry, _ starred: Bool) {
        if starred { favorites.insert(entry.path) } else { favorites.remove(entry.path) }
        favoriteEntries = FavoriteRules.afterToggle(favoriteEntries, entry, starred: starred)
    }

    /* ---- actions --------------------------------------------------------- */

    public func makeFolder(_ name: String) {
        let target = Paths.join(path, name)
        act { api in _ = try await api.makeFolder(target); return "Folder created" }
    }

    public func rename(_ entry: FileEntry, to newName: String) {
        guard isRename(current: entry.name, requested: newName) else { return }
        let target = Paths.join(Paths.parentOf(entry.path), newName)
        act { api in
            let result = try await api.rename(from: entry.path, to: target)
            // The server picks a free name when the one asked for is taken, and says so.
            return result.message.isEmpty ? "Renamed" : result.message
        }
    }

    public func delete(_ paths: [String]) {
        act { api in
            var trashed = false
            for p in paths { trashed = try await api.delete(p).trashed || trashed }
            return trashed ? "Moved to trash" : "Deleted"
        }
    }

    public func move(_ paths: [String], to destination: String) { relocate(paths, destination, moving: true) }

    public func copy(_ paths: [String], to destination: String) { relocate(paths, destination, moving: false) }

    private func relocate(_ paths: [String], _ destination: String, moving: Bool) {
        act { api in
            let result = moving ? try await api.move(paths, to: destination) : try await api.copy(paths, to: destination)
            if result.failed.isEmpty {
                return "\(result.completed) item\(Format.plural(result.completed)) \(moving ? "moved" : "copied")"
            }
            return "\(result.completed) done, \(result.failed.count) failed: \(result.failed[0].message)"
        }
    }

    private func act(_ block: @escaping @Sendable (CloudHubAPI) async throws -> String) {
        let api = self.api
        pending = Task {
            do {
                message = try await block(api)
                selected = []
                refresh()
            } catch {
                message = describe(error, fallback: "That did not work")
            }
        }
    }

    /// Something outside the browser changed the folder (an upload landed).
    public func folderChanged(_ folder: String) {
        if folder == path && searchResults == nil { open(path) }
    }
}
