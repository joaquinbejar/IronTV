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

    @Published var urlText = ""
    @Published private(set) var phase: Phase = .idle

    var canSubmit: Bool {
        phase != .validating && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parse the pasted M3U URL, check the credentials against the panel
    /// (`player_api.php`, no action), and persist on success.
    func validateAndSave(into appModel: AppModel) async {
        phase = .validating
        do {
            let account = try M3UURLParser.parse(urlText)
            let status = try await XtreamClient(account: account).accountStatus()
            guard status.authenticated else {
                let detail = status.status.map { " (status: \($0))" } ?? ""
                phase = .failure("The panel rejected these credentials\(detail).")
                return
            }
            try appModel.saveAccount(account)
            phase = .success(expiryDate: status.expiryDate)
        } catch {
            phase = .failure(errorMessage(for: error))
        }
    }

    func removeAccount(from appModel: AppModel) {
        do {
            try appModel.removeAccount()
            phase = .idle
        } catch {
            phase = .failure(errorMessage(for: error))
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
