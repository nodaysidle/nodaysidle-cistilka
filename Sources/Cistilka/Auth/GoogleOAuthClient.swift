import AppKit
import AuthenticationServices
import Foundation

/// Google OAuth 2.0 authorization-code + PKCE client (public native app).
///
/// Scopes request full Drive access so Cistilka can list My Drive and move items to Trash.
/// Documented to the user at connect time: list + trash; refresh via offline access token.
@MainActor
final class GoogleOAuthClient: NSObject {
    enum GoogleOAuthError: Error, LocalizedError, Sendable {
        case notConfigured
        case missingClientID
        case missingRedirectURI
        case invalidRedirectURI
        case userCancelled
        case noCallbackURL
        case missingAuthorizationCode
        case tokenExchangeFailed(String)
        case userInfoFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured, .missingClientID, .missingRedirectURI:
                return "Google Drive is not configured. Copy Config/OAuth.example.plist to Config/OAuth.plist and set GoogleClientID / GoogleRedirectURI."
            case .invalidRedirectURI:
                return "GoogleRedirectURI is invalid."
            case .userCancelled:
                return "Google sign-in was cancelled."
            case .noCallbackURL:
                return "Google sign-in did not return a callback URL."
            case .missingAuthorizationCode:
                return "Google sign-in response was missing an authorization code."
            case .tokenExchangeFailed(let message):
                return "Google token exchange failed: \(message)"
            case .userInfoFailed(let message):
                return "Could not load Google account email: \(message)"
            }
        }
    }

    /// Drive list + trash (full file metadata). Prefer documenting this at sign-in.
    static let driveScope = "https://www.googleapis.com/auth/drive"
    static let emailScope = "email"
    static let openIDScope = "openid"

    static var defaultScopes: [String] {
        [driveScope, emailScope, openIDScope]
    }

    private let config: OAuthConfig
    private let session: URLSession

    init(config: OAuthConfig = .load(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var isConfigured: Bool {
        config.isGoogleConfigured
    }

    /// Interactive sign-in via `ASWebAuthenticationSession` + PKCE.
    func signIn(scopes: [String] = GoogleOAuthClient.defaultScopes) async throws -> OAuthTokens {
        guard let clientID = config.googleClientID, !clientID.isEmpty else {
            throw GoogleOAuthError.missingClientID
        }
        guard let redirectURI = config.googleRedirectURI, !redirectURI.isEmpty else {
            throw GoogleOAuthError.missingRedirectURI
        }
        guard let callbackScheme = Self.callbackScheme(from: redirectURI) else {
            throw GoogleOAuthError.invalidRedirectURI
        }

        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.makeVerifier(length: 32)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = components.url else {
            throw GoogleOAuthError.invalidRedirectURI
        }

        let callbackURL = try await startWebAuth(url: authURL, callbackScheme: callbackScheme)
        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)

        var tokens = try await exchangeCode(
            code: code,
            verifier: verifier,
            clientID: clientID,
            redirectURI: redirectURI
        )
        if tokens.accountEmail == nil {
            tokens.accountEmail = try? await fetchUserEmail(accessToken: tokens.accessToken)
        }
        return tokens
    }

    /// Refresh an access token using a stored refresh token (no UI).
    nonisolated static func refresh(
        refreshToken: String,
        clientID: String,
        session: URLSession = .shared
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = formBody([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        try throwIfHTTPError(data: data, response: response, context: "refresh")
        return try decodeTokenResponse(data: data, provider: .google, fallbackRefresh: refreshToken)
    }

    /// Convenience refresh using the configured client ID.
    func refresh(refreshToken: String) async throws -> OAuthTokens {
        guard let clientID = config.googleClientID, !clientID.isEmpty else {
            throw GoogleOAuthError.missingClientID
        }
        return try await Self.refresh(
            refreshToken: refreshToken,
            clientID: clientID,
            session: session
        )
    }

    func fetchUserEmail(accessToken: String) async throws -> String {
        try await Self.fetchUserEmail(accessToken: accessToken, session: session)
    }

    nonisolated static func fetchUserEmail(
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw GoogleOAuthError.userInfoFailed(message)
        }
        struct UserInfo: Decodable {
            var email: String?
        }
        let info = try JSONDecoder().decode(UserInfo.self, from: data)
        guard let email = info.email, !email.isEmpty else {
            throw GoogleOAuthError.userInfoFailed("email missing")
        }
        return email
    }

    // MARK: - Web auth session

    private func startWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await WebAuthSession.start(url: url, callbackScheme: callbackScheme)
        } catch WebAuthSession.WebAuthError.cancelled {
            throw GoogleOAuthError.userCancelled
        } catch WebAuthSession.WebAuthError.noCallbackURL, WebAuthSession.WebAuthError.couldNotStart {
            throw GoogleOAuthError.noCallbackURL
        }
    }

    // MARK: - Token exchange

    private func exchangeCode(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Self.formBody([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(data: data, response: response, context: "token")
        return try Self.decodeTokenResponse(data: data, provider: .google, fallbackRefresh: nil)
    }

    // MARK: - Parsing helpers (testable)

    nonisolated static func callbackScheme(from redirectURI: String) -> String? {
        // Supports custom schemes like `com.nodaysidle.cistilka:/oauth2redirect/google`
        // and `com.nodaysidle.cistilka://oauth2redirect/google`.
        if let url = URL(string: redirectURI), let scheme = url.scheme, !scheme.isEmpty {
            return scheme
        }
        if let colon = redirectURI.firstIndex(of: ":") {
            let scheme = String(redirectURI[..<colon])
            return scheme.isEmpty ? nil : scheme
        }
        return nil
    }

    nonisolated static func authorizationCode(from callbackURL: URL, expectedState: String?) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        let items = components.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            throw GoogleOAuthError.tokenExchangeFailed(err)
        }
        if let expectedState {
            let state = items.first(where: { $0.name == "state" })?.value
            if state != expectedState {
                throw GoogleOAuthError.tokenExchangeFailed("state mismatch")
            }
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        return code
    }

    nonisolated static func decodeTokenResponse(
        data: Data,
        provider: AuthProvider,
        fallbackRefresh: String?
    ) throws -> OAuthTokens {
        struct TokenJSON: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Int?
            var token_type: String?
            var scope: String?
            var id_token: String?
        }
        let json = try JSONDecoder().decode(TokenJSON.self, from: data)
        let expiresAt: Date?
        if let seconds = json.expires_in {
            expiresAt = Date().addingTimeInterval(TimeInterval(seconds))
        } else {
            expiresAt = nil
        }
        var email: String?
        if let idToken = json.id_token {
            email = Self.emailFromIDToken(idToken)
        }
        return OAuthTokens(
            accessToken: json.access_token,
            refreshToken: json.refresh_token ?? fallbackRefresh,
            expiresAt: expiresAt,
            tokenType: json.token_type,
            scope: json.scope,
            accountEmail: email,
            provider: provider
        )
    }

    /// Best-effort email claim from an ID token payload (no signature verification).
    nonisolated static func emailFromIDToken(_ idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = obj["email"] as? String,
              !email.isEmpty
        else {
            return nil
        }
        return email
    }

    nonisolated private static func formBody(_ fields: [String: String]) -> String {
        fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    nonisolated private static func throwIfHTTPError(data: Data, response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GoogleOAuthError.tokenExchangeFailed("\(context): \(message)")
        }
    }
}

// MARK: - Config helpers

extension OAuthConfig {
    var isGoogleConfigured: Bool {
        if let id = googleClientID, !id.isEmpty,
           let redirect = googleRedirectURI, !redirect.isEmpty
        {
            return true
        }
        return false
    }

    var isMicrosoftConfigured: Bool {
        if let id = microsoftClientID, !id.isEmpty,
           let redirect = microsoftRedirectURI, !redirect.isEmpty
        {
            return true
        }
        return false
    }
}
