import Foundation

/// Multi-account OAuth token storage in Keychain (shared Google / Microsoft).
actor AuthStore {
    enum AuthStoreError: Error, LocalizedError, Sendable {
        case noTokens(accountId: String, provider: AuthProvider)
        case refreshUnavailable(accountId: String)
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTokens(let id, let provider):
                return "No \(provider.rawValue) tokens for \(id)."
            case .refreshUnavailable(let id):
                return "No refresh token for \(id); sign in again."
            case .refreshFailed(let message):
                return "Token refresh failed: \(message)"
            }
        }
    }

    private let keychain: KeychainStore
    private let servicePrefix: String

    /// Optional hook so Google/Microsoft clients can refresh without circular imports at call sites.
    private var googleRefresher: (@Sendable (String) async throws -> OAuthTokens)?
    private var microsoftRefresher: (@Sendable (String) async throws -> OAuthTokens)?

    init(
        keychain: KeychainStore = KeychainStore(),
        servicePrefix: String = "com.nodaysidle.cistilka.oauth"
    ) {
        self.keychain = keychain
        self.servicePrefix = servicePrefix
    }

    func setGoogleRefresher(_ refresher: @escaping @Sendable (String) async throws -> OAuthTokens) {
        googleRefresher = refresher
    }

    func setMicrosoftRefresher(_ refresher: @escaping @Sendable (String) async throws -> OAuthTokens) {
        microsoftRefresher = refresher
    }

    // MARK: - CRUD

    func save(tokens: OAuthTokens, accountId: String) async throws {
        let key = accountKey(provider: tokens.provider, accountId: accountId)
        var stored = tokens
        if stored.accountEmail == nil {
            stored.accountEmail = accountId
        }
        let data = try JSONEncoder().encode(stored)
        try await keychain.set(data, account: key, service: servicePrefix)
        try await addToIndex(provider: tokens.provider, accountId: accountId)
    }

    func load(accountId: String, provider: AuthProvider) async throws -> OAuthTokens? {
        let key = accountKey(provider: provider, accountId: accountId)
        guard let data = try await keychain.get(account: key, service: servicePrefix) else {
            return nil
        }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func delete(accountId: String, provider: AuthProvider) async throws {
        let key = accountKey(provider: provider, accountId: accountId)
        try await keychain.delete(account: key, service: servicePrefix)
        try await removeFromIndex(provider: provider, accountId: accountId)
    }

    /// Account emails / ids stored for `provider`.
    func listAccounts(provider: AuthProvider) async throws -> [String] {
        try await loadIndex(provider: provider)
    }

    // MARK: - Access token

    /// Returns a usable access token, refreshing via provider-specific hook when expired.
    /// - Parameter forceRefresh: When true (e.g. after HTTP 401), always refresh even if not yet expired.
    func validAccessToken(
        accountId: String,
        provider: AuthProvider,
        forceRefresh: Bool = false
    ) async throws -> String {
        guard let tokens = try await load(accountId: accountId, provider: provider) else {
            throw AuthStoreError.noTokens(accountId: accountId, provider: provider)
        }

        if !forceRefresh, !tokens.isAccessTokenExpired() {
            return tokens.accessToken
        }

        guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
            throw AuthStoreError.refreshUnavailable(accountId: accountId)
        }

        switch provider {
        case .google:
            guard let refresher = googleRefresher else {
                throw AuthStoreError.refreshUnavailable(accountId: accountId)
            }
            do {
                var fresh = try await refresher(refresh)
                // Preserve refresh token if Google omits it on refresh.
                if fresh.refreshToken == nil {
                    fresh.refreshToken = refresh
                }
                fresh.accountEmail = tokens.accountEmail ?? accountId
                fresh.provider = .google
                try await save(tokens: fresh, accountId: accountId)
                return fresh.accessToken
            } catch {
                throw AuthStoreError.refreshFailed(error.localizedDescription)
            }
        case .microsoft:
            guard let refresher = microsoftRefresher else {
                throw AuthStoreError.refreshUnavailable(accountId: accountId)
            }
            do {
                var fresh = try await refresher(refresh)
                // Preserve refresh token if Microsoft omits it on refresh.
                if fresh.refreshToken == nil {
                    fresh.refreshToken = refresh
                }
                fresh.accountEmail = tokens.accountEmail ?? accountId
                fresh.provider = .microsoft
                try await save(tokens: fresh, accountId: accountId)
                return fresh.accessToken
            } catch {
                throw AuthStoreError.refreshFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Index helpers

    private func accountKey(provider: AuthProvider, accountId: String) -> String {
        "\(provider.rawValue):\(accountId)"
    }

    private func indexKey(provider: AuthProvider) -> String {
        "\(provider.rawValue):__accounts__"
    }

    private func loadIndex(provider: AuthProvider) async throws -> [String] {
        guard let data = try await keychain.get(account: indexKey(provider: provider), service: servicePrefix)
        else {
            return []
        }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveIndex(_ accounts: [String], provider: AuthProvider) async throws {
        let data = try JSONEncoder().encode(accounts)
        try await keychain.set(data, account: indexKey(provider: provider), service: servicePrefix)
    }

    private func addToIndex(provider: AuthProvider, accountId: String) async throws {
        var accounts = try await loadIndex(provider: provider)
        if !accounts.contains(accountId) {
            accounts.append(accountId)
            accounts.sort()
            try await saveIndex(accounts, provider: provider)
        }
    }

    private func removeFromIndex(provider: AuthProvider, accountId: String) async throws {
        var accounts = try await loadIndex(provider: provider)
        accounts.removeAll { $0 == accountId }
        try await saveIndex(accounts, provider: provider)
    }
}
