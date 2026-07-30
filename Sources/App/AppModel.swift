import Foundation
import SwiftUI

/// App-wide state: the currently configured account. Views observe this so
/// the channel browser reacts when an account is saved or removed.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var account: Account?

    private let store: KeychainStore

    init(store: KeychainStore = KeychainStore()) {
        self.store = store
        if DemoMode.isActive {
            self.account = DemoMode.account
        } else {
            self.account = (try? store.loadAccount()) ?? nil
        }
        if account == nil {
            // Nothing to migrate the pre-scoping last-channel keys into, so drop
            // them rather than let the next account inherit them.
            LastChannelStore.discardLegacyValues()
        }
    }

    func saveAccount(_ account: Account) throws {
        try store.saveAccount(account)
        self.account = account
    }

    func removeAccount() throws {
        if account == DemoMode.account {
            account = nil // sample mode isn't persisted; just exit it
            return
        }
        try store.deleteAccount()
        account = nil
    }

    /// User-facing "Sample channels": browse and play legal public streams
    /// without a subscription. Not persisted to the Keychain.
    func startSampleMode() {
        account = DemoMode.account
    }
}
