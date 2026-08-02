import AppKit
import Foundation

/// Local filesystem `ScanSource` using `FileManager` walks (no symlink follow).
struct LocalDiskSource: ScanSource {
    var supportsTrash: Bool { true }

    /// When true (default), packages (`.app`, etc.) are sized as a single leaf.
    /// When false, packages are walked like ordinary directories.
    let treatPackagesAsLeaf: Bool
    /// Concurrent subdirectory listings (Gentle 2 / Default 6 / Aggressive 12).
    private let maxConcurrentListings: Int

    init(treatPackagesAsLeaf: Bool = true, maxConcurrentListings: Int = 6) {
        self.treatPackagesAsLeaf = treatPackagesAsLeaf
        self.maxConcurrentListings = max(1, maxConcurrentListings)
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
    ]

    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws {
        let rootURL = URL(fileURLWithPath: location.rootRef, isDirectory: true).standardizedFileURL
        let progress = ProgressState()

        // Best-effort walk: never abort an entire location scan because one child is
        // unreadable / vanished (common under Home + Library). Root permission denials
        // produce a denied root node and complete successfully.
        let rootNode = await scanDirectory(
            url: rootURL,
            parentId: nil,
            locationId: location.id,
            generation: generation,
            progress: progress,
            onBatch: onBatch,
            onProgress: onProgress
        )
        await onBatch([rootNode])
        await onProgress(await progress.snapshot())
    }

    func trash(nodes: [StorageNode]) async throws -> [RemovalResult] {
        var results: [RemovalResult] = []
        results.reserveCapacity(nodes.count)
        for node in nodes {
            let path = resolveDisplayPath(node: node)
            let url = URL(fileURLWithPath: path)
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                results.append(.movedToTrash(nodeId: node.id))
            } catch {
                results.append(.failed(nodeId: node.id, message: error.localizedDescription))
            }
        }
        return results
    }

    func reveal(node: StorageNode) async throws {
        let url = URL(fileURLWithPath: resolveDisplayPath(node: node))
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func resolveDisplayPath(node: StorageNode) -> String {
        node.logicalPath
    }

    // MARK: - Walk

    private func scanDirectory(
        url: URL,
        parentId: String?,
        locationId: UUID,
        generation: UInt64,
        progress: ProgressState,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async -> StorageNode {
        if Task.isCancelled {
            return makeSkippedFolder(
                url: url,
                parentId: parentId,
                locationId: locationId,
                generation: generation,
                permissions: .partial
            )
        }

        let path = url.path
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        let values = try? url.resourceValues(forKeys: Self.resourceKeys)

        // Unreadable / vanished directory: emit denied/partial folder and continue.
        let childrenURLs: [URL]
        do {
            childrenURLs = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: [.skipsPackageDescendants]
            )
        } catch {
            await progress.noteDir(path: path)
            await onProgress(await progress.snapshot())
            return makeSkippedFolder(
                url: url,
                parentId: parentId,
                locationId: locationId,
                generation: generation,
                permissions: Self.isSoftSkipError(error) ? .denied : .partial,
                modifiedAt: values?.contentModificationDate
            )
        }

        await progress.noteDir(path: path)
        await onProgress(await progress.snapshot())

        // Partition: leaves vs subdirectories (packages are leaves).
        var leafNodes: [StorageNode] = []
        var subdirs: [URL] = []

        for childURL in childrenURLs {
            if Task.isCancelled { break }
            let child = childURL.standardizedFileURL
            let rv: URLResourceValues
            do {
                rv = try child.resourceValues(forKeys: Self.resourceKeys)
            } catch {
                // Soft-skip unreadable / vanished children.
                leafNodes.append(
                    makeDeniedNode(
                        url: child,
                        parentId: path,
                        locationId: locationId,
                        generation: generation
                    )
                )
                continue
            }

            if rv.isSymbolicLink == true {
                let node = makeLeafNode(
                    url: child,
                    parentId: path,
                    locationId: locationId,
                    generation: generation,
                    kind: .symlink,
                    isPackage: false,
                    byteSize: Self.preferredSize(rv),
                    itemCount: 1,
                    modifiedAt: rv.contentModificationDate,
                    permissionsState: .ok
                )
                leafNodes.append(node)
                await progress.noteFile(bytes: node.byteSize, path: child.path)
                continue
            }

            if rv.isPackage == true, treatPackagesAsLeaf {
                let size = Self.packageAllocatedSize(at: child)
                let node = makeLeafNode(
                    url: child,
                    parentId: path,
                    locationId: locationId,
                    generation: generation,
                    kind: .package,
                    isPackage: true,
                    byteSize: size,
                    itemCount: 1,
                    modifiedAt: rv.contentModificationDate,
                    permissionsState: .ok
                )
                leafNodes.append(node)
                await progress.noteFile(bytes: size, path: child.path)
                continue
            }

            // Packages with expand-on: treat as directory (still mark isPackage on folder node).
            if rv.isDirectory == true || (rv.isPackage == true && !treatPackagesAsLeaf) {
                subdirs.append(child)
                continue
            }

            // Regular file or other
            let size = Self.preferredSize(rv)
            let node = makeLeafNode(
                url: child,
                parentId: path,
                locationId: locationId,
                generation: generation,
                kind: .file,
                isPackage: false,
                byteSize: size,
                itemCount: 1,
                modifiedAt: rv.contentModificationDate,
                permissionsState: .ok
            )
            leafNodes.append(node)
            await progress.noteFile(bytes: size, path: child.path)
        }

        if !leafNodes.isEmpty {
            await onBatch(leafNodes)
            await onProgress(await progress.snapshot())
        }

        // Concurrent subdirectory listings (cap ~6). Non-throwing: each child is best-effort.
        var folderNodes: [StorageNode] = []
        folderNodes.reserveCapacity(subdirs.count)

        await withTaskGroup(of: StorageNode.self) { group in
            var iterator = subdirs.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                while inFlight < maxConcurrentListings, let next = iterator.next() {
                    inFlight += 1
                    let nextURL = next
                    group.addTask {
                        await self.scanDirectory(
                            url: nextURL,
                            parentId: path,
                            locationId: locationId,
                            generation: generation,
                            progress: progress,
                            onBatch: onBatch,
                            onProgress: onProgress
                        )
                    }
                }
            }

            enqueueNext()

            for await folderNode in group {
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

        let isPkg = values?.isPackage == true
        return StorageNode(
            id: path,
            parentId: parentId,
            locationId: locationId,
            name: name,
            nodeKind: isPkg ? .package : .folder,
            logicalPath: path,
            byteSize: totalBytes,
            itemCount: totalItems,
            fileExtension: nil,
            contentType: nil,
            isPackage: isPkg,
            permissionsState: .ok,
            modifiedAt: values?.contentModificationDate,
            remoteId: nil,
            scanGeneration: generation
        )
    }

    private func makeSkippedFolder(
        url: URL,
        parentId: String?,
        locationId: UUID,
        generation: UInt64,
        permissions: PermissionsState,
        modifiedAt: Date? = nil
    ) -> StorageNode {
        let path = url.path
        let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
        return StorageNode(
            id: path,
            parentId: parentId,
            locationId: locationId,
            name: name,
            nodeKind: .folder,
            logicalPath: path,
            byteSize: 0,
            itemCount: 0,
            fileExtension: nil,
            contentType: nil,
            isPackage: false,
            permissionsState: permissions,
            modifiedAt: modifiedAt,
            remoteId: nil,
            scanGeneration: generation
        )
    }

    // MARK: - Node builders

    private func makeLeafNode(
        url: URL,
        parentId: String,
        locationId: UUID,
        generation: UInt64,
        kind: NodeKind,
        isPackage: Bool,
        byteSize: Int64,
        itemCount: Int64,
        modifiedAt: Date?,
        permissionsState: PermissionsState
    ) -> StorageNode {
        let path = url.path
        let ext = url.pathExtension
        return StorageNode(
            id: path,
            parentId: parentId,
            locationId: locationId,
            name: url.lastPathComponent,
            nodeKind: kind,
            logicalPath: path,
            byteSize: byteSize,
            itemCount: itemCount,
            fileExtension: ext.isEmpty ? nil : ext.lowercased(),
            contentType: nil,
            isPackage: isPackage,
            permissionsState: permissionsState,
            modifiedAt: modifiedAt,
            remoteId: nil,
            scanGeneration: generation
        )
    }

    private func makeDeniedNode(
        url: URL,
        parentId: String,
        locationId: UUID,
        generation: UInt64
    ) -> StorageNode {
        StorageNode(
            id: url.path,
            parentId: parentId,
            locationId: locationId,
            name: url.lastPathComponent,
            nodeKind: .unknown,
            logicalPath: url.path,
            byteSize: 0,
            itemCount: 0,
            fileExtension: nil,
            contentType: nil,
            isPackage: false,
            permissionsState: .denied,
            modifiedAt: nil,
            remoteId: nil,
            scanGeneration: generation
        )
    }

    // MARK: - Sizing helpers

    private static func preferredSize(_ values: URLResourceValues) -> Int64 {
        if let allocated = values.totalFileAllocatedSize {
            return Int64(allocated)
        }
        if let logical = values.fileSize {
            return Int64(logical)
        }
        return 0
    }

    /// Sum allocated sizes of package contents without emitting child nodes.
    private static func packageAllocatedSize(at packageURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            let rv = try? packageURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            if let allocated = rv?.totalFileAllocatedSize { return Int64(allocated) }
            if let logical = rv?.fileSize { return Int64(logical) }
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let rv = try? fileURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey,
            ])
            if rv?.isSymbolicLink == true { continue }
            if rv?.isDirectory == true { continue }
            total += preferredSize(rv ?? URLResourceValues())
        }
        return total
    }

    /// Errors that should not abort a whole-location scan (permission, missing, busy, etc.).
    private static func isSoftSkipError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM), Int(ENOENT), Int(ENOTDIR), Int(ELOOP),
                 Int(EIO), Int(EBUSY), Int(ESTALE), Int(ETIMEDOUT):
                return true
            default:
                break
            }
        }
        if ns.domain == NSCocoaErrorDomain {
            // 257 NSFileReadNoPermissionError, 260 NSFileReadNoSuchFileError, 256 NSFileReadUnknownError
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileReadNoSuchFileError, NSFileReadUnknownError:
                return true
            default:
                // Many FileManager failures under Home are Cocoa read/open variants.
                if (200..<400).contains(ns.code) { return true }
            }
        }
        return false
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        isSoftSkipError(error)
    }
}

// MARK: - Progress

private actor ProgressState {
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
