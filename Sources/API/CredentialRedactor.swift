import Foundation

/// Stream and API URLs embed credentials. Any URL that ends up in a log must
/// go through here first.
public enum CredentialRedactor {
    private static let mask = "REDACTED"
    private static let credentialQueryNames: Set<String> = ["username", "password"]
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

        var segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.count >= 3, credentialPathPrefixes.contains(segments[0].lowercased()) {
            segments[1] = mask
            segments[2] = mask
            components.path = "/" + segments.joined(separator: "/")
        }

        return components.string ?? "<unparseable url>"
    }
}
