import Foundation

/// Account persistence as `AppModel` needs it.
///
/// A seam: it lets the Settings flows — validate, save, remove — be tested
/// without touching the real Keychain, the same way ``AccountValidating`` keeps
/// validation off the network.
public protocol AccountStoring {
    func saveAccount(_ account: Account) throws
    func loadAccount() throws -> Account?
    func deleteAccount() throws
}

extension KeychainStore: AccountStoring {}
