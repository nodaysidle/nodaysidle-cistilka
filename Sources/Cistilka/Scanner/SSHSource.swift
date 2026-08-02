import AppKit
import Foundation

/// SFTP-backed `ScanSource`. Low concurrency (2–4) for remote listings.
///
/// Trash: rename into `profile.remoteTrashPath` when set; otherwise permanent
/// delete (RemovalService requires typing `DELETE` before calling trash).
struct SSHSource: ScanSource {
    typealias ClientFactory = @Sendable () async throws -> any SFTPBrowsing

    let profile: SSHProfile
    /// Factory so tests inject `FakeSFTPClient` without opening sockets.
    let clientFactory: ClientFactory
    /// When true, `trash` may permanently remove if no remote trash path.
    var allowPermanentDelete: Bool

    private let maxConcurrentListings = 3

    var supportsTrash: Bool { true }

    /// UI / RemovalService: permanent delete needs strong confirm when no trash path.
    var requiresPermanentDeleteConfirm: Bool {
        let trash = profile.remoteTrashPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trash.isEmpty
    }

    init(
        profile: SSHProfile,
        allowPermanentDelete: Bool = false,
        clientFactory: @escaping ClientFactory
    ) {
        self.profile = profile
        self.allowPermanentDelete = allowPermanentDelete
        self.clientFactory = clientFactory
    }

    // MARK: - ScanSource

    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws {
        let client = try await clientFactory()
        defer {
            Task { try? await client.close() }
        }

        let progress = SSHProgressState()
        let rootPath = RemotePath.normalize(profile.remotePath)

        let rootNode = try await scanDirectory(
            client: client,
            path: rootPath,
            parentId: nil,
            locationId: location.id,
            generation: generation,
            displayName: profile.displayName,
            progress: progress,
            onBatch: onBatch,
            onProgress: onProgress
        )
        await onBatch([rootNode])
        await onProgress(await progress.snapshot())
    }

    func trash(nodes: [StorageNode]) async throws -> [RemovalResult] {
        let client = try await clientFactory()
        defer {
            Task { try? await client.close() }
        }

        let trashRootRaw = profile.remoteTrashPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let useTrashPath = !trashRootRaw.isEmpty

        if useTrashPath {
            let trashRoot = RemotePath.normalize(trashRootRaw)
            // Ensure trash directory exists (best-effort).
            try? await client.createDirectory(at: trashRoot)
        } else if !allowPermanentDelete {
            return nodes.map {
                .failed(
                    nodeId: $0.id,
                    message: "Permanent SSH delete requires strong confirmation (type DELETE)."
                )
            }
        }

        var results: [RemovalResult] = []
        results.reserveCapacity(nodes.count)

        for node in nodes {
            let remotePath = node.remoteId ?? node.logicalPath
            let path = RemotePath.normalize(remotePath)
            do {
                if useTrashPath {
                    let trashRoot = RemotePath.normalize(trashRootRaw)
                    let destName = uniqueTrashName(originalPath: path)
                    let dest = RemotePath.join(trashRoot, destName)
                    try await client.rename(from: path, to: dest)
                    results.append(.movedToTrash(nodeId: node.id))
                } else {
                    try await permanentRemove(client: client, path: path, isDirectory: node.nodeKind == .folder)
                    results.append(.movedToTrash(nodeId: node.id))
                }
            } catch {
                results.append(.failed(nodeId: node.id, message: error.localizedDescription))
            }
        }
        return results
    }

    func reveal(node: StorageNode) async throws {
        let path = resolveDisplayPath(node: node)
        let paste = "\(profile.username)@\(profile.host):\(path)"
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paste, forType: .string)
        }
        // Optional: open Terminal at host (no free-form shell with user paths).
        let script = """
        tell application "Terminal"
            activate
            do script "echo 'Cistilka remote path: \(path.replacingOccurrences(of: "'", with: "'\\''")) on \(profile.host)'"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            _ = appleScript.executeAndReturnError(&error)
        }
    }

    func resolveDisplayPath(node: StorageNode) -> String {
        if let remoteId = node.remoteId, !remoteId.isEmpty {
            return RemotePath.normalize(remoteId)
        }
        return RemotePath.normalize(node.logicalPath)
    }

    // MARK: - Walk

    private func scanDirectory(
        client: any SFTPBrowsing,
        path: String,
        parentId: String?,
        locationId: UUID,
        generation: UInt64,
        displayName: String?,
        progress: SSHProgressState,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> StorageNode {
        try Task.checkCancellation()
        let norm = RemotePath.normalize(path)
        let name = displayName ?? RemotePath.lastComponent(norm)
        await progress.noteDir(path: norm)
        await onProgress(await progress.snapshot())

        let children: [SFTPDirEntry]
        do {
            children = try await client.listDirectory(at: norm)
        } catch {
            return StorageNode(
                id: nodeId(path: norm, locationId: locationId),
                parentId: parentId,
                locationId: locationId,
                name: name,
                nodeKind: .folder,
                logicalPath: norm,
                byteSize: 0,
                itemCount: 0,
                fileExtension: nil,
                contentType: nil,
                isPackage: false,
                permissionsState: .denied,
                modifiedAt: nil,
                remoteId: norm,
                scanGeneration: generation
            )
        }

        var leafNodes: [StorageNode] = []
        var subdirs: [SFTPDirEntry] = []

        for entry in children {
            try Task.checkCancellation()
            if entry.isSymlink {
                // Do not follow symlinks; record as symlink leaf.
                let node = makeNode(
                    entry: entry,
                    parentId: nodeId(path: norm, locationId: locationId),
                    locationId: locationId,
                    generation: generation,
                    kind: .symlink,
                    itemCount: 1
                )
                leafNodes.append(node)
                await progress.noteFile(bytes: entry.byteSize, path: entry.path)
                continue
            }
            if entry.isDirectory {
                subdirs.append(entry)
            } else {
                let node = makeNode(
                    entry: entry,
                    parentId: nodeId(path: norm, locationId: locationId),
                    locationId: locationId,
                    generation: generation,
                    kind: .file,
                    itemCount: 1
                )
                leafNodes.append(node)
                await progress.noteFile(bytes: entry.byteSize, path: entry.path)
            }
        }

        if !leafNodes.isEmpty {
            await onBatch(leafNodes)
            await onProgress(await progress.snapshot())
        }

        var folderNodes: [StorageNode] = []
        folderNodes.reserveCapacity(subdirs.count)

        try await withThrowingTaskGroup(of: StorageNode.self) { group in
            var iterator = subdirs.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                while inFlight < maxConcurrentListings, let next = iterator.next() {
                    inFlight += 1
                    let nextEntry = next
                    let parentNodeId = nodeId(path: norm, locationId: locationId)
                    group.addTask {
                        try await self.scanDirectory(
                            client: client,
                            path: nextEntry.path,
                            parentId: parentNodeId,
                            locationId: locationId,
                            generation: generation,
                            displayName: nextEntry.name,
                            progress: progress,
                            onBatch: onBatch,
                            onProgress: onProgress
                        )
                    }
                }
            }

            enqueueNext()
            for try await folderNode in group {
                inFlight -= 1
                folderNodes.append(folderNode)
                enqueueNext()
            }
        }

        if !folderNodes.isEmpty {
            await onBatch(folderNodes)
        }

        let totalBytes = leafNodes.reduce(Int64(0)) { $0 + $1.byteSize }
            + folderNodes.reduce(Int64(0)) { $0 + $1.byteSize }
        let totalItems = leafNodes.reduce(Int64(0)) { $0 + $1.itemCount }
            + folderNodes.reduce(Int64(0)) { $0 + $1.itemCount }

        return StorageNode(
            id: nodeId(path: norm, locationId: locationId),
            parentId: parentId,
            locationId: locationId,
            name: name,
            nodeKind: .folder,
            logicalPath: norm,
            byteSize: totalBytes,
            itemCount: totalItems,
            fileExtension: nil,
            contentType: nil,
            isPackage: false,
            permissionsState: .ok,
            modifiedAt: nil,
            remoteId: norm,
            scanGeneration: generation
        )
    }

    private func makeNode(
        entry: SFTPDirEntry,
        parentId: String,
        locationId: UUID,
        generation: UInt64,
        kind: NodeKind,
        itemCount: Int64
    ) -> StorageNode {
        let ext: String?
        if kind == .file {
            let name = entry.name
            if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                ext = String(name[name.index(after: dot)...]).lowercased()
            } else {
                ext = nil
            }
        } else {
            ext = nil
        }
        return StorageNode(
            id: nodeId(path: entry.path, locationId: locationId),
            parentId: parentId,
            locationId: locationId,
            name: entry.name,
            nodeKind: kind,
            logicalPath: entry.path,
            byteSize: entry.byteSize,
            itemCount: itemCount,
            fileExtension: ext,
            contentType: nil,
            isPackage: false,
            permissionsState: .ok,
            modifiedAt: entry.modifiedAt,
            remoteId: entry.path,
            scanGeneration: generation
        )
    }

    private func nodeId(path: String, locationId: UUID) -> String {
        "ssh:\(locationId.uuidString):\(RemotePath.normalize(path))"
    }

    private func uniqueTrashName(originalPath: String) -> String {
        let base = RemotePath.lastComponent(originalPath)
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(base).\(stamp).\(UUID().uuidString.prefix(8))"
    }

    private func permanentRemove(client: any SFTPBrowsing, path: String, isDirectory: Bool) async throws {
        if isDirectory {
            // Recursive remove: list, delete children, then rmdir.
            let children = (try? await client.listDirectory(at: path)) ?? []
            for child in children {
                if child.isDirectory {
                    try await permanentRemove(client: client, path: child.path, isDirectory: true)
                } else {
                    try await client.removeFile(at: child.path)
                }
            }
            try await client.removeDirectory(at: path)
        } else {
            try await client.removeFile(at: path)
        }
    }
}

// MARK: - Progress

private actor SSHProgressState {
    private var dirsVisited = 0
    private var filesVisited = 0
    private var bytesSeen: Int64 = 0
    private var currentPath = ""

    func noteDir(path: String) {
        dirsVisited += 1
        currentPath = path
    }

    func noteFile(bytes: Int64, path: String) {
        filesVisited += 1
        bytesSeen += bytes
        currentPath = path
    }

    func snapshot() -> ScanProgress {
        ScanProgress(
            dirsVisited: dirsVisited,
            filesVisited: filesVisited,
            bytesSeen: bytesSeen,
            currentPath: currentPath
        )
    }
}
