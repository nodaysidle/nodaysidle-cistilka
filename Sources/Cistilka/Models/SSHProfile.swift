import Foundation

/// How the user authenticates to an SSH host. Secrets live in Keychain, not here.
enum SSHAuthMethod: String, Codable, Sendable, Equatable, CaseIterable {
    case password
    case privateKey
}

/// Durable SSH connection profile (no secrets).
struct SSHProfile: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var authMethod: SSHAuthMethod
    var remotePath: String
    /// When set, trash renames into this directory. When nil, permanent delete needs strong confirm.
    var remoteTrashPath: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: SSHAuthMethod = .password,
        remotePath: String = "/",
        remoteTrashPath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.remotePath = remotePath
        self.remoteTrashPath = remoteTrashPath
    }

    /// `user@host:path` form for `ScanLocation.rootRef`.
    var rootRef: String {
        let path = RemotePath.normalize(remotePath)
        let hostPart = port == 22 ? host : "\(host):\(port)"
        // Keep path after a single colon after host (standard scp-style when port is default).
        // When non-default port, use `user@host#port:path` to avoid ambiguous colons.
        if port == 22 {
            return "\(username)@\(host):\(path)"
        }
        return "\(username)@\(host)#\(port):\(path)"
    }
}

/// Secrets for an SSH profile — never persisted in `SSHProfile` JSON.
struct SSHSecrets: Codable, Sendable, Equatable {
    var password: String?
    var privateKeyPEM: String?
    var passphrase: String?
}

/// Absolute remote path helpers for SFTP (normalize, join).
enum RemotePath: Sendable {
    /// Absolute path: collapse empty segments / `//`, drop `.`, resolve `..`.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "/" }
        // Home-relative `~` stays as a single leading segment after slash so join stays absolute.
        if s.hasPrefix("~") {
            s = "/" + s
        } else if !s.hasPrefix("/") {
            s = "/" + s
        }

        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [String] = []
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(String(part))
        }
        if stack.isEmpty { return "/" }
        return "/" + stack.joined(separator: "/")
    }

    /// Join base directory and a single path component (not multi-segment name).
    static func join(_ base: String, _ name: String) -> String {
        let cleanedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanedName.isEmpty {
            return normalize(base)
        }
        let baseNorm = normalize(base)
        if baseNorm == "/" {
            return normalize("/" + cleanedName)
        }
        return normalize(baseNorm + "/" + cleanedName)
    }

    /// Basename of a remote path.
    static func lastComponent(_ path: String) -> String {
        let norm = normalize(path)
        if norm == "/" { return "/" }
        return norm.split(separator: "/").last.map(String.init) ?? norm
    }

    /// Parent directory, or `/` for root.
    static func parent(_ path: String) -> String {
        let norm = normalize(path)
        if norm == "/" { return "/" }
        var parts = norm.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return "/" }
        parts.removeLast()
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/")
    }
}
