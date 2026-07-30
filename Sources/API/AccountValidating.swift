import Foundation

/// The single call account validation needs from the panel.
///
/// Exists as a seam: it lets Settings drive validation — success, rejection,
/// timeout, cancellation — without a network, which is what keeps the
/// credential-handling paths testable offline.
public protocol AccountValidating: Sendable {
    func accountStatus() async throws -> AccountStatus
}

extension XtreamClient: AccountValidating {}
