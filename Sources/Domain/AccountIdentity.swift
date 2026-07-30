import CryptoKit
import Foundation

/// Stable, non-secret handle for an account.
///
/// Two things key off an account and they need different granularity:
///
/// - **Preference namespacing** uses ``namespace`` (panel host + username), so
///   rotating a password keeps the user's favorites and last channel.
/// - **View and client identity** uses the whole value, which folds in a
///   fingerprint of the password, so rotating it rebuilds the browser and its
///   `XtreamClient` instead of leaving stale credentials in flight.
///
/// The password itself is never carried here, and never reaches a preference
/// key, a log, or `description` — only an irreversible truncated SHA-256 of it.
public struct AccountIdentity: Hashable, Sendable, CustomStringConvertible {
    /// Preference-key namespace: panel host and username, no secret.
    public let namespace: String
    /// Compact, privacy-preserving namespace for preference keys: a versioned
    /// digest of host + username, so UserDefaults/iCloud key names carry no
    /// account metadata. Excludes the password deliberately — a rotation must
    /// keep favorites and the last channel. The `v1.` prefix versions the
    /// derivation so it can evolve behind a migration.
    public let storageNamespace: String
    /// Short digest that changes when any credential changes, the password
    /// included. Not reversible, and not itself a secret.
    public let fingerprint: String

    public init(host: URL, username: String, password: String) {
        self.namespace = "\(host.absoluteString).\(username)"
        self.storageNamespace = "v1." + Self.digest("\(host.absoluteString)\u{0}\(username)")
        self.fingerprint = Self.fingerprint(host: host, username: username, password: password)
    }

    public init(account: Account) {
        self.init(host: account.host, username: account.username, password: account.password)
    }

    /// 64 bits of SHA-256 — plenty to tell credential sets apart, short enough
    /// to read in a log line.
    private static func fingerprint(host: URL, username: String, password: String) -> String {
        // NUL-separated so ("ab", "c") and ("a", "bc") can't hash alike.
        digest("\(host.absoluteString)\u{0}\(username)\u{0}\(password)")
    }

    private static func digest(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Safe to log: namespace plus fingerprint, never the password.
    public var description: String { "\(namespace)#\(fingerprint)" }
}

public extension Account {
    /// Identity used for view/client identity and preference namespacing.
    var identity: AccountIdentity { AccountIdentity(account: self) }
}
