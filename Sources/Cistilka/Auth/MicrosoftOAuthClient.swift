import AppKit
import AuthenticationServices
import Foundation

/// Microsoft identity platform authorization-code + PKCE client (public native app).
///
/// Scopes: `offline_access User.Read Files.ReadWrite` — list OneDrive, trash to recycle bin,
/// and refresh without re-prompting. Documented to the user at connect time.
@MainActor
final class MicrosoftOAuthClient: NSObject {
    enum MicrosoftOAuthError: Error, LocalizedError, Sendable {
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
                return "OneDrive is not configured. Copy Config/OAuth.example.plist to Config/OAuth.plist and set MicrosoftClientID / MicrosoftRedirectURI."
            case .invalidRedirectURI:
                return "MicrosoftRedirectURI is invalid."
            case .userCancelled:
                return "Microsoft sign-in was cancelled."
            case .noCallbackURL:
                return "Microsoft sign-in did not return a callback URL."
            case .missingAuthorizationCode:
                return "Microsoft sign-in response was missing an authorization code."
            case .tokenExchangeFailed(let message):
                return "Microsoft token exchange failed: \(message)"
            case .userInfoFailed(let message):
                return "Could not load Microsoft account identity: \(message)"
            }
        }
    }

    /// Graph scopes: list + trash (Files.ReadWrite), profile email (User.Read), refresh (offline_access).
    nonisolated static let filesScope = "Files.ReadWrite"
    nonisolated static let userReadScope = "User.Read"
    nonisolated static let offlineAccessScope = "offline_access"

    nonisolated static var defaultScopes: [String] {
        [offlineAccessScope, userReadScope, filesScope]
    }

    private let config: OAuthConfig
    private let session: URLSession

    init(config: OAuthConfig = .load(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var isConfigured: Bool {
        config.isMicrosoftConfigured
    }

    /// Interactive sign-in via `ASWebAuthenticationSession` + PKCE.
    func signIn(scopes: [String] = MicrosoftOAuthClient.defaultScopes) async throws -> OAuthTokens {
        guard let clientID = config.microsoftClientID, !clientID.isEmpty else {
            throw MicrosoftOAuthError.missingClientID
        }
        guard let redirectURI = config.microsoftRedirectURI, !redirectURI.isEmpty else {
            throw MicrosoftOAuthError.missingRedirectURI
        }
        guard let callbackScheme = Self.callbackScheme(from: redirectURI) else {
            throw MicrosoftOAuthError.invalidRedirectURI
        }

        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.makeVerifier(length: 32)
        let scopeString = scopes.joined(separator: " ")

        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopeString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else {
            throw MicrosoftOAuthError.invalidRedirectURI
        }

        let callbackURL = try await startWebAuth(url: authURL, callbackScheme: callbackScheme)
        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)

        var tokens = try await exchangeCode(
            code: code,
            verifier: verifier,
            clientID: clientID,
            redirectURI: redirectURI,
            scope: scopeString
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
        scopes: [String]? = nil,
        session: URLSession = .shared
    ) async throws -> OAuthTokens {
        let scopeString = (scopes ?? defaultScopes).joined(separator: " ")
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = formBody([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": scopeString,
        ])
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        try throwIfHTTPError(data: data, response: response, context: "refresh")
        return try decodeTokenResponse(data: data, provider: .microsoft, fallbackRefresh: refreshToken)
    }

    /// Convenience refresh using the configured client ID.
    func refresh(refreshToken: String) async throws -> OAuthTokens {
        guard let clientID = config.microsoftClientID, !clientID.isEmpty else {
            throw MicrosoftOAuthError.missingClientID
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
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw MicrosoftOAuthError.userInfoFailed(message)
        }
        struct GraphMe: Decodable {
            var mail: String?
            var userPrincipalName: String?
            var displayName: String?
        }
        let info = try JSONDecoder().decode(GraphMe.self, from: data)
        if let mail = info.mail, !mail.isEmpty {
            return mail
        }
        if let upn = info.userPrincipalName, !upn.isEmpty {
            return upn
        }
        throw MicrosoftOAuthError.userInfoFailed("mail / userPrincipalName missing")
    }

    // MARK: - Web auth session

    private func startWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        do {
            return try await WebAuthSession.start(url: url, callbackScheme: callbackScheme)
        } catch WebAuthSession.WebAuthError.cancelled {
            throw MicrosoftOAuthError.userCancelled
        } catch WebAuthSession.WebAuthError.noCallbackURL, WebAuthSession.WebAuthError.couldNotStart {
            throw MicrosoftOAuthError.noCallbackURL
        }
    }

    // MARK: - Token exchange

    private func exchangeCode(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String,
        scope: String
    ) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Self.formBody([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "scope": scope,
        ])
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(data: data, response: response, context: "token")
        return try Self.decodeTokenResponse(data: data, provider: .microsoft, fallbackRefresh: nil)
    }

    // MARK: - Parsing helpers (testable)

    nonisolated static func callbackScheme(from redirectURI: String) -> String? {
        // Supports `msauth.com.nodaysidle.cistilka://auth` and
        // `com.nodaysidle.cistilka:/oauth2redirect/microsoft`.
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
            throw MicrosoftOAuthError.missingAuthorizationCode
        }
        let items = components.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value
            throw MicrosoftOAuthError.tokenExchangeFailed(desc ?? err)
        }
        if let expectedState {
            let state = items.first(where: { $0.name == "state" })?.value
            if state != expectedState {
                throw MicrosoftOAuthError.tokenExchangeFailed("state mismatch")
            }
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MicrosoftOAuthError.missingAuthorizationCode
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

    /// Best-effort email / preferred_username claim from an ID token payload (no signature verification).
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let email = obj["email"] as? String, !email.isEmpty {
            return email
        }
        if let preferred = obj["preferred_username"] as? String, !preferred.isEmpty {
            return preferred
        }
        if let upn = obj["upn"] as? String, !upn.isEmpty {
            return upn
        }
        return nil
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
            throw MicrosoftOAuthError.tokenExchangeFailed("\(context): \(message)")
        }
    }
}
