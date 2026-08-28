import Foundation

/// Catalog served by the playlist file itself, for providers that hand out an
/// M3U and have no Xtream panel behind it.
///
/// Implements the same ``ChannelBrowsing`` seam the Xtream client does, so
/// `ChannelsViewModel` and everything above it consume identical `Category`
/// and `LiveStream` values and never learn where the catalog came from.
///
/// What this source structurally cannot provide, and why the UI has to be
/// honest about it rather than showing blanks:
///
/// - **No account status.** There is no `player_api.php`, so no expiry date
///   and no maximum-connections figure. ``accountStatus()`` synthesises an
///   authenticated status because the playlist downloading *is* the only
///   available proof that the credentials work.
/// - **No incremental loading.** The Xtream client fetches one category at a
///   time; a playlist arrives whole, which is why the fetch is cached.
///
/// What it does NOT lose: `tvg-id` carries the same value `epgChannelID` gets
/// from the API, and each entry's own URL states its format per channel, which
/// is finer-grained than the account-wide `allowed_output_formats`.
public final class M3UCatalogClient: @unchecked Sendable {
    private let playlistURL: URL
    private let panelHost: URL
    private let session: URLSession
    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date

    /// `@unchecked Sendable` with an explicit lock rather than an actor: the
    /// ``ChannelBrowsing/playbackURL(for:format:)`` requirement is synchronous
    /// and an actor cannot satisfy it without hopping.
    private let lock = NSLock()
    private var cached: Snapshot?
    /// In-flight fetch, so N channels selected at once do not download the
    /// same multi-megabyte playlist N times.
    private var inFlight: Task<Snapshot, Error>?

    private struct Snapshot {
        let fetchedAt: Date
        let categories: [Category]
        let streams: [LiveStream]
        let urlsByStream: [StreamID: URL]
    }

    public init(
        playlistURL: URL,
        panelHost: URL,
        cacheLifetime: TimeInterval,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.playlistURL = playlistURL
        self.panelHost = panelHost
        self.session = session
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    /// Drops the cached playlist so the next read re-fetches. The explicit
    /// refresh the user asks for must never be answered from cache.
    public func invalidateCache() {
        lock.withLock {
            cached = nil
            inFlight = nil
        }
    }

    /// What the caller should do, decided under the lock in one step so two
    /// concurrent readers cannot both start a download.
    private enum CacheDecision {
        case reuse(Snapshot)
        case join(Task<Snapshot, Error>)
    }

    private func snapshot() async throws -> Snapshot {
        let decision: CacheDecision = lock.withLock {
            if let cached, now().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
                return .reuse(cached)
            }
            if let inFlight {
                return .join(inFlight)
            }
            let task = Task { [self] () throws -> Snapshot in
                let entries = try await fetchEntries()
                let built = Self.build(from: entries)
                return Snapshot(
                    fetchedAt: now(),
                    categories: built.categories,
                    streams: built.streams,
                    urlsByStream: built.urlsByStream
                )
            }
            inFlight = task
            return .join(task)
        }

        switch decision {
        case .reuse(let snapshot):
            return snapshot
        case .join(let task):
            do {
                let snapshot = try await task.value
                lock.withLock {
                    cached = snapshot
                    inFlight = nil
                }
                return snapshot
            } catch {
                // Cleared so a failure is retried rather than latched: a
                // provider that was down for one fetch must not poison the
                // client for the rest of the session.
                lock.withLock { inFlight = nil }
                throw error
            }
        }
    }

    /// Streamed line by line rather than decoded into one `String`: provider
    /// playlists reach tens of megabytes and 100k+ entries, and tvOS has the
    /// least memory of the three targets.
    private func fetchEntries() async throws -> [M3UEntry] {
        let (bytes, response) = try await session.bytes(from: playlistURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw XtreamAPIError.httpStatus(http.statusCode)
        }
        var parser = M3UPlaylistParser()
        for try await line in bytes.lines {
            parser.consume(line: line)
        }
        return try parser.finish()
    }

    /// Stable identifiers derived from the entry's own identity rather than
    /// its position: a provider inserting a channel must not renumber every
    /// favorite and the last-watched channel underneath the user.
    static func build(from entries: [M3UEntry]) -> (categories: [Category], streams: [LiveStream], urlsByStream: [StreamID: URL]) {
        var categories: [Category] = []
        var categoryIDs: [String: CategoryID] = [:]
        var streams: [LiveStream] = []
        var urlsByStream: [StreamID: URL] = [:]
        var usedStreamIDs: Set<StreamID> = []

        for entry in entries {
            let groupName = entry.group ?? String(localized: "Ungrouped")
            let categoryID: CategoryID
            if let existing = categoryIDs[groupName] {
                categoryID = existing
            } else {
                categoryID = CategoryID(stableID(for: groupName))
                categoryIDs[groupName] = categoryID
                categories.append(Category(id: categoryID, name: groupName))
            }

            var streamID = StreamID(stableID(for: entry.url.absoluteString))
            // Two entries hashing alike would collapse into one channel;
            // walking to the next free slot keeps both, and keeps the id
            // stable for everything that did not collide.
            while usedStreamIDs.contains(streamID) {
                streamID = StreamID(streamID.rawValue &+ 1)
            }
            usedStreamIDs.insert(streamID)

            streams.append(
                LiveStream(
                    id: streamID,
                    name: entry.name,
                    iconURL: entry.logoURL,
                    categoryID: categoryID,
                    epgChannelID: entry.tvgID,
                    // The entry's own URL. PlaybackSourcePlanner applies the
                    // same-host trust policy to it, exactly as it does to an
                    // Xtream `direct_source`.
                    directSourceURL: entry.url
                )
            )
            urlsByStream[streamID] = entry.url
        }
        return (categories, streams, urlsByStream)
    }

    /// FNV-1a, folded into the non-negative range. Swift's `hashValue` is
    /// seeded per process, so it cannot be used for anything that has to match
    /// across launches — favorites and the last channel are stored by id.
    static func stableID(for text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(Int32.max))
    }
}

extension M3UCatalogClient: ChannelBrowsing {
    /// Synthesised. The playlist downloading is the only proof of credentials
    /// this source can offer, and it has already happened by the time this
    /// returns. `allowedOutputFormats` is empty rather than nil on purpose:
    /// nil means "panel predates the field, assume both", which would make the
    /// planner build Xtream-shaped URLs this source cannot serve. Empty routes
    /// playback through the entry's own URL instead.
    public func accountStatus() async throws -> AccountStatus {
        _ = try await snapshot()
        return AccountStatus(
            authenticated: true,
            status: nil,
            expiryDate: nil,
            maxConnections: nil,
            allowedOutputFormats: []
        )
    }

    public func liveCategories() async throws -> [Category] {
        try await snapshot().categories
    }

    /// The whole playlist is already in memory, so filtering by category is
    /// local — there is no per-category endpoint to call.
    public func liveStreams(in categoryID: CategoryID?) async throws -> [LiveStream] {
        let streams = try await snapshot().streams
        guard let categoryID else { return streams }
        return streams.filter { $0.categoryID == categoryID }
    }

    /// The URL from the playlist, whatever container was asked for: this
    /// source does not synthesise Xtream-shaped URLs, and the entry already
    /// states its own format. Only reachable once a snapshot exists, which
    /// every catalog path guarantees before a stream can be selected.
    public func playbackURL(for streamID: StreamID, format: XtreamClient.StreamFormat) throws -> URL {
        let url = lock.withLock { cached?.urlsByStream[streamID] }
        guard let url else { throw XtreamAPIError.invalidURL }
        return url
    }
}

extension M3UCatalogClient: AccountValidating {}
