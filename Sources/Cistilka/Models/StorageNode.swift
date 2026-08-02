import Foundation

/// Classification of a storage tree entry.
enum NodeKind: String, Codable, Sendable, Equatable, CaseIterable {
    case folder
    case file
    case symlink
    case package
    case unknown
}

/// Permission / access outcome for a node during scan.
enum PermissionsState: String, Codable, Sendable, Equatable, CaseIterable {
    case ok
    case denied
    case partial
}

/// Flat-table storage tree entry with parent links.
struct StorageNode: Identifiable, Sendable, Equatable {
    var id: String
    var parentId: String?
    var locationId: UUID
    var name: String
    var nodeKind: NodeKind
    var logicalPath: String
    var byteSize: Int64
    /// Recursive file count under folders; `1` for files.
    var itemCount: Int64
    var fileExtension: String?
    /// Optional UTI/MIME when cheap to obtain.
    var contentType: String?
    /// `.app` etc. treated as leaf by default.
    var isPackage: Bool
    var permissionsState: PermissionsState
    var modifiedAt: Date?
    /// Cloud/SSH id for API ops.
    var remoteId: String?
    /// Monotonic generation; stale rows discarded on full rescan.
    var scanGeneration: UInt64

    /// Share of parent size in `[0, 1]`. Returns `0` when `parentSize` is zero.
    func percentOfParent(parentSize: Int64) -> Double {
        guard parentSize > 0 else { return 0 }
        return Double(byteSize) / Double(parentSize)
    }
}

extension StorageNode {
    /// Test and index helper with sensible defaults.
    static func fixture(
        id: String,
        parentId: String? = nil,
        locationId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: String? = nil,
        kind: NodeKind = .file,
        logicalPath: String? = nil,
        byteSize: Int64 = 0,
        itemCount: Int64 = 1,
        ext: String? = nil,
        contentType: String? = nil,
        isPackage: Bool = false,
        permissionsState: PermissionsState = .ok,
        modifiedAt: Date? = nil,
        remoteId: String? = nil,
        generation: UInt64 = 1
    ) -> StorageNode {
        let resolvedName = name ?? id
        return StorageNode(
            id: id,
            parentId: parentId,
            locationId: locationId,
            name: resolvedName,
            nodeKind: kind,
            logicalPath: logicalPath ?? "/\(resolvedName)",
            byteSize: byteSize,
            itemCount: itemCount,
            fileExtension: ext,
            contentType: contentType,
            isPackage: isPackage,
            permissionsState: permissionsState,
            modifiedAt: modifiedAt,
            remoteId: remoteId,
            scanGeneration: generation
        )
    }
}
