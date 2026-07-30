import XCTest
@testable import IronTV

@MainActor
final class AppModelTests: XCTestCase {

    private final class FakeStore: AccountStoring {
        var loadResult: Result<Account?, Error> = .success(nil)
        var deleteError: Error?
        private(set) var deleteCount = 0

        func saveAccount(_ account: Account) throws {}
        func loadAccount() throws -> Account? { try loadResult.get() }
        func deleteAccount() throws {
            deleteCount += 1
            if let deleteError { throw deleteError }
        }
    }

    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    func testFailedLoadIsADistinctStateWithANonSecretMessage() {
        let store = FakeStore()
        store.loadResult = .failure(KeychainError.corruptedData)

        let model = AppModel(store: store)

        XCTAssertEqual(model.availability, .failed(message: "The stored account could not be read."))
        XCTAssertNil(model.account, "a failed load must not masquerade as a configured account")
    }

    func testFailureMessageCarriesOnlyTheStatusCode() {
        let store = FakeStore()
        store.loadResult = .failure(KeychainError.unexpectedStatus(-25244))

        let model = AppModel(store: store)

        XCTAssertEqual(model.availability, .failed(message: "Keychain error (-25244)."))
    }

    func testReloadRecoversOnceTheStoreHeals() {
        let store = FakeStore()
        store.loadResult = .failure(KeychainError.corruptedData)
        let model = AppModel(store: store)

        store.loadResult = .success(account)
        model.reloadAccount()

        XCTAssertEqual(model.availability, .loaded(account))
        XCTAssertEqual(model.account, account)
    }

    func testDiscardUnreadableAccountDeletesAndReturnsToTheEmptyState() throws {
        let store = FakeStore()
        store.loadResult = .failure(KeychainError.corruptedData)
        let model = AppModel(store: store)

        try model.discardUnreadableAccount()

        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertEqual(model.availability, .loaded(nil))
    }

    func testDiscardSurfacesDeleteFailuresAndKeepsTheFailedState() {
        let store = FakeStore()
        store.loadResult = .failure(KeychainError.corruptedData)
        store.deleteError = KeychainError.unexpectedStatus(-25293)
        let model = AppModel(store: store)

        XCTAssertThrowsError(try model.discardUnreadableAccount())
        XCTAssertEqual(model.availability, .failed(message: "The stored account could not be read."))
    }

    func testHealthyLoadAndRemovalKeepAvailabilityConsistent() throws {
        let store = FakeStore()
        store.loadResult = .success(account)
        let model = AppModel(store: store)

        XCTAssertEqual(model.availability, .loaded(account))
        try model.removeAccount()
        XCTAssertEqual(model.availability, .loaded(nil))
    }
}
