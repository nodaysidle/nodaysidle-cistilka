import Foundation

/// Outcome of attempting to remove a storage node (trash-first policy).
enum RemovalResult: Sendable, Equatable {
    case movedToTrash(nodeId: String)
    case failed(nodeId: String, message: String)
}
