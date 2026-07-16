import Foundation
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
    private let service: String
    private let accountName = "xtream-account"

    public init(service: String = "com.quantkernel.irontv") {
        self.service = service
    }

    public func saveAccount(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        try deleteAccount()

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // Sync the account via iCloud Keychain (macOS/iOS/iPadOS; Apple TV
        // doesn't receive iCloud Keychain — the URL is re-entered there).
        attributes[kSecAttrSynchronizable as String] = true

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func loadAccount() throws -> Account? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let account = try? JSONDecoder().decode(Account.self, from: data) else {
                throw KeychainError.corruptedData
            }
            return account
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteAccount() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            // Match both synced items and pre-sync local ones (migration).
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }
}
