import Foundation
import GRDB

/// Durable SQLite persistence for scan tree nodes, keyed by location.
actor SQLiteStore {
    private let dbQueue: DatabaseQueue

    init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nodes (
                  id TEXT NOT NULL,
                  location_id TEXT NOT NULL,
                  parent_id TEXT,
                  name TEXT NOT NULL,
                  node_kind TEXT NOT NULL,
                  logical_path TEXT NOT NULL,
                  byte_size INTEGER NOT NULL,
                  item_count INTEGER NOT NULL,
                  file_extension TEXT NOT NULL,
                  is_package INTEGER NOT NULL,
                  permissions_state TEXT NOT NULL,
                  modified_at REAL,
                  remote_id TEXT,
                  scan_generation INTEGER NOT NULL,
                  PRIMARY KEY (location_id, id)
                );
                CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(location_id, parent_id);
                """)
        }
    }

    /// Persist nodes. Replaces all existing rows for each distinct `locationId` in the batch.
    func save(nodes: [StorageNode]) async throws {
        let locationIds = Set(nodes.map(\.locationId))
        try await dbQueue.write { db in
            for locationId in locationIds {
                try db.execute(
                    sql: "DELETE FROM nodes WHERE location_id = ?",
                    arguments: [locationId.uuidString]
                )
            }
            for node in nodes {
                try db.execute(
                    sql: """
                        INSERT INTO nodes (
                          id, location_id, parent_id, name, node_kind, logical_path,
                          byte_size, item_count, file_extension, is_package,
                          permissions_state, modified_at, remote_id, scan_generation
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        node.id,
                        node.locationId.uuidString,
                        node.parentId,
                        node.name,
                        node.nodeKind.rawValue,
                        node.logicalPath,
                        node.byteSize,
                        node.itemCount,
                        node.fileExtension ?? "",
                        node.isPackage ? 1 : 0,
                        node.permissionsState.rawValue,
                        node.modifiedAt.map(\.timeIntervalSince1970),
                        node.remoteId,
                        Int64(node.scanGeneration),
                    ]
                )
            }
        }
    }

    func load(locationId: UUID) async throws -> [StorageNode] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM nodes WHERE location_id = ?",
                arguments: [locationId.uuidString]
            )
            return try rows.map { try Self.node(from: $0) }
        }
    }

    func delete(locationId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM nodes WHERE location_id = ?",
                arguments: [locationId.uuidString]
            )
        }
    }

    /// Delete all cached scan rows (all locations).
    func deleteAll() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM nodes")
        }
    }

    // MARK: - Mapping

    private static func node(from row: Row) throws -> StorageNode {
        let id: String = row["id"]
        let locationString: String = row["location_id"]
        guard let locationId = UUID(uuidString: locationString) else {
            throw SQLiteStoreError.invalidLocationId(locationString)
        }
        let parentId: String? = row["parent_id"]
        let name: String = row["name"]
        let nodeKindRaw: String = row["node_kind"]
        guard let nodeKind = NodeKind(rawValue: nodeKindRaw) else {
            throw SQLiteStoreError.invalidNodeKind(nodeKindRaw)
        }
        let logicalPath: String = row["logical_path"]
        let byteSize: Int64 = row["byte_size"]
        let itemCount: Int64 = row["item_count"]
        let fileExtensionStored: String = row["file_extension"]
        let fileExtension: String? = fileExtensionStored.isEmpty ? nil : fileExtensionStored
        let isPackageInt: Int = row["is_package"]
        let permissionsRaw: String = row["permissions_state"]
        guard let permissionsState = PermissionsState(rawValue: permissionsRaw) else {
            throw SQLiteStoreError.invalidPermissionsState(permissionsRaw)
        }
        let modifiedAtSeconds: Double? = row["modified_at"]
        let modifiedAt = modifiedAtSeconds.map { Date(timeIntervalSince1970: $0) }
        let remoteId: String? = row["remote_id"]
        let scanGeneration: Int64 = row["scan_generation"]

        return StorageNode(
            id: id,
            parentId: parentId,
            locationId: locationId,
            name: name,
            nodeKind: nodeKind,
            logicalPath: logicalPath,
            byteSize: byteSize,
            itemCount: itemCount,
            fileExtension: fileExtension,
            contentType: nil,
            isPackage: isPackageInt != 0,
            permissionsState: permissionsState,
            modifiedAt: modifiedAt,
            remoteId: remoteId,
            scanGeneration: UInt64(scanGeneration)
        )
    }
}

enum SQLiteStoreError: Error, Equatable {
    case invalidLocationId(String)
    case invalidNodeKind(String)
    case invalidPermissionsState(String)
}
