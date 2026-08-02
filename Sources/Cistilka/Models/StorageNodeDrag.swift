import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Internal pasteboard type for dragging tree node IDs to the trash bar.
    static var cistilkaStorageNodeIDs: UTType {
        UTType(exportedAs: "com.nodaysidle.cistilka.storage-node-ids")
    }
}

/// Drag payload for one or more `StorageNode` IDs (multi-select drag).
struct StorageNodeIDList: Codable, Transferable, Hashable, Sendable {
    var ids: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cistilkaStorageNodeIDs)
    }
}
