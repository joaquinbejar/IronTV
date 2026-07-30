import Foundation
import SwiftUI

/// App-wide state: the currently configured account. Views observe this so
/// the channel browser reacts when an account is saved or removed.
@MainActor
final class AppModel: ObservableObject {
    /// Whether the stored account could be read at all. A load failure is a
    /// distinct, recoverable state — not the same as "no account configured":
    /// a credential probably still exists, it just couldn't be read (corrupted
    /// payload, entitlement/signing change, genuine Keychain error).
    enum AccountAvailability: Equatable {
        case loaded(Account?)
        case failed(message: String)
    }

    @Published private(set) var availability: AccountAvailability

    /// Convenience the rest of the app reads; `nil` while the load has failed.
    var account: Account? {
        if case .loaded(let account) = availability { return account }
        return nil
    }

    private let store: AccountStoring

    init(store: AccountStoring = KeychainStore()) {
        self.store = store
        if DemoMode.isActive {
            availability = .loaded(DemoMode.account)
        } else {
            availability = Self.loadAvailability(from: store)
        }
        if case .loaded(nil) = availability {
            // Genuinely no account: nothing to migrate the pre-scoping
            // last-channel keys into, so drop them rather than let the next
            // account inherit them. Deliberately NOT done on a failed load —
            // an account probably still exists there.
            LastChannelStore.discardLegacyValues()
        }
    }

    /// Retry after a failed startup load — e.g. once the Keychain becomes
    /// available again.
    func reloadAccount() {
        availability = Self.loadAvailability(from: store)
    }

    /// Recovery for an unreadable stored account (corrupted payload, or an
    /// item bound to a previous signature): delete it from every back-end and
    /// return to the clean no-account state so it can be added again.
    func discardUnreadableAccount() throws {
        try store.deleteAccount()
        availability = .loaded(nil)
    }

    func saveAccount(_ account: Account) throws {
        try store.saveAccount(account)
        availability = .loaded(account)
    }

    func removeAccount() throws {
        if account == DemoMode.account {
            availability = .loaded(nil) // sample mode isn't persisted; just exit it
            return
        }
        try store.deleteAccount()
        availability = .loaded(nil)
    }

    /// User-facing "Sample channels": browse and play legal public streams
    /// without a subscription. Not persisted to the Keychain.
    func startSampleMode() {
        availability = .loaded(DemoMode.account)
    }

    /// The failure message is the typed error's own description — status codes
    /// and fixed copy only, never credential data.
    private static func loadAvailability(from store: AccountStoring) -> AccountAvailability {
        do {
            return .loaded(try store.loadAccount())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(message: message)
        }
    }
}
