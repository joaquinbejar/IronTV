import Foundation

/// On-disk copy of a downloaded playlist, so the expiry the user sets in
/// Settings survives relaunches instead of applying only within one client.
///
/// Lives in the caches directory on purpose: provider playlists reach tens of
/// megabytes, this is reconstructible from the network, and the system is free
/// to purge it under storage pressure — which matters most on tvOS. A purge is
/// not an error, it is a cache miss and one more download.
///
/// Keyed by the account's `storageNamespace`, which is a digest: the file name
/// carries no host, username or playlist URL, and the body is the playlist as
/// downloaded — credential-bearing, and therefore never logged.
public struct PlaylistCacheStore: @unchecked Sendable {
    private let directory: URL
    /// FileManager is not Sendable, but every use here is a self-contained
    /// call on an instance this store owns and never mutates.
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let caches = (try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = caches.appendingPathComponent("Playlists", isDirectory: true)
        }
    }

    private func fileURL(for namespace: String) -> URL {
        directory.appendingPathComponent("\(namespace).m3u", isDirectory: false)
    }

    /// The cached body, or nil when there is none, it cannot be read, or it is
    /// older than `lifetime`. Every failure is a miss: a cache that cannot be
    /// read must never be able to break the app.
    /// The body comes back with the time it was written, so the caller can age
    /// the in-memory snapshot from the download rather than restarting the
    /// clock on every launch.
    public func load(namespace: String, lifetime: TimeInterval, now: Date) -> (body: String, writtenAt: Date)? {
        let url = fileURL(for: namespace)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        guard now.timeIntervalSince(modified) < lifetime else { return nil }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (body, modified)
    }

    /// Best-effort. A playlist that cannot be written is still perfectly
    /// usable this session, so a full disk costs a re-download, never a
    /// failure the user sees.
    public func save(_ body: String, namespace: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: namespace)
        try? Data(body.utf8).write(to: url, options: .atomic)
        // Excluded from backup: reconstructible, and large.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }

    public func remove(namespace: String) {
        try? fileManager.removeItem(at: fileURL(for: namespace))
    }
}
