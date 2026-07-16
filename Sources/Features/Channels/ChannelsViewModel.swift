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
            Task { await loadStreams() }
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

    private let client: XtreamClient
    private let lastChannel: LastChannelStore
    private let favoritesStore: FavoritesStore
    private var streamCache: [CategorySelection: [LiveStream]] = [:]
    /// Stream to re-select once its category's streams arrive (launch restore).
    private var pendingStreamRestore: StreamID?

    init(account: Account, lastChannel: LastChannelStore = LastChannelStore()) {
        let settings = PlaybackSettingsStore().load()
        self.client = XtreamClient(account: account, requestTimeout: settings.apiTimeoutSeconds)
        self.lastChannel = lastChannel
        self.favoritesStore = FavoritesStore(account: account)
        self.favorites = favoritesStore.load()
        Task { await loadCategories() }
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
        // The favorites list reflects removals immediately.
        if selectedCategory == .favorites, let all = streamCache[.all] {
            streams = all.filter { favorites.contains($0.id) }
        }
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
        try client.playbackURL(for: streamID)
    }

    func loadCategories() async {
        categoriesPhase = .loading
        do {
            categories = try await client.liveCategories()
            categoriesPhase = .loaded
            restoreLastChannelIfPossible()
        } catch {
            categoriesPhase = .failed(errorMessage(for: error))
        }
    }

    func loadStreams(bypassCache: Bool = false) async {
        guard let selection = selectedCategory else {
            streams = []
            streamsPhase = .loaded
            return
        }
        if !bypassCache, selection != .favorites, let cached = streamCache[selection] {
            streams = cached
            streamsPhase = .loaded
            applyPendingStreamRestore()
            return
        }
        streamsPhase = .loading
        do {
            let fetched: [LiveStream]
            switch selection {
            case .all:
                fetched = try await allStreams(bypassCache: bypassCache)
            case .favorites:
                // Favorites are a filter over the full channel list.
                fetched = try await allStreams(bypassCache: bypassCache)
                    .filter { favorites.contains($0.id) }
            case .category(let categoryID):
                fetched = try await client.liveStreams(in: categoryID)
            }
            // Ignore stale responses after a quick category switch.
            guard selectedCategory == selection else { return }
            if case .category = selection {
                streamCache[selection] = fetched
            }
            streams = fetched
            streamsPhase = .loaded
            applyPendingStreamRestore()
        } catch {
            guard selectedCategory == selection else { return }
            streamsPhase = .failed(errorMessage(for: error))
        }
    }

    private func allStreams(bypassCache: Bool) async throws -> [LiveStream] {
        if !bypassCache, let cached = streamCache[.all] {
            return cached
        }
        let fetched = try await client.liveStreams(in: nil)
        streamCache[.all] = fetched
        return fetched
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
