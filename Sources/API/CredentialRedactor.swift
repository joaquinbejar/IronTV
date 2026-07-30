import Foundation

/// Stream and API URLs embed credentials. Any URL that ends up in a log must
/// go through here first.
public enum CredentialRedactor {
    private static let mask = "REDACTED"
    // "token" covers provider direct_source URLs, which embed access
    // tokens as query parameters.
    private static let credentialQueryNames: Set<String> = ["username", "password", "token"]
    /// Path prefixes whose next two segments are `/{username}/{password}/`.
    private static let credentialPathPrefixes: Set<String> = ["live", "movie", "series", "timeshift"]

    public static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<unparseable url>"
        }

        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                credentialQueryNames.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: mask)
                    : item
            }
        }

        // Split the *encoded* path: a credential slash is %2F there, not a
        // separator, so the segment structure is authoritative and redaction
        // cannot depend on decoded slash boundaries.
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.count >= 3, credentialPathPrefixes.contains(segments[0].lowercased()) {
            if segments.count >= 4 {
                // Keep the prefix and the stream file, and collapse everything
                // between into exactly two masks — that also swallows the extra
                // segments a legacy URL built from a slashed credential grew.
                segments = [segments[0], mask, mask, segments[segments.count - 1]]
            } else {
                segments[1] = mask
                segments[2] = mask
            }
            components.percentEncodedPath = "/" + segments.joined(separator: "/")
        }

        return components.string ?? "<unparseable url>"
    }
}
