import Foundation

/// Stream container formats a panel can advertise via `allowed_output_formats`.
public enum StreamOutputFormat: String, Sendable, Hashable {
    case hls = "m3u8"
    case ts
}

/// Which sources playback should use for one stream, in engine order.
public struct PlaybackSourceSelection: Equatable, Sendable {
    /// The panel advertises HLS — AVPlayer can lead.
    public var useHLS: Bool
    /// The panel advertises raw MPEG-TS — the VLC engine has a source.
    public var useTS: Bool
    /// Provider-supplied direct URL that passed the trust policy, if any.
    public var directURL: URL?

    public var hasPlayableSource: Bool {
        useHLS || useTS || directURL != nil
    }

    public init(useHLS: Bool, useTS: Bool, directURL: URL?) {
        self.useHLS = useHLS
        self.useTS = useTS
        self.directURL = directURL
    }
}

/// Deterministic source/engine selection from what the provider advertises.
///
/// Policy, in order: HLS when advertised (AVPlayer first — hardware decode,
/// AirPlay); TS when advertised (the VLC engine's source, and the automatic
/// fallback); a `direct_source` URL last, and only when it passes the trust
/// policy — http/https scheme AND the same host as the panel. A cross-host
/// direct source is a redirect of credentials/tokens to an arbitrary server
/// the user never entered, so it is rejected here rather than surfaced.
/// Absent `allowed_output_formats` means the panel predates the field —
/// assume both classic formats, which is exactly today's behavior.
public enum PlaybackSourcePlanner {
    public static func plan(
        directSource: URL?,
        allowedFormats: Set<StreamOutputFormat>?,
        panelHost: URL
    ) -> PlaybackSourceSelection {
        let formats = allowedFormats ?? [.hls, .ts]
        return PlaybackSourceSelection(
            useHLS: formats.contains(.hls),
            useTS: formats.contains(.ts),
            directURL: trustedDirectURL(directSource, panelHost: panelHost)
        )
    }

    /// Same-origin trust, aligned with the API-side rule: http/https scheme,
    /// same host, same effective port — a direct_source hopping ports could
    /// route credential/token-bearing URLs to a different service on the same
    /// machine. A scheme upgrade (http panel → https direct) is allowed; a
    /// downgrade (https panel → http direct) is not.
    private static func trustedDirectURL(_ url: URL?, panelHost: URL) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              let panelScheme = panelHost.scheme?.lowercased(),
              let trusted = panelHost.host?.lowercased(),
              host == trusted,
              effectivePort(scheme: scheme, port: url.port) == effectivePort(scheme: panelScheme, port: panelHost.port),
              !(panelScheme == "https" && scheme == "http") else {
            return nil
        }
        return url
    }

    private static func effectivePort(scheme: String, port: Int?) -> Int {
        if let port { return port }
        return scheme == "https" ? 443 : 80
    }
}
