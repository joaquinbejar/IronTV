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
    }

    func saveAccount(_ account: Account) throws {
        try store.saveAccount(account)
        self.account = account
    }

    func removeAccount() throws {
        try store.deleteAccount()
        account = nil
    }
}
