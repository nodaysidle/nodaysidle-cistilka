import Foundation

/// Cloud OAuth provider identity.
enum AuthProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case google
    case microsoft
}

/// Tokens returned from an OAuth authorization or refresh exchange.
struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Absolute expiry time of `accessToken` when known.
    var expiresAt: Date?
    var tokenType: String?
    var scope: String?
    /// Account email / UPN when resolved (Keychain account key).
    var accountEmail: String?
    var provider: AuthProvider

    /// True when access token is missing or within the refresh skew window.
    func isAccessTokenExpired(skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= skew
    }
}
