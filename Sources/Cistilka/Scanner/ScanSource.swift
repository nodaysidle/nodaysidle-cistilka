import Foundation

/// Pluggable storage backend for enumeration, trash, and reveal.
protocol ScanSource: Sendable {
    var supportsTrash: Bool { get }

    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws

    func trash(nodes: [StorageNode]) async throws -> [RemovalResult]
    func reveal(node: StorageNode) async throws
    func resolveDisplayPath(node: StorageNode) -> String
}
