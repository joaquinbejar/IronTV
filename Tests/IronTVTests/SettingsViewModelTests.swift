import XCTest
@testable import IronTV

@MainActor
final class SettingsViewModelTests: XCTestCase {

    private let validURL = "http://host.example.com:8080/get.php?username=user1&password=pass1"
    private let otherURL = "http://host.example.com:8080/get.php?username=user2&password=pass2"

    // MARK: - Doubles

    /// In-memory account store, so no test touches the real Keychain.
    private final class FakeAccountStore: AccountStoring {
        var saved: Account?
        var saveError: Error?
        var deleteError: Error?

        func saveAccount(_ account: Account) throws {
            if let saveError { throw saveError }
            saved = account
        }

        func loadAccount() throws -> Account? { saved }

        func deleteAccount() throws {
            if let deleteError { throw deleteError }
            saved = nil
        }
    }

    /// Panel double. `gate` lets a test hold a request in flight and decide when
    /// it completes, which is what makes the stale-completion cases deterministic.
    private final class FakeClient: AccountValidating, @unchecked Sendable {
        let result: Result<AccountStatus, Error>
        let gate: Gate?

        init(result: Result<AccountStatus, Error>, gate: Gate? = nil) {
            self.result = result
            self.gate = gate
        }

        func accountStatus() async throws -> AccountStatus {
            if let gate {
                await gate.wait()
            }
            return try result.get()
        }
    }

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }

    private func authenticated(expiry: Date? = nil) -> AccountStatus {
        AccountStatus(authenticated: true, status: "Active", expiryDate: expiry, maxConnections: 2)
    }

    private func rejected() -> AccountStatus {
        AccountStatus(authenticated: false, status: "Expired", expiryDate: nil, maxConnections: nil)
    }

    /// Records what the factory was handed, so the timeout wiring is observable.
    private final class FactorySpy {
        var accounts: [Account] = []
        var timeouts: [TimeInterval] = []
        var callCount: Int { accounts.count }
    }

    private func makeViewModel(
        result: Result<AccountStatus, Error>,
        gate: Gate? = nil,
        settings: PlaybackSettings = .default,
        spy: FactorySpy = FactorySpy()
    ) -> (SettingsViewModel, FactorySpy) {
        let viewModel = SettingsViewModel(
            makeClient: { account, timeout in
                spy.accounts.append(account)
                spy.timeouts.append(timeout)
                return FakeClient(result: result, gate: gate)
            },
            currentSettings: { settings }
        )
        return (viewModel, spy)
    }

    // MARK: - Success

    func testSuccessSavesTheAccountAndClearsTheCredentialField() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let expiry = Date(timeIntervalSince1970: 1_767_225_600)
        let (viewModel, spy) = makeViewModel(result: .success(authenticated(expiry: expiry)))

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: expiry))
        XCTAssertEqual(store.saved?.username, "user1")
        XCTAssertEqual(appModel.account?.username, "user1")
        // The URL carries the password — it must not survive the save.
        XCTAssertEqual(viewModel.urlText, "")
        XCTAssertEqual(spy.callCount, 1)
    }

    func testValidationUsesTheConfiguredAPITimeout() async {
        var settings = PlaybackSettings.default
        settings.apiTimeoutSeconds = 75
        let (viewModel, spy) = makeViewModel(result: .success(authenticated()), settings: settings)

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: AppModel(store: FakeAccountStore()))

        XCTAssertEqual(spy.timeouts, [75])
    }

    // MARK: - Rejection and failure

    func testPanelRejectionReportsFailureAndSavesNothing() async {
        let store = FakeAccountStore()
        let (viewModel, _) = makeViewModel(result: .success(rejected()))

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: AppModel(store: store))

        XCTAssertEqual(viewModel.phase, .failure("The panel rejected these credentials (status: Expired)."))
        XCTAssertNil(store.saved)
        // Still on screen so the user can correct it.
        XCTAssertEqual(viewModel.urlText, validURL)
    }

    func testTimeoutReportsFailureWithoutLeakingTheCredentials() async {
        let store = FakeAccountStore()
        let urlError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: validURL])
        let (viewModel, _) = makeViewModel(result: .failure(XtreamAPIError.network(urlError)))

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: AppModel(store: store))

        guard case .failure(let message) = viewModel.phase else {
            return XCTFail("expected a failure phase, got \(viewModel.phase)")
        }
        XCTAssertFalse(message.contains("pass1"), "credentials leaked into the error text: \(message)")
        XCTAssertFalse(message.contains("get.php"), "the URL leaked into the error text: \(message)")
        XCTAssertNil(store.saved)
    }

    func testUnparseableURLReportsFailureWithoutEchoingTheInput() async {
        let (viewModel, spy) = makeViewModel(result: .success(authenticated()))

        viewModel.urlText = "http://host.example.com/get.php?username=user1"
        await viewModel.validateAndSave(into: AppModel(store: FakeAccountStore()))

        XCTAssertEqual(viewModel.phase, .failure("The URL has no password parameter."))
        XCTAssertEqual(spy.callCount, 0, "no request should be made for input that can't be parsed")
    }

    // MARK: - Cancellation, staleness, dismissal

    func testEditingDuringARequestDiscardsTheInFlightValidation() async {
        let store = FakeAccountStore()
        let gate = Gate()
        let (viewModel, _) = makeViewModel(result: .success(authenticated()), gate: gate)

        viewModel.urlText = validURL
        let submission = Task { await viewModel.validateAndSave(into: AppModel(store: store)) }
        await Task.yield()

        // The user keeps typing while the panel is still answering.
        viewModel.urlText = otherURL
        await gate.open()
        await submission.value

        XCTAssertNil(store.saved, "a stale completion must not save an account")
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.urlText, otherURL)
    }

    func testCancellingValidationLeavesPhaseIdleAndSavesNothing() async {
        let store = FakeAccountStore()
        let gate = Gate()
        let (viewModel, _) = makeViewModel(result: .success(authenticated()), gate: gate)

        viewModel.urlText = validURL
        let submission = Task { await viewModel.validateAndSave(into: AppModel(store: store)) }
        await Task.yield()
        XCTAssertEqual(viewModel.phase, .validating)

        viewModel.cancelValidation()
        await gate.open()
        await submission.value

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNil(store.saved)
    }

    func testDismissingTheFormClearsTheURLAndStopsValidating() async {
        let store = FakeAccountStore()
        let gate = Gate()
        let (viewModel, _) = makeViewModel(result: .success(authenticated()), gate: gate)

        viewModel.urlText = validURL
        let submission = Task { await viewModel.validateAndSave(into: AppModel(store: store)) }
        await Task.yield()

        viewModel.formDismissed()
        await gate.open()
        await submission.value

        XCTAssertEqual(viewModel.urlText, "")
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNil(store.saved)
    }

    /// Latest request wins: the earlier completion must not report back.
    func testASecondSubmissionSupersedesTheFirst() async {
        let store = FakeAccountStore()
        let firstGate = Gate()
        let spy = FactorySpy()
        let viewModel = SettingsViewModel(
            makeClient: { account, timeout in
                spy.accounts.append(account)
                spy.timeouts.append(timeout)
                // Only the first request is held open.
                return FakeClient(result: .success(AccountStatus(
                    authenticated: true,
                    status: "Active",
                    expiryDate: nil,
                    maxConnections: nil
                )), gate: spy.callCount == 1 ? firstGate : nil)
            },
            currentSettings: { .default }
        )
        let appModel = AppModel(store: store)

        viewModel.urlText = validURL
        let first = Task { await viewModel.validateAndSave(into: appModel) }
        await Task.yield()

        viewModel.urlText = otherURL
        let second = Task { await viewModel.validateAndSave(into: appModel) }
        await second.value

        await firstGate.open()
        await first.value

        XCTAssertEqual(store.saved?.username, "user2", "the newest submission must be the one that saves")
        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil))
    }

    // MARK: - Removal

    func testRemovingTheAccountClearsTheFieldAndResetsPhase() async {
        let store = FakeAccountStore()
        let (viewModel, _) = makeViewModel(result: .success(authenticated()))
        let appModel = AppModel(store: store)

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        XCTAssertNotNil(store.saved)

        viewModel.urlText = "leftover text"
        viewModel.removeAccount(from: appModel)

        XCTAssertNil(store.saved)
        XCTAssertNil(appModel.account)
        XCTAssertEqual(viewModel.urlText, "")
        XCTAssertEqual(viewModel.phase, .idle)
    }

    /// A failed removal is no reason to leave a pasted password on screen.
    func testAFailedRemovalStillClearsTheCredentialField() async {
        let store = FakeAccountStore()
        store.deleteError = KeychainError.unexpectedStatus(-25300)
        let (viewModel, _) = makeViewModel(result: .success(authenticated()))
        let appModel = AppModel(store: store)

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        viewModel.urlText = validURL

        viewModel.removeAccount(from: appModel)

        XCTAssertEqual(viewModel.urlText, "")
        guard case .failure = viewModel.phase else {
            return XCTFail("expected the removal failure to be reported, got \(viewModel.phase)")
        }
    }

    // MARK: - The reveal must not outlive the credential it exposes

    func testRevealTogglesAndStartsHidden() {
        let (viewModel, _) = makeViewModel(result: .success(authenticated()))

        XCTAssertFalse(viewModel.isRevealingURL)
        viewModel.toggleURLReveal()
        XCTAssertTrue(viewModel.isRevealingURL)
        viewModel.toggleURLReveal()
        XCTAssertFalse(viewModel.isRevealingURL)
    }

    /// Otherwise the next URL the user pastes shows up in plain text.
    func testASuccessfulSaveReHidesTheField() async {
        let (viewModel, _) = makeViewModel(result: .success(authenticated()))

        viewModel.urlText = validURL
        viewModel.toggleURLReveal()
        await viewModel.validateAndSave(into: AppModel(store: FakeAccountStore()))

        XCTAssertFalse(viewModel.isRevealingURL)
    }

    func testRemovingTheAccountReHidesTheField() {
        let (viewModel, _) = makeViewModel(result: .success(authenticated()))

        viewModel.urlText = validURL
        viewModel.toggleURLReveal()
        viewModel.removeAccount(from: AppModel(store: FakeAccountStore()))

        XCTAssertFalse(viewModel.isRevealingURL)
    }

    func testDismissalReHidesTheField() {
        let (viewModel, _) = makeViewModel(result: .success(authenticated()))

        viewModel.urlText = validURL
        viewModel.toggleURLReveal()
        viewModel.formDismissed()

        XCTAssertFalse(viewModel.isRevealingURL)
    }

    /// A rejected panel leaves the URL on screen to be corrected, so the reveal
    /// the user asked for stays honored.
    func testRejectionKeepsTheRevealTheUserChose() async {
        let (viewModel, _) = makeViewModel(result: .success(rejected()))

        viewModel.urlText = validURL
        viewModel.toggleURLReveal()
        await viewModel.validateAndSave(into: AppModel(store: FakeAccountStore()))

        XCTAssertEqual(viewModel.urlText, validURL)
        XCTAssertTrue(viewModel.isRevealingURL)
    }

    func testCanSubmitRequiresNonEmptyTextAndNoRequestInFlight() async {
        let gate = Gate()
        let (viewModel, _) = makeViewModel(result: .success(authenticated()), gate: gate)

        XCTAssertFalse(viewModel.canSubmit)
        viewModel.urlText = "   "
        XCTAssertFalse(viewModel.canSubmit)
        viewModel.urlText = validURL
        XCTAssertTrue(viewModel.canSubmit)

        let submission = Task { await viewModel.validateAndSave(into: AppModel(store: FakeAccountStore())) }
        await Task.yield()
        XCTAssertFalse(viewModel.canSubmit, "no second submission while one is in flight")

        await gate.open()
        await submission.value
    }
}
