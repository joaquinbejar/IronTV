import Foundation
import os
import Security

public enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case corruptedData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))."
        case .corruptedData:
            return "The stored account could not be read."
        }
    }
}

/// Persists the single `Account` as a generic-password Keychain item.
public struct KeychainStore {
    /// The Keychain back-ends available on macOS. The data-protection Keychain
    /// (iOS-style, no ACLs) is preferred: items in the legacy file-based login
    /// Keychain carry an ACL bound to the signature of the build that created
    /// them, so a re-signed build gets `errSecInvalidOwnerEdit` (-25244) when
    /// it tries to overwrite or delete them. The legacy back-end is only used
    /// as a fallback when the app is signed without an `application-identifier`
    /// entitlement (no provisioning profile), which makes the data-protection
    /// Keychain unavailable.
    private enum Backend {
        case dataProtection
        case legacy
    }

    private static var backends: [Backend] {
        #if os(macOS)
        [.dataProtection, .legacy]
        #else
        [.dataProtection] // the only Keychain on iOS/tvOS
        #endif
    }

    private let service: String
    private let accountName = "xtream-account"
    private let client: SecItemClient

    /// Status codes only — never credential data (see the migration catch).
    private static let logger = Logger(subsystem: "com.taunais.irontv", category: "keychain")

    public init(service: String = "com.taunais.irontv", client: SecItemClient = SystemSecItemClient()) {
        self.service = service
        self.client = client
    }

    public func saveAccount(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)

        var lastStatus = errSecSuccess
        for backend in Self.backends {
            let status = write(data, to: backend)
            if status == errSecSuccess {
                if backend == .dataProtection { purgeLegacyItem() }
                return
            }
            lastStatus = status
            // Only keep going when the back-end itself is unusable; a real
            // write failure must surface instead of being retried elsewhere.
            guard status == errSecMissingEntitlement else { break }
        }
        throw KeychainError.unexpectedStatus(lastStatus)
    }

    public func loadAccount() throws -> Account? {
        for backend in Self.backends {
            var query = baseQuery(backend)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            let (status, result) = client.copyMatching(query)
            switch status {
            case errSecSuccess:
                guard let data = result,
                      let account = try? JSONDecoder().decode(Account.self, from: data) else {
                    throw KeychainError.corruptedData
                }
                if backend == .legacy {
                    // One-time migration: re-store in the data-protection
                    // Keychain so later writes aren't blocked by the old ACL.
                    // Idempotent — the legacy item is only purged after the
                    // data-protection write succeeds, so a failure here simply
                    // retries on the next load.
                    do {
                        try saveAccount(account)
                    } catch {
                        let detail = (error as? KeychainError)?.errorDescription ?? "unrecognized error"
                        Self.logger.notice("Legacy Keychain migration failed; will retry on next load: \(detail, privacy: .public)")
                    }
                }
                return account
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw KeychainError.unexpectedStatus(status)
            }
        }
        return nil
    }

    public func deleteAccount() throws {
        var lastStatus = errSecSuccess
        for backend in Self.backends {
            let status = client.delete(baseQuery(backend))
            switch status {
            case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                lastStatus = status
            }
        }
        guard lastStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(lastStatus)
        }
    }

    private func write(_ data: Data, to backend: Backend) -> OSStatus {
        // Update-first: never delete the only stored credential. An in-place
        // update either succeeds or leaves the previous item intact — the old
        // delete-then-add flow could destroy the account when the delete
        // succeeded and the add then failed.
        let updated = client.update(baseQuery(backend), [kSecValueData as String: data])
        guard updated == errSecItemNotFound else { return updated }

        var attributes = baseQuery(backend, synchronizable: true)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        var status = client.add(attributes)
        if status == errSecMissingEntitlement {
            // Synchronizable items need an application-identifier entitlement
            // (provisioning profile). Developer ID builds don't have one —
            // store the account locally instead of failing.
            attributes[kSecAttrSynchronizable as String] = false
            status = client.add(attributes)
        }
        if status == errSecDuplicateItem {
            // An item appeared between the update and the add (racing writer,
            // or an item the initial update couldn't match): update in place.
            status = client.update(baseQuery(backend), [kSecValueData as String: data])
        }
        return status
    }

    /// Best-effort removal of the pre-migration login-Keychain item once the
    /// data-protection Keychain holds the account. The old ACL may reject the
    /// delete — harmless, since the data-protection item is authoritative and
    /// `loadAccount` reads it first.
    private func purgeLegacyItem() {
        #if os(macOS)
        // Restricted to non-synchronizable items: legacy queries can reach
        // iCloud-synced items, and this must never race the write above.
        _ = client.delete(baseQuery(.legacy, synchronizable: false))
        #endif
    }

    private func baseQuery(_ backend: Backend, synchronizable: Any? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            // Match both synced items and pre-sync local ones (migration).
            kSecAttrSynchronizable as String: synchronizable ?? kSecAttrSynchronizableAny,
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
