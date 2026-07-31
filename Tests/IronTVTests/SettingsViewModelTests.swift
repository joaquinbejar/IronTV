import XCTest
@testable import IronTV

@MainActor
final class SettingsViewModelTests: XCTestCase {

    private let validURL = "http://host.example.com:8080/get.php?username=user1&password=pass1"
    private let otherURL = "http://host.example.com:8080/get.php?username=user2&password=pass2"
    /// For tests whose subject is transport-independent — https skips the probe.
    private let validHTTPSURL = "https://host.example.com:8080/get.php?username=user1&password=pass1"

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

    private func authenticated(expiry: Date? = nil, advertisedHTTPSPort: Int? = nil) -> AccountStatus {
        AccountStatus(
            authenticated: true,
            status: "Active",
            expiryDate: expiry,
            maxConnections: 2,
            advertisedHTTPSPort: advertisedHTTPSPort
        )
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

    /// Records the migrations the view model requested on a verified upgrade.
    private final class MigrationSpy {
        var migrations: [(from: Account, to: Account)] = []
    }

    /// Variant whose panel double answers per URL scheme, so the https probe
    /// and the http fallback can be scripted independently.
    private func makeViewModel(
        resultsByScheme: [String: Result<AccountStatus, Error>],
        settings: PlaybackSettings = .default,
        spy: FactorySpy = FactorySpy(),
        migrations: MigrationSpy = MigrationSpy()
    ) -> (SettingsViewModel, FactorySpy) {
        let viewModel = SettingsViewModel(
            makeClient: { account, timeout in
                spy.accounts.append(account)
                spy.timeouts.append(timeout)
                let scheme = account.host.scheme?.lowercased() ?? ""
                let result = resultsByScheme[scheme] ?? .failure(URLError(.unsupportedURL))
                return FakeClient(result: result)
            },
            currentSettings: { settings },
            migratePreferences: { migrations.migrations.append((from: $0, to: $1)) }
        )
        return (viewModel, spy)
    }

    /// Variant whose panel double answers per origin (`"scheme:port"`), so the
    /// same-port twin probe, the http validation, and the advertised-port
    /// probe can be scripted independently.
    private func makeViewModel(
        resultsByOrigin: [String: Result<AccountStatus, Error>],
        gatesByOrigin: [String: Gate] = [:],
        settings: PlaybackSettings = .default,
        spy: FactorySpy = FactorySpy(),
        migrations: MigrationSpy = MigrationSpy()
    ) -> (SettingsViewModel, FactorySpy) {
        let viewModel = SettingsViewModel(
            makeClient: { account, timeout in
                spy.accounts.append(account)
                spy.timeouts.append(timeout)
                let origin = Self.origin(of: account)
                let result = resultsByOrigin[origin] ?? .failure(URLError(.unsupportedURL))
                return FakeClient(result: result, gate: gatesByOrigin[origin])
            },
            currentSettings: { settings },
            migratePreferences: { migrations.migrations.append((from: $0, to: $1)) }
        )
        return (viewModel, spy)
    }

    private static func origin(of account: Account) -> String {
        "\(account.host.scheme ?? ""):\(account.host.port.map(String.init) ?? "")"
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

        viewModel.urlText = validHTTPSURL
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

        viewModel.urlText = validHTTPSURL
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

    // MARK: - Insecure transport

    func testHTTPURLUpgradesToVerifiedHTTPSWithoutWarning() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let (viewModel, spy) = makeViewModel(resultsByScheme: ["https": .success(authenticated())])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil))
        XCTAssertEqual(store.saved?.host.scheme, "https")
        XCTAssertEqual(store.saved?.host.port, 8080, "the upgrade must keep the entered port")
        XCTAssertEqual(spy.accounts.map { $0.host.scheme ?? "" }, ["https"], "nothing may go over plain http")
    }

    func testHTTPURLWithNoTLSEndpointAsksForConfirmationBeforeAnyPlaintext() async {
        let store = FakeAccountStore()
        let (viewModel, spy) = makeViewModel(resultsByScheme: [
            "https": .failure(URLError(.secureConnectionFailed)),
            "http": .success(authenticated()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: AppModel(store: store))

        XCTAssertEqual(viewModel.phase, .confirmingInsecureTransport)
        XCTAssertEqual(spy.accounts.map { $0.host.scheme ?? "" }, ["https"], "no request may hit http before consent")
        XCTAssertNil(store.saved)
        XCTAssertEqual(viewModel.urlText, validURL, "the pasted text must stay editable")
    }

    func testConfirmingInsecureTransportValidatesOverHTTP() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let (viewModel, spy) = makeViewModel(resultsByScheme: [
            "https": .failure(URLError(.secureConnectionFailed)),
            "http": .success(authenticated()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil))
        XCTAssertEqual(store.saved?.host.scheme, "http")
        XCTAssertEqual(spy.accounts.map { $0.host.scheme ?? "" }, ["https", "http"])
    }

    func testCancellingInsecureTransportSendsAndSavesNothing() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let (viewModel, spy) = makeViewModel(resultsByScheme: [
            "https": .failure(URLError(.secureConnectionFailed)),
            "http": .success(authenticated()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        viewModel.cancelInsecureTransport()

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNil(store.saved)
        XCTAssertEqual(spy.accounts.map { $0.host.scheme ?? "" }, ["https"])

        // A confirmation after cancel must be a stale no-op.
        await viewModel.confirmInsecureTransport(into: appModel)
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(spy.callCount, 1)
    }

    func testTLSHTTPStatusRejectionFailsWithoutOfferingPlaintext() async {
        let store = FakeAccountStore()
        for code in [401, 403] {
            let (viewModel, spy) = makeViewModel(resultsByScheme: [
                "https": .failure(XtreamAPIError.httpStatus(code)),
                "http": .success(authenticated()),
            ])

            viewModel.urlText = validURL
            await viewModel.validateAndSave(into: AppModel(store: store))

            XCTAssertEqual(viewModel.phase, .failure("The panel rejected these credentials (HTTP \(code))."))
            XCTAssertEqual(spy.accounts.map { $0.host.scheme ?? "" }, ["https"], "an explicit TLS rejection must not offer a plaintext retry")
            XCTAssertNil(store.saved)
        }
    }

    func testTLSTransportFailureStillReachesTheConfirmation() async {
        // A 5xx or connection failure says nothing about the credentials —
        // the compatibility confirmation must stay available.
        let (viewModel, _) = makeViewModel(resultsByScheme: [
            "https": .failure(XtreamAPIError.httpStatus(503)),
            "http": .success(authenticated()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: AppModel(store: FakeAccountStore()))

        XCTAssertEqual(viewModel.phase, .confirmingInsecureTransport)
    }

    func testTLSRejectionFailsWithoutFallingBackToPlaintext() async {
        let store = FakeAccountStore()
        let (viewModel, spy) = makeViewModel(resultsByScheme: [
            "https": .success(rejected()),
            "http": .success(authenticated()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: AppModel(store: store))

        XCTAssertEqual(viewModel.phase, .failure("The panel rejected these credentials (status: Expired)."))
        XCTAssertEqual(spy.accounts.map { $0.host.scheme ?? "" }, ["https"], "refused credentials must not be retried over plaintext")
        XCTAssertNil(store.saved)
    }

    func testEditingTextDropsThePendingConfirmation() async {
        let appModel = AppModel(store: FakeAccountStore())
        let (viewModel, spy) = makeViewModel(resultsByScheme: [
            "https": .failure(URLError(.secureConnectionFailed)),
            "http": .success(authenticated()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        XCTAssertEqual(viewModel.phase, .confirmingInsecureTransport)

        viewModel.urlText = otherURL
        XCTAssertEqual(viewModel.phase, .idle)

        await viewModel.confirmInsecureTransport(into: appModel)
        XCTAssertEqual(spy.callCount, 1, "a confirmation for edited text must not fire")
    }

    func testHTTPSProbeUsesCappedTimeoutAndFallbackUsesConfiguredOne() async {
        var settings = PlaybackSettings.default
        settings.apiTimeoutSeconds = 75
        let appModel = AppModel(store: FakeAccountStore())
        let (viewModel, spy) = makeViewModel(
            resultsByScheme: [
                "https": .failure(URLError(.secureConnectionFailed)),
                "http": .success(authenticated()),
            ],
            settings: settings
        )

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(spy.timeouts, [8, 75], "probe is capped so a filtered TLS port can't stall the warning")
    }

    func testVerifiedUpgradeMigratesPreferencesFromTheHTTPAccount() async throws {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let previous = Account(host: URL(string: "http://host.example.com:8080")!, username: "user1", password: "oldpass")
        try appModel.saveAccount(previous)
        let migrations = MigrationSpy()
        let (viewModel, _) = makeViewModel(
            resultsByScheme: ["https": .success(authenticated())],
            migrations: migrations
        )

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)

        XCTAssertEqual(store.saved?.host.scheme, "https")
        XCTAssertEqual(migrations.migrations.count, 1)
        XCTAssertEqual(migrations.migrations.first?.from, previous)
        XCTAssertEqual(migrations.migrations.first?.to.host.scheme, "https")
    }

    // MARK: - Advertised HTTPS port upgrade

    func testConfirmedHTTPUpgradesToTheAdvertisedHTTPSPort() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        // Distinct expiries: what the UI reports must come from the TLS
        // endpoint actually saved, not the http response it replaced.
        let probedExpiry = Date(timeIntervalSince1970: 1_767_225_600)
        let (viewModel, spy) = makeViewModel(resultsByOrigin: [
            "https:8080": .failure(URLError(.secureConnectionFailed)),
            "http:8080": .success(authenticated(expiry: Date(timeIntervalSince1970: 1_700_000_000), advertisedHTTPSPort: 8443)),
            "https:8443": .success(authenticated(expiry: probedExpiry)),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        XCTAssertEqual(viewModel.phase, .confirmingInsecureTransport)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: probedExpiry), "success must report the saved endpoint's own status")
        XCTAssertEqual(store.saved?.host.scheme, "https")
        XCTAssertEqual(store.saved?.host.port, 8443, "the account must land on the advertised TLS port")
        XCTAssertEqual(spy.accounts.map(Self.origin(of:)), ["https:8080", "http:8080", "https:8443"])
        XCTAssertEqual(spy.timeouts, [8, 30, 8], "the advertised-port probe is capped like the twin probe")
    }

    func testUnreachableAdvertisedPortKeepsTheConfirmedHTTPAccount() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let (viewModel, _) = makeViewModel(resultsByOrigin: [
            "https:8080": .failure(URLError(.secureConnectionFailed)),
            "http:8080": .success(authenticated(advertisedHTTPSPort: 8443)),
            "https:8443": .failure(URLError(.timedOut)),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil), "a dead advertised port must never block the save")
        XCTAssertEqual(store.saved?.host.scheme, "http")
        XCTAssertEqual(store.saved?.host.port, 8080)
    }

    func testRejectedAdvertisedPortKeepsTheConfirmedHTTPAccount() async {
        // The TLS endpoint answered but refused the credentials — a different
        // vhost or a stale panel config. The http account the panel just
        // authenticated is what the user gets.
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let (viewModel, _) = makeViewModel(resultsByOrigin: [
            "https:8080": .failure(URLError(.secureConnectionFailed)),
            "http:8080": .success(authenticated(advertisedHTTPSPort: 8443)),
            "https:8443": .success(rejected()),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil))
        XCTAssertEqual(store.saved?.host.scheme, "http")
    }

    func testAdvertisedPortEqualToTheProbedTwinIsNotRetried() async {
        // The same-port twin already failed before the confirmation — an
        // advertised port pointing at that same endpoint adds nothing.
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let (viewModel, spy) = makeViewModel(resultsByOrigin: [
            "https:8080": .failure(URLError(.secureConnectionFailed)),
            "http:8080": .success(authenticated(advertisedHTTPSPort: 8080)),
        ])

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil))
        XCTAssertEqual(store.saved?.host.scheme, "http")
        XCTAssertEqual(spy.accounts.map(Self.origin(of:)), ["https:8080", "http:8080"])
    }

    func testAdvertisedPortUpgradeMigratesPreferencesFromThePreviousAccount() async throws {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let previous = Account(host: URL(string: "http://host.example.com:8080")!, username: "user1", password: "oldpass")
        try appModel.saveAccount(previous)
        let migrations = MigrationSpy()
        let (viewModel, _) = makeViewModel(
            resultsByOrigin: [
                "https:8080": .failure(URLError(.secureConnectionFailed)),
                "http:8080": .success(authenticated(advertisedHTTPSPort: 8443)),
                "https:8443": .success(authenticated()),
            ],
            migrations: migrations
        )

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        await viewModel.confirmInsecureTransport(into: appModel)

        XCTAssertEqual(store.saved?.host.port, 8443)
        XCTAssertEqual(migrations.migrations.count, 1)
        XCTAssertEqual(migrations.migrations.first?.from, previous)
        XCTAssertEqual(migrations.migrations.first?.to.host.port, 8443)
    }

    func testEditingDuringTheAdvertisedPortProbeDiscardsTheResult() async {
        let store = FakeAccountStore()
        let appModel = AppModel(store: store)
        let gate = Gate()
        let (viewModel, _) = makeViewModel(
            resultsByOrigin: [
                "https:8080": .failure(URLError(.secureConnectionFailed)),
                "http:8080": .success(authenticated(advertisedHTTPSPort: 8443)),
                "https:8443": .success(authenticated()),
            ],
            gatesByOrigin: ["https:8443": gate]
        )

        viewModel.urlText = validURL
        await viewModel.validateAndSave(into: appModel)
        let confirmation = Task { await viewModel.confirmInsecureTransport(into: appModel) }
        await Task.yield()

        viewModel.urlText = otherURL
        await gate.open()
        await confirmation.value

        XCTAssertNil(store.saved, "a stale upgrade completion must not save any account")
        XCTAssertEqual(viewModel.phase, .idle)
    }

    func testHTTPSURLValidatesDirectlyWithoutProbe() async {
        let store = FakeAccountStore()
        let (viewModel, spy) = makeViewModel(resultsByScheme: ["https": .success(authenticated())])

        viewModel.urlText = "https://host.example.com:8443/get.php?username=user1&password=pass1"
        await viewModel.validateAndSave(into: AppModel(store: store))

        XCTAssertEqual(viewModel.phase, .success(expiryDate: nil))
        XCTAssertEqual(store.saved?.host.scheme, "https")
        XCTAssertEqual(spy.callCount, 1)
    }

    // MARK: - Success copy

    func testSuccessMessageDistinguishesExpiryShapes() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let future = Date(timeIntervalSince1970: 1_803_727_680)
        let past = Date(timeIntervalSince1970: 1_600_000_000)

        XCTAssertEqual(
            SettingsViewModel.successMessage(expiryDate: nil, now: now),
            "Account valid (no expiry reported)"
        )
        XCTAssertEqual(
            SettingsViewModel.successMessage(expiryDate: future, now: now),
            "Account valid until \(future.formatted(date: .abbreviated, time: .omitted))"
        )
        XCTAssertEqual(
            SettingsViewModel.successMessage(expiryDate: past, now: now),
            "Account valid, but the panel reports it expired on \(past.formatted(date: .abbreviated, time: .omitted))"
        )
    }
}
