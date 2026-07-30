import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case validating
        case success(expiryDate: Date?)
        case failure(String)
    }

    /// The pasted playlist URL. It carries the account password, so it is
    /// cleared as soon as it is no longer needed — see ``formDismissed()``.
    @Published var urlText = "" {
        didSet {
            // The in-flight request was for text the user has since changed;
            // letting it finish could save an account that doesn't match what
            // is on screen. Only fires while validating, so the programmatic
            // clear on success doesn't cancel its own completion.
            guard urlText != oldValue, phase == .validating else { return }
            cancelValidation()
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
    private var validationTask: Task<Void, Never>?

    init(
        makeClient: @escaping ClientFactory = { XtreamClient(account: $0, requestTimeout: $1) },
        currentSettings: @escaping @MainActor () -> PlaybackSettings = { PlaybackSettingsStore().load() }
    ) {
        self.makeClient = makeClient
        self.currentSettings = currentSettings
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
        phase = .validating

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performValidation(of: submitted, into: appModel)
        }
        validationTask = task
        await task.value
    }

    /// Stops an in-flight validation. Its completion can no longer mutate the
    /// phase or save an account.
    func cancelValidation() {
        validationTask?.cancel()
        validationTask = nil
        if phase == .validating {
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

    private func performValidation(of submitted: String, into appModel: AppModel) async {
        do {
            let account = try M3UURLParser.parse(submitted)
            let client = makeClient(account, currentSettings().apiTimeoutSeconds)
            let status = try await client.accountStatus()
            guard isStillCurrent(submitted) else { return }

            guard status.authenticated else {
                let detail = status.status.map { " (status: \($0))" } ?? ""
                phase = .failure("The panel rejected these credentials\(detail).")
                return
            }
            try appModel.saveAccount(account)
            // Phase first: it takes urlText out of the validating state, so
            // clearing the field below doesn't cancel this completion.
            phase = .success(expiryDate: status.expiryDate)
            clearCredentialInput()
        } catch is CancellationError {
            return
        } catch {
            guard isStillCurrent(submitted) else { return }
            phase = .failure(errorMessage(for: error))
        }
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
