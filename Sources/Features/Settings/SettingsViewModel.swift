import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case validating
        /// An http URL parsed, no TLS twin answered, and nothing has been sent
        /// over plaintext yet — waiting for the user's deliberate go-ahead.
        case confirmingInsecureTransport
        case success(expiryDate: Date?)
        case failure(String)
    }

    /// Success copy for the three shapes a panel reports: a future expiry, no
    /// known expiry (missing/zero/garbage `exp_date`, sanitized to `nil` in the
    /// DTO mapping), and the inconsistent case where authentication succeeded
    /// but the reported expiry is not in the future.
    static func successMessage(expiryDate: Date?, now: Date = Date()) -> String {
        guard let expiryDate else { return "Account valid (no expiry reported)" }
        let formatted = expiryDate.formatted(date: .abbreviated, time: .omitted)
        if expiryDate <= now {
            return "Account valid, but the panel reports it expired on \(formatted)"
        }
        return "Account valid until \(formatted)"
    }

    /// The pasted playlist URL. It carries the account password, so it is
    /// cleared as soon as it is no longer needed — see ``formDismissed()``.
    @Published var urlText = "" {
        didSet {
            // The in-flight request was for text the user has since changed;
            // letting it finish could save an account that doesn't match what
            // is on screen. Only fires while validating or awaiting the HTTP
            // confirmation, so the programmatic clear on success doesn't
            // cancel its own completion.
            guard urlText != oldValue else { return }
            if phase == .validating {
                cancelValidation()
            } else if phase == .confirmingInsecureTransport {
                cancelInsecureTransport()
            }
        }
    }
    @Published private(set) var phase: Phase = .idle

    /// Whether the pasted URL is shown in the clear. It lives here rather than in
    /// the view so it is reset together with the credential it exposes — a reveal
    /// must never carry over to the next URL the user types or pastes.
    @Published private(set) var isRevealingURL = false

    /// Builds the client that checks credentials against the panel. Injectable
    /// so tests can validate offline.
    typealias ClientFactory = @MainActor (Account, TimeInterval) -> AccountValidating

    private let makeClient: ClientFactory
    private let currentSettings: @MainActor () -> PlaybackSettings
    private let migratePreferences: @MainActor (Account, Account) -> Void
    private var validationTask: Task<Void, Never>?
    /// The pasted URL an insecure-transport confirmation refers to. Consumed by
    /// ``confirmInsecureTransport(into:)``; dropped on cancel, edit or dismiss.
    private var pendingInsecureSubmission: String?

    /// Cap on the HTTPS probe so a filtered TLS port cannot stall the
    /// insecure-transport warning behind the full API timeout.
    private static let httpsProbeTimeout: TimeInterval = 8

    init(
        makeClient: @escaping ClientFactory = { XtreamClient(account: $0, requestTimeout: $1) },
        currentSettings: @escaping @MainActor () -> PlaybackSettings = { PlaybackSettingsStore().load() },
        migratePreferences: @escaping @MainActor (Account, Account) -> Void = { AccountPreferenceMigrator.migrate(from: $0, to: $1) }
    ) {
        self.makeClient = makeClient
        self.currentSettings = currentSettings
        self.migratePreferences = migratePreferences
    }

    var canSubmit: Bool {
        phase != .validating && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parse the pasted M3U URL, check the credentials against the panel
    /// (`player_api.php`, no action), and persist on success.
    ///
    /// Latest request wins: a previous in-flight validation is cancelled, and a
    /// completion that is no longer current cannot touch `phase` or save an
    /// account.
    func validateAndSave(into appModel: AppModel) async {
        let submitted = urlText
        validationTask?.cancel()
        pendingInsecureSubmission = nil
        phase = .validating

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performValidation(of: submitted, into: appModel, insecureTransportConfirmed: false)
        }
        validationTask = task
        await task.value
    }

    /// The user deliberately accepted plain HTTP for the URL that raised the
    /// warning. Re-runs validation over http; a stale confirmation (text edited,
    /// nothing pending) is a no-op.
    func confirmInsecureTransport(into appModel: AppModel) async {
        guard let submitted = pendingInsecureSubmission, submitted == urlText else { return }
        pendingInsecureSubmission = nil
        validationTask?.cancel()
        phase = .validating

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performValidation(of: submitted, into: appModel, insecureTransportConfirmed: true)
        }
        validationTask = task
        await task.value
    }

    /// The user declined to send credentials over plain HTTP. Nothing was sent;
    /// the pasted text stays for editing.
    func cancelInsecureTransport() {
        pendingInsecureSubmission = nil
        if phase == .confirmingInsecureTransport {
            phase = .idle
        }
    }

    /// The confirmation UI went away without an explicit choice (Esc, tap
    /// outside). Leaves the pending submission so an in-flight Continue action
    /// scheduled just before the dismissal can still consume it.
    func insecureConfirmationDismissed() {
        if phase == .confirmingInsecureTransport {
            phase = .idle
        }
    }

    /// Stops an in-flight validation. Its completion can no longer mutate the
    /// phase or save an account.
    func cancelValidation() {
        validationTask?.cancel()
        validationTask = nil
        pendingInsecureSubmission = nil
        if phase == .validating || phase == .confirmingInsecureTransport {
            phase = .idle
        }
    }

    /// Shows or hides the pasted URL. Reset by ``clearCredentialInput()``.
    func toggleURLReveal() {
        isRevealingURL.toggle()
    }

    /// The form went away — sheet dismissed, tab left, or the app backgrounded
    /// (which can snapshot the window). Stop validating and drop the pasted URL
    /// rather than leave a password sitting in the field.
    func formDismissed() {
        cancelValidation()
        clearCredentialInput()
    }

    func removeAccount(from appModel: AppModel) {
        cancelValidation()
        // Cleared before the attempt, not after: a failed removal is no reason to
        // leave a pasted password on screen.
        clearCredentialInput()
        do {
            try appModel.removeAccount()
            phase = .idle
        } catch {
            phase = .failure(errorMessage(for: error))
        }
    }

    private func performValidation(of submitted: String, into appModel: AppModel, insecureTransportConfirmed: Bool) async {
        do {
            let account = try M3UURLParser.parse(submitted)
            let timeout = currentSettings().apiTimeoutSeconds

            var resolved = account
            var status: AccountStatus?

            if !account.usesSecureTransport, !insecureTransportConfirmed {
                // Probing the TLS twin first sends the credentials over HTTPS
                // only, so it needs no consent — and a verified upgrade means
                // the warning never has to appear at all.
                if let secured = Self.httpsVariant(of: account) {
                    let probe = makeClient(secured, min(timeout, Self.httpsProbeTimeout))
                    let outcome: Result<AccountStatus, Error>
                    do {
                        outcome = .success(try await probe.accountStatus())
                    } catch {
                        outcome = .failure(error)
                    }
                    guard isStillCurrent(submitted) else { return }

                    switch outcome {
                    case .success(let probed) where probed.authenticated:
                        resolved = secured
                        status = probed
                    case .success(let probed):
                        // The panel answered authoritatively over TLS and
                        // refused these credentials — plaintext would change
                        // nothing except exposing them.
                        phase = .failure(Self.rejectionMessage(for: probed))
                        return
                    case .failure(XtreamAPIError.httpStatus(let code)) where code == 401 || code == 403:
                        // Same authority, HTTP-level: an explicit credential
                        // rejection over TLS must never turn into an offer to
                        // retry in the clear.
                        phase = .failure("The panel rejected these credentials (HTTP \(code)).")
                        return
                    case .failure(is CancellationError):
                        return
                    case .failure:
                        // Transport-level failure — no TLS endpoint answered;
                        // fall through to the confirmation below.
                        break
                    }
                }
                guard isStillCurrent(submitted) else { return }
                if status == nil {
                    // No TLS endpoint answered. Sending credentials over plain
                    // HTTP needs a deliberate go-ahead first.
                    pendingInsecureSubmission = submitted
                    phase = .confirmingInsecureTransport
                    return
                }
            }

            let finalStatus: AccountStatus
            if let status {
                finalStatus = status
            } else {
                finalStatus = try await makeClient(resolved, timeout).accountStatus()
            }
            guard isStillCurrent(submitted) else { return }

            guard finalStatus.authenticated else {
                phase = .failure(Self.rejectionMessage(for: finalStatus))
                return
            }
            if insecureTransportConfirmed, !resolved.usesSecureTransport,
               let secured = Self.advertisedHTTPSUpgrade(of: resolved, from: finalStatus) {
                // The authenticated HTTP response says where the panel's TLS
                // endpoint really lives — usually a different port, which is
                // why the same-port probe missed it. Verified before switching;
                // any failure keeps the http account the user just confirmed,
                // so the upgrade attempt can never block the save.
                let probed = try? await makeClient(secured, min(timeout, Self.httpsProbeTimeout)).accountStatus()
                guard isStillCurrent(submitted) else { return }
                if let probed, probed.authenticated {
                    resolved = secured
                }
            }
            if resolved.host != account.host, let previous = appModel.account,
               previous.username == resolved.username, previous.host == account.host {
                // The verified upgrade changes the preference namespace (it
                // embeds the scheme) — carry favorites and last channel across.
                migratePreferences(previous, resolved)
            }
            try appModel.saveAccount(resolved)
            // Phase first: it takes urlText out of the validating state, so
            // clearing the field below doesn't cancel this completion.
            phase = .success(expiryDate: finalStatus.expiryDate)
            clearCredentialInput()
        } catch is CancellationError {
            return
        } catch {
            guard isStillCurrent(submitted) else { return }
            phase = .failure(errorMessage(for: error))
        }
    }

    private static func rejectionMessage(for status: AccountStatus) -> String {
        let detail = status.status.map { " (status: \($0))" } ?? ""
        return "The panel rejected these credentials\(detail)."
    }

    /// The account rebased onto the panel's advertised TLS port. nil when the
    /// panel advertised nothing valid, or advertised the endpoint the same-port
    /// twin probe already tried before the user confirmed plain HTTP.
    private static func advertisedHTTPSUpgrade(of account: Account, from status: AccountStatus) -> Account? {
        guard let advertised = status.advertisedHTTPSPort else { return nil }
        guard advertised != (account.host.port ?? 443) else { return nil }
        guard var components = URLComponents(url: account.host, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "https"
        components.port = advertised
        guard let host = components.url else { return nil }
        return Account(host: host, username: account.username, password: account.password)
    }

    /// The same account with the host scheme swapped to https (port kept).
    private static func httpsVariant(of account: Account) -> Account? {
        guard var components = URLComponents(url: account.host, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "https"
        guard let host = components.url else { return nil }
        return Account(host: host, username: account.username, password: account.password)
    }

    /// Drops the credential-bearing text **and** re-hides it. Both belong together:
    /// leaving the reveal on would show the next URL the user types in the clear.
    private func clearCredentialInput() {
        urlText = ""
        isRevealingURL = false
    }

    /// A completion may only report back if it wasn't cancelled and the text it
    /// validated is still the text on screen.
    private func isStillCurrent(_ submitted: String) -> Bool {
        !Task.isCancelled && submitted == urlText
    }

    /// Panel and parse errors describe the failure without echoing the URL, so
    /// no credential reaches the UI or a log through here.
    private func errorMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
