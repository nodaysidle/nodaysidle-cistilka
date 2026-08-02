import Foundation

/// Persists SSH profiles (JSON) and secrets / host-key TOFU fingerprints (Keychain).
actor SSHCredentialStore {
    enum StoreError: Error, LocalizedError, Sendable {
        case missingSecrets(profileId: UUID)
        case encodingFailed
        case hostKeyChanged(host: String, port: Int)

        var errorDescription: String? {
            switch self {
            case .missingSecrets(let id):
                return "No SSH credentials stored for profile \(id.uuidString)."
            case .encodingFailed:
                return "Could not encode SSH credentials."
            case .hostKeyChanged(let host, let port):
                return "SSH host key for \(host):\(port) changed. Remove the stored key in Accounts to re-trust (TOFU)."
            }
        }
    }

    private let keychain: KeychainStore
    private let secretsService: String
    private let hostKeyService: String
    private let profilesURL: URL

    init(
        keychain: KeychainStore = KeychainStore(),
        directory: URL? = nil,
        secretsService: String = "com.nodaysidle.cistilka.ssh.secrets",
        hostKeyService: String = "com.nodaysidle.cistilka.ssh.hostkeys"
    ) {
        self.keychain = keychain
        self.secretsService = secretsService
        self.hostKeyService = hostKeyService
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
        }
        self.profilesURL = dir.appendingPathComponent("ssh-profiles.json", isDirectory: false)
    }

    // MARK: - Profiles

    func loadProfiles() throws -> [SSHProfile] {
        guard FileManager.default.fileExists(atPath: profilesURL.path) else {
            return []
        }
        let data = try Data(contentsOf: profilesURL)
        return try JSONDecoder().decode([SSHProfile].self, from: data)
    }

    func saveProfiles(_ profiles: [SSHProfile]) throws {
        let dir = profilesURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: profilesURL, options: .atomic)
    }

    func upsert(_ profile: SSHProfile) throws {
        var all = try loadProfiles()
        if let idx = all.firstIndex(where: { $0.id == profile.id }) {
            all[idx] = profile
        } else {
            all.append(profile)
        }
        try saveProfiles(all)
    }

    func deleteProfile(id: UUID) async throws {
        var all = try loadProfiles()
        all.removeAll { $0.id == id }
        try saveProfiles(all)
        try await keychain.delete(account: id.uuidString, service: secretsService)
    }

    func profile(id: UUID) throws -> SSHProfile? {
        try loadProfiles().first { $0.id == id }
    }

    // MARK: - Secrets

    func saveSecrets(_ secrets: SSHSecrets, profileId: UUID) async throws {
        let data = try JSONEncoder().encode(secrets)
        try await keychain.set(data, account: profileId.uuidString, service: secretsService)
    }

    func loadSecrets(profileId: UUID) async throws -> SSHSecrets? {
        guard let data = try await keychain.get(account: profileId.uuidString, service: secretsService) else {
            return nil
        }
        return try JSONDecoder().decode(SSHSecrets.self, from: data)
    }

    func requireSecrets(profileId: UUID) async throws -> SSHSecrets {
        guard let secrets = try await loadSecrets(profileId: profileId) else {
            throw StoreError.missingSecrets(profileId: profileId)
        }
        return secrets
    }

    // MARK: - Host key TOFU (fingerprint strings)

    func hostKeyFingerprint(host: String, port: Int) async throws -> String? {
        let account = hostKeyAccount(host: host, port: port)
        guard let data = try await keychain.get(account: account, service: hostKeyService) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveHostKeyFingerprint(_ fingerprint: String, host: String, port: Int) async throws {
        let account = hostKeyAccount(host: host, port: port)
        guard let data = fingerprint.data(using: .utf8) else {
            throw StoreError.encodingFailed
        }
        try await keychain.set(data, account: account, service: hostKeyService)
    }

    func clearHostKey(host: String, port: Int) async throws {
        try await keychain.delete(account: hostKeyAccount(host: host, port: port), service: hostKeyService)
    }

    /// TOFU: accept first key; fail if a different key is presented later.
    func validateOrTrustHostKey(fingerprint: String, host: String, port: Int) async throws {
        if let known = try await hostKeyFingerprint(host: host, port: port) {
            if known != fingerprint {
                throw StoreError.hostKeyChanged(host: host, port: port)
            }
            return
        }
        try await saveHostKeyFingerprint(fingerprint, host: host, port: port)
    }

    private func hostKeyAccount(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}
