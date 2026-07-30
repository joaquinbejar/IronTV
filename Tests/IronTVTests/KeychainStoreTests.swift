import Security
import XCTest
@testable import IronTV

final class KeychainStoreTests: XCTestCase {

    /// Scripted Security.framework double: returns queued results per call and
    /// records every call in order, so tests can assert both outcomes and the
    /// exact sequence (e.g. "no delete before the replacement is secured").
    private final class ScriptedSecItemClient: SecItemClient {
        var copyResults: [(OSStatus, Data?)] = []
        var addResults: [OSStatus] = []
        var updateResults: [OSStatus] = []
        var deleteResults: [OSStatus] = []

        private(set) var copies: [[String: Any]] = []
        private(set) var adds: [[String: Any]] = []
        private(set) var updates: [[String: Any]] = []
        private(set) var deletes: [[String: Any]] = []
        /// Call order as "copy"/"add"/"update"/"delete" tokens.
        private(set) var sequence: [String] = []

        func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
            copies.append(query)
            sequence.append("copy")
            return copyResults.isEmpty ? (errSecItemNotFound, nil) : copyResults.removeFirst()
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            adds.append(attributes)
            sequence.append("add")
            return addResults.isEmpty ? errSecSuccess : addResults.removeFirst()
        }

        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
            updates.append(query)
            sequence.append("update")
            return updateResults.isEmpty ? errSecItemNotFound : updateResults.removeFirst()
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            deletes.append(query)
            sequence.append("delete")
            return deleteResults.isEmpty ? errSecSuccess : deleteResults.removeFirst()
        }
    }

    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    private func accountData() throws -> Data {
        try JSONEncoder().encode(account)
    }

    private func makeStore(_ client: ScriptedSecItemClient) -> KeychainStore {
        KeychainStore(service: "test.irontv", client: client)
    }

    // MARK: - Load

    func testLoadReturnsNilWhenNoBackendHasAnItem() throws {
        let client = ScriptedSecItemClient()
        client.copyResults = [(errSecItemNotFound, nil), (errSecItemNotFound, nil)]

        XCTAssertNil(try makeStore(client).loadAccount())
        XCTAssertEqual(client.copies.count, 2, "both backends must be consulted")
    }

    func testLoadReturnsTheDataProtectionItem() throws {
        let client = ScriptedSecItemClient()
        client.copyResults = [(errSecSuccess, try accountData())]

        XCTAssertEqual(try makeStore(client).loadAccount(), account)
        XCTAssertEqual(client.copies.count, 1)
        XCTAssertTrue(client.deletes.isEmpty)
    }

    func testLoadThrowsCorruptedDataForAnUndecodablePayload() {
        let client = ScriptedSecItemClient()
        client.copyResults = [(errSecSuccess, Data("not json".utf8))]

        XCTAssertThrowsError(try makeStore(client).loadAccount()) { error in
            XCTAssertEqual(error as? KeychainError, .corruptedData)
        }
    }

    func testLoadFailsWhenNoBackendIsUsable() {
        let client = ScriptedSecItemClient()
        // Every backend reports a missing entitlement: nothing was actually
        // consulted, so "no account" would be a lie — this must fail.
        client.copyResults = [(errSecMissingEntitlement, nil), (errSecMissingEntitlement, nil)]

        XCTAssertThrowsError(try makeStore(client).loadAccount()) { error in
            XCTAssertEqual(error as? KeychainError, .unexpectedStatus(errSecMissingEntitlement))
        }
    }

    func testLoadTrustsAnEmptyLegacyBackendWhenDataProtectionIsUnavailable() throws {
        let client = ScriptedSecItemClient()
        // The macOS fallback: data protection unusable, legacy readable and
        // genuinely empty — nil is a trustworthy answer here.
        client.copyResults = [(errSecMissingEntitlement, nil), (errSecItemNotFound, nil)]

        XCTAssertNil(try makeStore(client).loadAccount())
    }

    func testLoadSurfacesUnexpectedStatuses() {
        let client = ScriptedSecItemClient()
        client.copyResults = [(errSecAuthFailed, nil)]

        XCTAssertThrowsError(try makeStore(client).loadAccount()) { error in
            XCTAssertEqual(error as? KeychainError, .unexpectedStatus(errSecAuthFailed))
        }
    }

    // MARK: - Save (update-first, never destructive)

    func testSaveUpdatesInPlaceWithoutDeletingOrAdding() throws {
        let client = ScriptedSecItemClient()
        client.updateResults = [errSecSuccess]

        try makeStore(client).saveAccount(account)

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertTrue(client.adds.isEmpty)
        // The only delete is the post-success legacy purge — never a pre-delete.
        XCTAssertEqual(client.sequence, ["update", "delete"])
        let purge = try XCTUnwrap(client.deletes.first)
        XCTAssertNil(purge[kSecUseDataProtectionKeychain as String], "purge must target the legacy backend")
        XCTAssertEqual(purge[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testSaveAddsWhenNoItemExists() throws {
        let client = ScriptedSecItemClient()
        client.updateResults = [errSecItemNotFound]
        client.addResults = [errSecSuccess]

        try makeStore(client).saveAccount(account)

        XCTAssertEqual(client.sequence, ["update", "add", "delete"])
    }

    func testSaveFallsBackToALocalItemWithoutTheSyncEntitlement() throws {
        let client = ScriptedSecItemClient()
        client.updateResults = [errSecItemNotFound]
        client.addResults = [errSecMissingEntitlement, errSecSuccess]

        try makeStore(client).saveAccount(account)

        XCTAssertEqual(client.adds.count, 2)
        XCTAssertEqual(client.adds[1][kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testSaveResolvesAnAddRaceByUpdating() throws {
        let client = ScriptedSecItemClient()
        client.updateResults = [errSecItemNotFound, errSecSuccess]
        client.addResults = [errSecDuplicateItem]

        try makeStore(client).saveAccount(account)

        XCTAssertEqual(client.sequence, ["update", "add", "update", "delete"])
    }

    func testFailedReplacementThrowsAndNeverDeletesTheStoredItem() {
        let client = ScriptedSecItemClient()
        // e.g. a legacy-ACL denial: the update fails, the old item survives.
        client.updateResults = [errSecInvalidOwnerEdit]

        XCTAssertThrowsError(try makeStore(client).saveAccount(account)) { error in
            XCTAssertEqual(error as? KeychainError, .unexpectedStatus(errSecInvalidOwnerEdit))
        }
        XCTAssertTrue(client.deletes.isEmpty, "the only stored credential must never be deleted on a failed write")
        XCTAssertTrue(client.adds.isEmpty)
    }

    func testSaveFallsBackToTheLegacyBackendWithoutTheDataProtectionEntitlement() throws {
        let client = ScriptedSecItemClient()
        // Data-protection backend unusable; legacy add succeeds.
        client.updateResults = [errSecMissingEntitlement, errSecItemNotFound]
        client.addResults = [errSecSuccess]

        try makeStore(client).saveAccount(account)

        XCTAssertEqual(client.updates.count, 2, "must move on to the legacy backend")
        XCTAssertTrue(client.deletes.isEmpty, "no purge when the account lives in the legacy backend")
    }

    // MARK: - Migration

    func testLegacyLoadMigratesAndPurgesOnSuccess() throws {
        let client = ScriptedSecItemClient()
        client.copyResults = [(errSecItemNotFound, nil), (errSecSuccess, try accountData())]
        client.updateResults = [errSecSuccess] // migration write into data protection

        XCTAssertEqual(try makeStore(client).loadAccount(), account)
        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(client.deletes.count, 1, "successful migration purges the legacy item")
    }

    func testFailedMigrationStillReturnsTheAccountAndKeepsTheLegacyItem() throws {
        let client = ScriptedSecItemClient()
        client.copyResults = [(errSecItemNotFound, nil), (errSecSuccess, try accountData())]
        client.updateResults = [errSecAuthFailed] // migration write denied

        XCTAssertEqual(try makeStore(client).loadAccount(), account, "a failed migration must not lose the account")
        XCTAssertTrue(client.deletes.isEmpty, "the legacy item must survive until migration succeeds")
    }

    // MARK: - Delete

    func testDeleteRemovesTheItemFromEveryBackend() throws {
        let client = ScriptedSecItemClient()
        client.deleteResults = [errSecSuccess, errSecSuccess]

        try makeStore(client).deleteAccount()

        XCTAssertEqual(client.deletes.count, 2)
    }

    func testDeleteToleratesMissingItemsAndEntitlements() throws {
        let client = ScriptedSecItemClient()
        client.deleteResults = [errSecItemNotFound, errSecMissingEntitlement]

        XCTAssertNoThrow(try makeStore(client).deleteAccount())
    }

    func testDeleteSurfacesRealFailures() {
        let client = ScriptedSecItemClient()
        client.deleteResults = [errSecSuccess, errSecAuthFailed]

        XCTAssertThrowsError(try makeStore(client).deleteAccount()) { error in
            XCTAssertEqual(error as? KeychainError, .unexpectedStatus(errSecAuthFailed))
        }
    }
}
