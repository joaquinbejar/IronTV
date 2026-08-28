import Foundation

/// Turns a playlist URL we could not read credentials out of into an account
/// whose catalog is the playlist itself.
///
/// This is the branch that replaces ``M3UURLParseError/missingUsername`` as a
/// dead end. The credentials stay embedded in the URL — that is how the
/// provider issued them — so nothing here has to guess a parameter name.
public enum PlaylistAccountBuilder {
    public static func account(fromPlaylistURL text: String) -> Account? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let playlistURL = components.url
        else { return nil }

        var hostComponents = URLComponents()
        hostComponents.scheme = scheme
        hostComponents.host = host
        hostComponents.port = components.port
        guard let hostURL = hostComponents.url else { return nil }

        // Username and password are unknown by construction — that is why we
        // are here. Empty rather than invented: nothing builds a URL from
        // them for a playlist account, and a fake value would end up in the
        // Keychain and in the preference namespace.
        return Account(
            host: hostURL,
            username: "",
            password: "",
            origin: .playlist,
            playlistURL: playlistURL
        )
    }
}
