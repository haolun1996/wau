import Foundation

/// Sends HTTP requests; URLSession in the app, a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        return (data, http)
    }
}

/// A signed-in Google account: hands out access tokens, refreshing them when
/// they expire and reporting new tokens so they can be stored.
public actor GoogleSession {
    public let config: GoogleOAuthConfig
    private var tokens: GoogleTokens
    private let transport: any HTTPTransport
    private let onTokensChanged: @Sendable (GoogleTokens) -> Void
    private let now: @Sendable () -> Date

    public init(
        config: GoogleOAuthConfig,
        tokens: GoogleTokens,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init,
        onTokensChanged: @escaping @Sendable (GoogleTokens) -> Void
    ) {
        self.config = config
        self.tokens = tokens
        self.transport = transport
        self.now = now
        self.onTokensChanged = onTokensChanged
    }

    public var email: String? { tokens.email }

    public func accessToken() async throws -> String {
        if tokens.expiresAt > now() { return tokens.accessToken }
        try await refresh()
        return tokens.accessToken
    }

    /// Gets a new access token with the refresh token (e.g. after a 401).
    public func refresh() async throws {
        guard let refreshToken = tokens.refreshToken else { throw SyncError.notSignedIn }
        let (data, response) = try await transport.send(GoogleOAuth.refreshRequest(refreshToken: refreshToken, config: config))
        guard response.statusCode == 200 else {
            // 400 invalid_grant: access was revoked or the refresh token expired.
            throw response.statusCode == 400 ? SyncError.notSignedIn : SyncError.server(status: response.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        tokens = try GoogleOAuth.tokens(from: data, previous: tokens, now: now())
        onTokensChanged(tokens)
    }
}

/// Reads and writes whole files somewhere remote, by name.
public protocol RemoteStore: Sendable {
    func read(_ name: String) async throws -> Data?
    func write(_ name: String, _ data: Data) async throws
}

/// Files in the app's private Google Drive folder ("appDataFolder"): hidden
/// from the user's Drive and from every other app.
public actor GoogleDriveStore: RemoteStore {
    static let api = URL(string: "https://www.googleapis.com/drive/v3/files")!
    static let upload = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!

    private let session: GoogleSession
    private let transport: any HTTPTransport
    private var fileIDs: [String: String] = [:]

    public init(session: GoogleSession, transport: any HTTPTransport) {
        self.session = session
        self.transport = transport
    }

    public func read(_ name: String) async throws -> Data? {
        guard let id = try await fileID(named: name) else { return nil }
        let request = URLRequest(url: URL(string: Self.api.appendingPathComponent(id).absoluteString + "?alt=media")!)
        return try await send(request)
    }

    public func write(_ name: String, _ data: Data) async throws {
        if let id = try await fileID(named: name) {
            var request = URLRequest(url: URL(string: Self.upload.appendingPathComponent(id).absoluteString + "?uploadType=media")!)
            request.httpMethod = "PATCH"
            request.setValue(Self.contentType(for: name), forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            _ = try await send(request)
        } else {
            let request = Self.createRequest(name: name, data: data)
            let response = try await send(request)
            struct Created: Decodable { let id: String }
            guard let created = try? JSONDecoder().decode(Created.self, from: response) else { throw SyncError.invalidResponse }
            fileIDs[name] = created.id
        }
    }

    private func fileID(named name: String) async throws -> String? {
        if let id = fileIDs[name] { return id }
        var components = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(name.replacingOccurrences(of: "'", with: "\\'"))'"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        let data = try await send(URLRequest(url: components.url!))
        struct Listing: Decodable { struct File: Decodable { let id: String }; let files: [File] }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { throw SyncError.invalidResponse }
        let id = listing.files.first?.id
        fileIDs[name] = id
        return id
    }

    /// Sends with the current access token, refreshing and retrying once on 401.
    private func send(_ request: URLRequest, retried: Bool = false) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401, !retried {
            try await session.refresh()
            return try await send(request, retried: true)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SyncError.server(status: response.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    /// A multipart upload creating `name` inside the app data folder.
    static func createRequest(name: String, data: Data, boundary: String = "wau-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: URL(string: upload.absoluteString + "?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = try! JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]], options: .sortedKeys)
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(contentType(for: name))\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func contentType(for name: String) -> String {
        name.hasSuffix(".json") ? "application/json" : name.hasSuffix(".png") ? "image/png" : "application/octet-stream"
    }
}
