import Combine
import Foundation

@MainActor
final class ChannelsViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var categories: [Category] = []
    @Published private(set) var categoriesPhase: Phase = .loading
    @Published private(set) var streams: [LiveStream] = []
    @Published private(set) var streamsPhase: Phase = .loaded
    @Published var searchText = ""

    @Published var selectedCategory: CategorySelection? {
        didSet {
            guard selectedCategory != oldValue else { return }
            lastChannel.lastCategory = selectedCategory
            selectedStreamID = nil
            // Cancel the superseded load before starting the new one — a
            // quick category switch must not leave big fetches and decodes
            // running for a selection nobody is looking at.
            restartStreamsLoad()
        }
    }

    @Published var selectedStreamID: StreamID? {
        didSet {
            guard selectedStreamID != oldValue else { return }
            if selectedStreamID != nil {
                lastChannel.lastStreamID = selectedStreamID
            }
        }
    }

    @Published private(set) var favorites: Set<StreamID>

    private let client: ChannelBrowsing
    private let lastChannel: LastChannelStore
    private let favoritesStore: FavoritesStore
    /// Main-actor-confined, like every other piece of this view model's state:
    /// only retained tasks running on this actor read or write it, and every
    /// write sits behind a current-selection guard.
    private var streamCache: [CategorySelection: [LiveStream]] = [:]
    /// Stream to re-select once its category's streams arrive (launch restore).
    private var pendingStreamRestore: StreamID?

    /// Retained so superseded loads are cancelled instead of racing on: by a
    /// selection change, a retry, or deinit. All `Sendable`, so deinit may
    /// cancel them.
    private var categoriesTask: Task<Void, Never>?
    private var streamsTask: Task<Void, Never>?
    /// Single in-flight fetch of the full channel list — All and Favorites
    /// dedupe on it instead of issuing a second identical request.
    private var allStreamsTask: Task<[LiveStream], Error>?

    /// True for the demo catalog: the screenshot env flag OR the user-facing
    /// "Sample channels" account.
    private let isDemo: Bool
    /// Owns the iCloud-favorites observer token; removes it on release so no
    /// nonisolated deinit has to touch non-Sendable state.
    private let teardown = TeardownBag()

    /// `lastChannel` defaults to a store scoped to this account, so the browser
    /// can never restore another provider's category or stream. `client` and
    /// `preferenceStorage` are injectable for offline tests; the defaults are
    /// the real Xtream client and the synced store.
    init(
        account: Account,
        lastChannel: LastChannelStore? = nil,
        client: ChannelBrowsing? = nil,
        preferenceStorage: KeyValueStorage = SyncedStorage.shared
    ) {
        let settings = PlaybackSettingsStore().load()
        self.client = client ?? XtreamClient(account: account, requestTimeout: settings.apiTimeoutSeconds)
        self.lastChannel = lastChannel ?? LastChannelStore(identity: account.identity, storage: preferenceStorage)
        self.favoritesStore = FavoritesStore(account: account, storage: preferenceStorage)
        self.isDemo = DemoMode.isActive || account == DemoMode.account
        self.favorites = isDemo ? DemoMode.favoriteIDs : favoritesStore.load()
        observeFavoritesSync()
        categoriesTask = makeCategoriesLoadTask()
    }

    deinit {
        categoriesTask?.cancel()
        streamsTask?.cancel()
        allStreamsTask?.cancel()
    }

    /// Picks up favorites toggled on another device while this screen is open.
    /// iCloud KVS is last-writer-wins per key, so the remote value replaces
    /// ours wholesale — that's what makes removals propagate.
    private func observeFavoritesSync() {
        guard !isDemo else { return }
        let key = favoritesStore.storageKey
        teardown.store(NotificationCenter.default.addObserver(
            forName: SyncedStorage.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changed = notification.userInfo?[SyncedStorage.changedKeysUserInfoKey] as? [String] ?? []
            guard changed.contains(key) else { return }
            // Delivered on the main queue (SyncedStorage posts there), so the
            // hop onto the actor is an assertion, not a detached task that
            // could outlive or race the view model.
            MainActor.assumeIsolated {
                self?.adoptRemoteFavorites()
            }
        })
    }

    private func adoptRemoteFavorites() {
        let remote = favoritesStore.load()
        guard remote != favorites else { return }
        favorites = remote
        refreshFavoritesListIfShown()
    }

    func isFavorite(_ streamID: StreamID) -> Bool {
        favorites.contains(streamID)
    }

    func toggleFavorite(_ streamID: StreamID) {
        if favorites.contains(streamID) {
            favorites.remove(streamID)
        } else {
            favorites.insert(streamID)
        }
        favoritesStore.save(favorites)
        refreshFavoritesListIfShown()
    }

    /// The favorites list reflects removals immediately.
    private func refreshFavoritesListIfShown() {
        guard selectedCategory == .favorites, let all = streamCache[.all] else { return }
        streams = all.filter { favorites.contains($0.id) }
    }

    var filteredStreams: [LiveStream] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return streams }
        return streams.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func selectedStream() -> LiveStream? {
        guard let selectedStreamID else { return nil }
        return streams.first { $0.id == selectedStreamID }
    }

    func playbackURL(for streamID: StreamID) throws -> URL {
        if isDemo {
            // Screenshots play the bundled poster clip; the user-facing
            // sample mode plays real legal HLS streams.
            return DemoMode.isActive ? DemoMode.screenshotClipURL : DemoMode.sampleURL(for: streamID)
        }
        return try client.playbackURL(for: streamID)
    }

    /// Raw MPEG-TS variant for the VLC engine; nil for demo/sample content.
    func playbackTSURL(for streamID: StreamID) -> URL? {
        guard !isDemo else { return nil }
        return try? client.playbackURL(for: streamID, format: .ts)
    }

    /// Public entry points cancel the superseded load, retain the new task,
    /// and await it — so view code keeps its `await` call sites while every
    /// in-flight load stays cancellable.
    ///
    /// Every load is two-phase: a brief strong window on the actor to plan
    /// (phase flips, cache checks) and to apply the result — while the fetch
    /// itself holds only the client. An in-flight request therefore never
    /// pins the view model: release the browser and the loads die with it.
    func loadCategories() async {
        categoriesTask?.cancel()
        let task = makeCategoriesLoadTask()
        categoriesTask = task
        await task.value
    }

    func loadStreams(bypassCache: Bool = false) async {
        let task = restartStreamsLoad(bypassCache: bypassCache)
        await task.value
    }

    private func makeCategoriesLoadTask() -> Task<Void, Never> {
        Task { [weak self] () -> Void in
            guard let fetch = self?.beginCategoriesLoad() else { return }
            let result: Result<[Category], Error>
            do {
                result = .success(try await withTaskCancellationHandler {
                    try await fetch.value
                } onCancel: {
                    fetch.cancel()
                })
            } catch {
                result = .failure(error)
            }
            self?.finishCategoriesLoad(result)
        }
    }

    /// nil = handled synchronously (demo catalog); otherwise the detached
    /// fetch to await without retaining the view model.
    private func beginCategoriesLoad() -> Task<[Category], Error>? {
        if isDemo {
            categories = DemoMode.categories
            categoriesPhase = .loaded
            return nil
        }
        categoriesPhase = .loading
        let client = self.client
        // Detached: the wrapper frames must not be scheduled on the main actor
        // (the client's nonisolated async work already runs off it).
        return Task.detached { try await client.liveCategories() }
    }

    private func finishCategoriesLoad(_ result: Result<[Category], Error>) {
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let fetched):
            categories = fetched
            categoriesPhase = .loaded
            restoreLastChannelIfPossible()
        case .failure(let error):
            // Cancellation is a state transition, not a user-facing failure.
            guard !Self.isCancellation(error) else { return }
            categoriesPhase = .failed(errorMessage(for: error))
        }
    }

    @discardableResult
    private func restartStreamsLoad(bypassCache: Bool = false) -> Task<Void, Never> {
        streamsTask?.cancel()
        let task = Task { [weak self] () -> Void in
            guard let plan = self?.beginStreamsLoad(bypassCache: bypassCache) else { return }
            guard case .fetch(let selection, let fetch, let exclusive) = plan else { return }
            let result: Result<[LiveStream], Error>
            do {
                result = .success(try await withTaskCancellationHandler {
                    try await fetch.value
                } onCancel: {
                    // The shared full-list fetch may have other waiters — it
                    // is only torn down by deinit, never by one stale waiter.
                    if exclusive { fetch.cancel() }
                })
            } catch {
                result = .failure(error)
            }
            self?.finishStreamsLoad(result, for: selection)
        }
        streamsTask = task
        return task
    }

    private enum StreamsLoadPlan {
        /// Answered synchronously: empty selection, demo catalog, or cache.
        case served
        /// Await this fetch, then apply for the given selection. `exclusive`
        /// is false for the shared full-list task, which other loads may be
        /// awaiting too.
        case fetch(CategorySelection, Task<[LiveStream], Error>, exclusive: Bool)
    }

    private func beginStreamsLoad(bypassCache: Bool) -> StreamsLoadPlan {
        guard let selection = selectedCategory else {
            streams = []
            streamsPhase = .loaded
            return .served
        }
        if isDemo {
            streams = DemoMode.streams(in: selection)
            streamsPhase = .loaded
            applyPendingStreamRestore()
            return .served
        }
        if !bypassCache, selection != .favorites, let cached = streamCache[selection] {
            streams = cached
            streamsPhase = .loaded
            applyPendingStreamRestore()
            return .served
        }
        streamsPhase = .loading
        let client = self.client
        switch selection {
        case .all, .favorites:
            if !bypassCache, selection == .favorites, let cached = streamCache[.all] {
                finishStreamsLoad(.success(cached), for: selection)
                return .served
            }
            // The full channel list is fetched at most once at a time: a
            // Favorites load arriving while All is still fetching awaits the
            // same task instead of issuing a second identical request.
            if !bypassCache, let inFlight = allStreamsTask, !inFlight.isCancelled {
                return .fetch(selection, inFlight, exclusive: false)
            }
            let task = Task.detached { try await client.liveStreams(in: nil) }
            allStreamsTask = task
            return .fetch(selection, task, exclusive: false)
        case .category(let categoryID):
            return .fetch(selection, Task.detached { try await client.liveStreams(in: categoryID) }, exclusive: true)
        }
    }

    private func finishStreamsLoad(_ result: Result<[LiveStream], Error>, for selection: CategorySelection) {
        switch result {
        case .success(let fetched):
            // The shared full list is cacheable regardless of which selection
            // is current — the next All/Favorites visit serves from it.
            if selection == .all || selection == .favorites {
                streamCache[.all] = fetched
                // The cache is the source of truth now — dropping the completed
                // task releases its retained copy of the catalog.
                allStreamsTask = nil
            }
            // Only the current selection may update phases, the visible list,
            // or the per-category cache — stale responses are dropped.
            guard selectedCategory == selection, !Task.isCancelled else { return }
            let visible: [LiveStream]
            if selection == .favorites {
                visible = fetched.filter { favorites.contains($0.id) }
            } else {
                visible = fetched
            }
            if case .category = selection {
                streamCache[selection] = fetched
            }
            streams = visible
            streamsPhase = .loaded
            applyPendingStreamRestore()
        case .failure(let error):
            // A failed shared fetch must not be reused by the next load.
            if selection == .all || selection == .favorites {
                allStreamsTask = nil
            }
            guard !Self.isCancellation(error), !Task.isCancelled else { return }
            guard selectedCategory == selection else { return }
            streamsPhase = .failed(errorMessage(for: error))
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case XtreamAPIError.network(let urlError) = error, urlError.code == .cancelled { return true }
        return false
    }

    private func restoreLastChannelIfPossible() {
        guard selectedCategory == nil, let saved = lastChannel.lastCategory else { return }
        if case .category(let id) = saved, !categories.contains(where: { $0.id == id }) {
            return
        }
        pendingStreamRestore = lastChannel.lastStreamID
        selectedCategory = saved
    }

    private func applyPendingStreamRestore() {
        guard let pending = pendingStreamRestore else { return }
        pendingStreamRestore = nil
        if streams.contains(where: { $0.id == pending }) {
            selectedStreamID = pending
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
