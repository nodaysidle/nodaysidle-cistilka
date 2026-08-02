import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH

/// Builds Citadel auth + connects an SFTP session with TOFU host-key checking.
enum CitadelSFTPBridge {
    enum BridgeError: Error, LocalizedError, Sendable {
        case missingPassword
        case missingPrivateKey
        case unsupportedPrivateKey
        case hostKeyChanged(host: String, port: Int)
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingPassword:
                return "SSH password is required."
            case .missingPrivateKey:
                return "SSH private key is required."
            case .unsupportedPrivateKey:
                return "Unsupported private key type (use OpenSSH ed25519 or RSA)."
            case .hostKeyChanged(let host, let port):
                return "SSH host key for \(host):\(port) changed. Clear stored key to re-trust."
            case .connectionFailed(let message):
                return "SSH connection failed: \(message)"
            }
        }
    }

    /// Connect using profile + secrets; validates host key via TOFU store.
    static func connect(
        profile: SSHProfile,
        secrets: SSHSecrets,
        hostKeyStore: SSHCredentialStore
    ) async throws -> any SFTPBrowsing {
        let auth = try makeAuthenticationMethod(profile: profile, secrets: secrets)
        let host = profile.host
        let port = profile.port

        let knownFingerprint = try await hostKeyStore.hostKeyFingerprint(host: host, port: port)
        let captured = HostKeyCapture()
        let validator = SSHHostKeyValidator.custom(
            TOFUHostKeyDelegate(
                knownFingerprint: knownFingerprint,
                onAccept: { fp in
                    Task {
                        try? await hostKeyStore.saveHostKeyFingerprint(fp, host: host, port: port)
                    }
                    captured.fingerprint = fp
                },
                onMismatch: {
                    captured.mismatch = true
                }
            )
        )

        do {
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never,
                algorithms: .all
            )

            if captured.mismatch {
                try? await client.close()
                throw BridgeError.hostKeyChanged(host: host, port: port)
            }

            // First connect TOFU: ensure fingerprint persisted (delegate may race).
            if let fp = captured.fingerprint {
                try await hostKeyStore.validateOrTrustHostKey(fingerprint: fp, host: host, port: port)
            }

            let sftp = try await client.openSFTP()
            return CitadelSFTPSession(ssh: client, sftp: sftp)
        } catch let error as BridgeError {
            throw error
        } catch {
            if captured.mismatch {
                throw BridgeError.hostKeyChanged(host: host, port: port)
            }
            throw BridgeError.connectionFailed(error.localizedDescription)
        }
    }

    static func makeAuthenticationMethod(
        profile: SSHProfile,
        secrets: SSHSecrets
    ) throws -> SSHAuthenticationMethod {
        switch profile.authMethod {
        case .password:
            guard let password = secrets.password, !password.isEmpty else {
                throw BridgeError.missingPassword
            }
            return .passwordBased(username: profile.username, password: password)
        case .privateKey:
            guard let pem = secrets.privateKeyPEM, !pem.isEmpty else {
                throw BridgeError.missingPrivateKey
            }
            let decryption = secrets.passphrase.flatMap { $0.data(using: .utf8) }
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryption) {
                return .ed25519(username: profile.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decryption) {
                return .rsa(username: profile.username, privateKey: key)
            }
            throw BridgeError.unsupportedPrivateKey
        }
    }
}

// MARK: - Host key TOFU

private final class HostKeyCapture: @unchecked Sendable {
    var fingerprint: String?
    var mismatch = false
}

private final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let knownFingerprint: String?
    private let onAccept: @Sendable (String) -> Void
    private let onMismatch: @Sendable () -> Void

    init(
        knownFingerprint: String?,
        onAccept: @escaping @Sendable (String) -> Void,
        onMismatch: @escaping @Sendable () -> Void
    ) {
        self.knownFingerprint = knownFingerprint
        self.onAccept = onAccept
        self.onMismatch = onMismatch
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = CitadelSFTPBridge.fingerprint(for: hostKey)
        if let known = knownFingerprint {
            if known == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                onMismatch()
                validationCompletePromise.fail(CitadelSFTPBridge.BridgeError.hostKeyChanged(host: "", port: 0))
            }
            return
        }
        // First seen — TOFU accept.
        onAccept(fingerprint)
        validationCompletePromise.succeed(())
    }
}

extension CitadelSFTPBridge {
    /// Stable SHA-256 fingerprint of the SSH wire-format public key (OpenSSH-style).
    ///
    /// Uses `NIOSSHPublicKey.write(to:)` for canonical key material rather than
    /// `String(describing:)`, which is not guaranteed stable across library versions.
    static func fingerprint(for key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let raw = buffer.readBytes(length: buffer.readableBytes) ?? []
        let digest = SHA256.hash(data: raw)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SHA256:\(hex)"
    }
}

// MARK: - Live session

private final class CitadelSFTPSession: SFTPBrowsing, @unchecked Sendable {
    private let ssh: SSHClient
    private let sftp: SFTPClient
    private let closeState = CloseState()

    init(ssh: SSHClient, sftp: SFTPClient) {
        self.ssh = ssh
        self.sftp = sftp
    }

    private actor CloseState {
        private var closed = false
        func markClosedIfNeeded() -> Bool {
            if closed { return true }
            closed = true
            return false
        }
    }

    func listDirectory(at path: String) async throws -> [SFTPDirEntry] {
        let norm = RemotePath.normalize(path)
        let names = try await sftp.listDirectory(atPath: norm)
        var entries: [SFTPDirEntry] = []
        for nameMsg in names {
            for component in nameMsg.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }
                let childPath = RemotePath.join(norm, filename)
                let attrs = component.attributes
                let (isDir, isLink) = Self.classify(attributes: attrs, longname: component.longname)
                let size = Int64(attrs.size ?? 0)
                let modified = attrs.accessModificationTime?.modificationTime
                entries.append(
                    SFTPDirEntry(
                        name: filename,
                        path: childPath,
                        isDirectory: isDir,
                        isSymlink: isLink,
                        byteSize: size,
                        modifiedAt: modified
                    )
                )
            }
        }
        return entries
    }

    func getAttributes(at path: String) async throws -> SFTPDirEntry {
        let norm = RemotePath.normalize(path)
        let attrs = try await sftp.getAttributes(at: norm)
        let (isDir, isLink) = Self.classify(attributes: attrs, longname: "")
        return SFTPDirEntry(
            name: RemotePath.lastComponent(norm),
            path: norm,
            isDirectory: isDir,
            isSymlink: isLink,
            byteSize: Int64(attrs.size ?? 0),
            modifiedAt: attrs.accessModificationTime?.modificationTime
        )
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        try await sftp.rename(
            at: RemotePath.normalize(oldPath),
            to: RemotePath.normalize(newPath)
        )
    }

    func removeFile(at path: String) async throws {
        try await sftp.remove(at: RemotePath.normalize(path))
    }

    func removeDirectory(at path: String) async throws {
        try await sftp.rmdir(at: RemotePath.normalize(path))
    }

    func createDirectory(at path: String) async throws {
        try await sftp.createDirectory(atPath: RemotePath.normalize(path))
    }

    func close() async throws {
        let already = await closeState.markClosedIfNeeded()
        guard !already else { return }
        try? await sftp.close()
        try? await ssh.close()
    }

    private static func classify(
        attributes: SFTPFileAttributes,
        longname: String
    ) -> (isDirectory: Bool, isSymlink: Bool) {
        if let perms = attributes.permissions {
            let mode = perms & 0o170000
            if mode == 0o040000 { return (true, false) }
            if mode == 0o120000 { return (false, true) }
            return (false, false)
        }
        if longname.hasPrefix("d") { return (true, false) }
        if longname.hasPrefix("l") { return (false, true) }
        return (false, false)
    }
}
