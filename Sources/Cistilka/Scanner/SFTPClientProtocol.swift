import Foundation

/// One entry from SFTP readdir (testable without a live network).
struct SFTPDirEntry: Sendable, Equatable {
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var byteSize: Int64
    var modifiedAt: Date?
}

enum SFTPClientError: Error, LocalizedError, Sendable {
    case notConnected
    case pathNotFound(String)
    case permissionDenied(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SFTP client is not connected."
        case .pathNotFound(let path):
            return "Remote path not found: \(path)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        case .operationFailed(let message):
            return message
        }
    }
}

/// Minimal SFTP surface used by `SSHSource` (Citadel-backed or fake).
protocol SFTPBrowsing: Sendable {
    func listDirectory(at path: String) async throws -> [SFTPDirEntry]
    func getAttributes(at path: String) async throws -> SFTPDirEntry
    func rename(from oldPath: String, to newPath: String) async throws
    func removeFile(at path: String) async throws
    func removeDirectory(at path: String) async throws
    func createDirectory(at path: String) async throws
    func close() async throws
}

/// In-memory SFTP tree for unit tests.
actor FakeSFTPClient: SFTPBrowsing {
    /// Path → (isDirectory, size, modifiedAt, children names for dirs).
    private var nodes: [String: FakeNode]

    struct FakeNode: Sendable {
        var isDirectory: Bool
        var isSymlink: Bool
        var byteSize: Int64
        var modifiedAt: Date?
        /// Child basenames when directory.
        var children: [String]
    }

    init(nodes: [String: FakeNode] = [:]) {
        var seeded = nodes
        if seeded["/"] == nil {
            seeded["/"] = FakeNode(
                isDirectory: true,
                isSymlink: false,
                byteSize: 0,
                modifiedAt: nil,
                children: []
            )
        }
        self.nodes = seeded
    }

    /// Convenience: build a small tree from path → size (files) or directory flag.
    static func withTree(_ entries: [(path: String, isDirectory: Bool, size: Int64)]) -> FakeSFTPClient {
        var map: [String: FakeNode] = [
            "/": FakeNode(isDirectory: true, isSymlink: false, byteSize: 0, modifiedAt: nil, children: []),
        ]
        for entry in entries {
            let path = RemotePath.normalize(entry.path)
            map[path] = FakeNode(
                isDirectory: entry.isDirectory,
                isSymlink: false,
                byteSize: entry.size,
                modifiedAt: nil,
                children: []
            )
            // Link parents.
            var parent = RemotePath.parent(path)
            let name = RemotePath.lastComponent(path)
            while true {
                var parentNode = map[parent] ?? FakeNode(
                    isDirectory: true,
                    isSymlink: false,
                    byteSize: 0,
                    modifiedAt: nil,
                    children: []
                )
                parentNode.isDirectory = true
                if !parentNode.children.contains(name) && parent == RemotePath.parent(path) {
                    parentNode.children.append(name)
                }
                // Ensure intermediate dirs exist with child links.
                if parent != RemotePath.parent(path) {
                    let childName = path
                        .dropFirst(parent == "/" ? 1 : parent.count + 1)
                        .split(separator: "/")
                        .first
                        .map(String.init)
                    if let childName, !parentNode.children.contains(childName) {
                        parentNode.children.append(childName)
                    }
                }
                map[parent] = parentNode
                if parent == "/" { break }
                parent = RemotePath.parent(parent)
            }
            // Fix direct parent child list properly.
            let directParent = RemotePath.parent(path)
            var pNode = map[directParent] ?? FakeNode(
                isDirectory: true,
                isSymlink: false,
                byteSize: 0,
                modifiedAt: nil,
                children: []
            )
            pNode.isDirectory = true
            let base = RemotePath.lastComponent(path)
            if !pNode.children.contains(base) {
                pNode.children.append(base)
            }
            map[directParent] = pNode
        }
        return FakeSFTPClient(nodes: map)
    }

    func listDirectory(at path: String) async throws -> [SFTPDirEntry] {
        let norm = RemotePath.normalize(path)
        guard let node = nodes[norm], node.isDirectory else {
            throw SFTPClientError.pathNotFound(norm)
        }
        return node.children.compactMap { name -> SFTPDirEntry? in
            let childPath = RemotePath.join(norm, name)
            guard let child = nodes[childPath] else { return nil }
            return SFTPDirEntry(
                name: name,
                path: childPath,
                isDirectory: child.isDirectory,
                isSymlink: child.isSymlink,
                byteSize: child.byteSize,
                modifiedAt: child.modifiedAt
            )
        }
    }

    func getAttributes(at path: String) async throws -> SFTPDirEntry {
        let norm = RemotePath.normalize(path)
        guard let node = nodes[norm] else {
            throw SFTPClientError.pathNotFound(norm)
        }
        return SFTPDirEntry(
            name: RemotePath.lastComponent(norm),
            path: norm,
            isDirectory: node.isDirectory,
            isSymlink: node.isSymlink,
            byteSize: node.byteSize,
            modifiedAt: node.modifiedAt
        )
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        let old = RemotePath.normalize(oldPath)
        let new = RemotePath.normalize(newPath)
        guard let node = nodes[old] else {
            throw SFTPClientError.pathNotFound(old)
        }
        // Move node + descendants.
        let prefix = old == "/" ? old : old + "/"
        var moves: [(String, FakeNode)] = [(new, node)]
        for (path, n) in nodes where path.hasPrefix(prefix) {
            let suffix = String(path.dropFirst(old.count))
            moves.append((RemotePath.normalize(new + suffix), n))
        }
        // Unlink old.
        removeFromParent(path: old)
        for (path, _) in nodes where path == old || path.hasPrefix(prefix) {
            nodes[path] = nil
        }
        for (path, n) in moves {
            nodes[path] = n
        }
        addToParent(path: new)
        // Rebuild children lists for moved directories.
        rebuildChildren(for: new, node: node)
    }

    func removeFile(at path: String) async throws {
        let norm = RemotePath.normalize(path)
        guard let node = nodes[norm], !node.isDirectory else {
            throw SFTPClientError.pathNotFound(norm)
        }
        removeFromParent(path: norm)
        nodes[norm] = nil
    }

    func removeDirectory(at path: String) async throws {
        let norm = RemotePath.normalize(path)
        guard norm != "/" else {
            throw SFTPClientError.operationFailed("Cannot remove root")
        }
        guard let node = nodes[norm], node.isDirectory else {
            throw SFTPClientError.pathNotFound(norm)
        }
        if !node.children.isEmpty {
            throw SFTPClientError.operationFailed("Directory not empty: \(norm)")
        }
        removeFromParent(path: norm)
        nodes[norm] = nil
    }

    func createDirectory(at path: String) async throws {
        let norm = RemotePath.normalize(path)
        if nodes[norm] != nil {
            return
        }
        nodes[norm] = FakeNode(
            isDirectory: true,
            isSymlink: false,
            byteSize: 0,
            modifiedAt: nil,
            children: []
        )
        addToParent(path: norm)
    }

    func close() async throws {}

    // MARK: - Helpers

    private func removeFromParent(path: String) {
        let parent = RemotePath.parent(path)
        let name = RemotePath.lastComponent(path)
        guard var p = nodes[parent] else { return }
        p.children.removeAll { $0 == name }
        nodes[parent] = p
    }

    private func addToParent(path: String) {
        let parent = RemotePath.parent(path)
        let name = RemotePath.lastComponent(path)
        var p = nodes[parent] ?? FakeNode(
            isDirectory: true,
            isSymlink: false,
            byteSize: 0,
            modifiedAt: nil,
            children: []
        )
        p.isDirectory = true
        if !p.children.contains(name) {
            p.children.append(name)
        }
        nodes[parent] = p
    }

    private func rebuildChildren(for path: String, node: FakeNode) {
        guard node.isDirectory else { return }
        var updated = nodes[path] ?? node
        var kids: [String] = []
        let prefix = path == "/" ? "/" : path + "/"
        for (childPath, _) in nodes where childPath != path && childPath.hasPrefix(prefix) {
            let rest = String(childPath.dropFirst(prefix.count))
            if !rest.contains("/") {
                kids.append(rest)
            }
        }
        updated.children = kids.sorted()
        nodes[path] = updated
    }
}
