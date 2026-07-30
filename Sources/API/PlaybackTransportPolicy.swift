import Foundation

/// Verdict on where a media request actually went, versus where playback was
/// pointed.
public enum PlaybackTransportVerdict: Equatable, Sendable {
    case acceptable
    /// The stream moved from https to plain http — path credentials exposed.
    case downgraded
    /// The stream moved to a different host or port than the planned origin.
    case crossOrigin
}

/// Post-hoc transport watch for playback: neither AVFoundation nor VLCKit
/// exposes a redirect veto for HLS playlist/segment requests, so enforcement
/// happens by observation — the player's access log is judged against the
/// planned origin, and a violation stops the session (detection, not
/// prevention: the first request already happened, which is documented).
/// Reuses the same same-origin rule that guards the API requests.
public enum PlaybackTransportPolicy {
    /// Relative or unparsable URIs are acceptable: they resolve against the
    /// planned origin by construction. Absolute URIs on non-web schemes
    /// (file:, data:, …) or without a host can never be the planned origin —
    /// they count as cross-origin, not as noise.
    public static func verdict(observedURI: String, plannedOrigin: URL) -> PlaybackTransportVerdict {
        guard let observed = URL(string: observedURI),
              let scheme = observed.scheme?.lowercased() else {
            return .acceptable
        }
        guard scheme == "http" || scheme == "https", observed.host != nil else {
            return .crossOrigin
        }
        if SameOriginRedirectPolicy.allowsRedirect(from: plannedOrigin, to: observed) {
            return .acceptable
        }
        if plannedOrigin.scheme?.lowercased() == "https", observed.scheme?.lowercased() == "http" {
            return .downgraded
        }
        return .crossOrigin
    }

    /// First violation in a batch of observed URIs, if any.
    public static func firstViolation(in observedURIs: [String], plannedOrigin: URL) -> PlaybackTransportVerdict? {
        for uri in observedURIs {
            let result = verdict(observedURI: uri, plannedOrigin: plannedOrigin)
            if result != .acceptable { return result }
        }
        return nil
    }
}
