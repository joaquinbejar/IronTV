import Foundation
import os

/// Async client for the Xtream Codes JSON API of a single account.
public struct XtreamClient: Sendable {
    public let account: Account
    private let session: URLSession
    private let requestTimeout: TimeInterval

    private static let logger = Logger(subsystem: "com.quantkernel.irontv", category: "xtream")

    public init(account: Account, session: URLSession = .shared, requestTimeout: TimeInterval = 30) {
        self.account = account
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - Endpoints

    /// `player_api.php` with no action.
    public func accountStatus() async throws -> AccountStatus {
        let dto: AccountInfoDTO = try await fetch(playerAPIURL(action: nil))
        return dto.userInfo?.toDomain()
            ?? AccountStatus(authenticated: false, status: nil, expiryDate: nil, maxConnections: nil)
    }

    public func liveCategories() async throws -> [Category] {
        let dtos: [LiveCategoryDTO] = try await fetch(playerAPIURL(action: "get_live_categories"))
        return dtos.compactMap { $0.toDomain() }
    }

    /// All live streams, or only those in `categoryID` when given.
    public func liveStreams(in categoryID: CategoryID? = nil) async throws -> [LiveStream] {
        let dtos: [LiveStreamDTO] = try await fetch(playerAPIURL(action: "get_live_streams", categoryID: categoryID))
        return dtos.compactMap { $0.toDomain(fallbackCategoryID: categoryID) }
    }

    // MARK: - URL building

    /// HLS playback URL: `{host}/live/{username}/{password}/{stream_id}.m3u8`.
    /// Never log the result unredacted — see `CredentialRedactor`.
    public func playbackURL(for streamID: StreamID) throws -> URL {
        guard var components = URLComponents(url: account.host, resolvingAgainstBaseURL: false) else {
            throw XtreamAPIError.invalidURL
        }
        components.path = "/live/\(account.username)/\(account.password)/\(streamID.rawValue).m3u8"
        guard let url = components.url else {
            throw XtreamAPIError.invalidURL
        }
        return url
    }

    func playerAPIURL(action: String?, categoryID: CategoryID? = nil) throws -> URL {
        guard var components = URLComponents(url: account.host, resolvingAgainstBaseURL: false) else {
            throw XtreamAPIError.invalidURL
        }
        components.path = "/player_api.php"
        var query = [
            URLQueryItem(name: "username", value: account.username),
            URLQueryItem(name: "password", value: account.password),
        ]
        if let action {
            query.append(URLQueryItem(name: "action", value: action))
        }
        if let categoryID {
            query.append(URLQueryItem(name: "category_id", value: String(categoryID.rawValue)))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw XtreamAPIError.invalidURL
        }
        return url
    }

    // MARK: - Transport

    private func fetch<T: Decodable>(_ url: @autoclosure () throws -> URL) async throws -> T {
        let url = try url()
        Self.logger.debug("GET \(CredentialRedactor.redact(url), privacy: .public)")

        let request = URLRequest(url: url, timeoutInterval: requestTimeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw XtreamAPIError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw XtreamAPIError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw XtreamAPIError.decoding(error)
        }
    }
}
