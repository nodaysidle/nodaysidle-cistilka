import Foundation

/// High-level reveal entry point; delegates to the active `ScanSource`.
struct RevealService {
    @MainActor
    static func reveal(node: StorageNode, source: any ScanSource) async throws {
        try await source.reveal(node: node)
    }
}
