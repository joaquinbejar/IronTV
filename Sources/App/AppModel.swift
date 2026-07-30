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
    private let discardLegacyChannelKeys: () -> Void

    init(
        store: AccountStoring = KeychainStore(),
        discardLegacyChannelKeys: @escaping () -> Void = { LastChannelStore.discardLegacyValues() }
    ) {
        self.store = store
        self.discardLegacyChannelKeys = discardLegacyChannelKeys
        self.availability = .loaded(nil) // replaced by the transition below
        if DemoMode.isActive {
            transition(to: .loaded(DemoMode.account))
        } else {
            transition(to: Self.loadAvailability(from: store))
        }
    }

    /// Retry after a failed startup load — e.g. once the Keychain becomes
    /// available again.
    func reloadAccount() {
        transition(to: Self.loadAvailability(from: store))
    }

    /// Recovery for an unreadable stored account (corrupted payload, or an
    /// item bound to a previous signature): delete it from every back-end and
    /// return to the clean no-account state so it can be added again.
    func discardUnreadableAccount() throws {
        try store.deleteAccount()
        transition(to: .loaded(nil))
    }

    func saveAccount(_ account: Account) throws {
        try store.saveAccount(account)
        transition(to: .loaded(account))
    }

    func removeAccount() throws {
        if account == DemoMode.account {
            transition(to: .loaded(nil)) // sample mode isn't persisted; just exit it
            return
        }
        try store.deleteAccount()
        transition(to: .loaded(nil))
    }

    /// User-facing "Sample channels": browse and play legal public streams
    /// without a subscription. Not persisted to the Keychain, and deliberately
    /// reachable from the failed state — sample playback needs no credentials.
    func startSampleMode() {
        transition(to: .loaded(DemoMode.account))
    }

    /// Every availability change funnels through here so the empty state gets
    /// its cleanup no matter which path reached it: whenever there is
    /// genuinely no account, the pre-scoping last-channel keys are dropped so
    /// the next account cannot inherit a previous provider's selection.
    /// Deliberately NOT done on a failed load — an account probably still
    /// exists there.
    private func transition(to newValue: AccountAvailability) {
        availability = newValue
        if case .loaded(nil) = newValue {
            discardLegacyChannelKeys()
        }
    }

    /// Fixed, non-secret copy only: a typed `KeychainError` description
    /// (status codes and fixed strings), or a generic fallback — never an
    /// arbitrary error's own text.
    static func nonSecretMessage(for error: Error) -> String {
        (error as? KeychainError)?.errorDescription ?? String(localized: "The stored account could not be accessed.")
    }

    private static func loadAvailability(from store: AccountStoring) -> AccountAvailability {
        do {
            return .loaded(try store.loadAccount())
        } catch {
            return .failed(message: Self.nonSecretMessage(for: error))
        }
    }
}
