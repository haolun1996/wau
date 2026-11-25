import CryptoKit
import Foundation

public enum SyncError: Error, LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case signInFailed(String)
    case server(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Google sign-in isn't set up in this build (no client ID)."
        case .notSignedIn: "Not signed in to Google."
        case .signInFailed(let reason): "Google sign-in failed: \(reason)"
        case .server(let status, let message): "Google Drive returned \(status): \(message)"
        case .invalidResponse: "Google returned a response Wau couldn't read."
        }
    }
}

/// Proof Key for Code Exchange (RFC 7636): proves the app that started
/// sign-in is the one finishing it, without a client secret.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.init(verifier: Data(bytes).base64URLEncoded)
    }

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

/// The app's Google OAuth client. Use an "iOS" client ID from Google Cloud
/// Console: it allows the reversed-client-ID redirect a Mac app can receive.
public struct GoogleOAuthConfig: Sendable, Equatable {
    public static let scopes = ["openid", "email", "https://www.googleapis.com/auth/drive.appdata"]

    public let clientID: String

    public init?(clientID: String?) {
        guard let clientID = clientID?.trimmingCharacters(in: .whitespaces),
              clientID.hasSuffix(".apps.googleusercontent.com")
        else { return nil }
        self.clientID = clientID
    }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    public var redirectScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    public var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
}

/// Access and refresh tokens from Google.
public struct GoogleTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }
}

/// Building and reading the requests of Google's OAuth flow for installed apps.
public enum GoogleOAuth {
    static let authorizeEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public static func authorizationURL(config: GoogleOAuthConfig, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization code from the redirect Google sent back.
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw SyncError.signInFailed(error) }
        guard value("state") == expectedState else { throw SyncError.signInFailed("the response didn't match the request") }
        guard let code = value("code"), !code.isEmpty else { throw SyncError.signInFailed("no authorization code") }
        return code
    }

    public static func tokenRequest(code: String, pkce: PKCE, config: GoogleOAuthConfig) -> URLRequest {
        formRequest([
            "client_id": config.clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ])
    }

    public static func refreshRequest(refreshToken: String, config: GoogleOAuthConfig) -> URLRequest {
        formRequest([
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    /// Reads a token response. Refresh responses usually omit the refresh
    /// token and ID token, so the previous ones carry over.
    public static func tokens(from data: Data, previous: GoogleTokens? = nil, now: Date = Date()) throws -> GoogleTokens {
        struct Response: Decodable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
            let id_token: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw SyncError.invalidResponse }
        return GoogleTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? previous?.refreshToken,
            // Refresh a minute early rather than racing the expiry.
            expiresAt: now.addingTimeInterval(response.expires_in - 60),
            email: response.id_token.flatMap(email(fromIDToken:)) ?? previous?.email
        )
    }

    /// The account's email from an OpenID ID token. Only for display: the
    /// token comes straight from Google over TLS, so it isn't re-verified.
    public static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }

    private static func formRequest(_ parameters: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
