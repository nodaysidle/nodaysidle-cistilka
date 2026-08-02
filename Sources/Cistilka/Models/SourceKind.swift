import Foundation

/// Identifies which storage backend a location or node belongs to.
enum SourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case googleDrive
    case oneDrive
    case ssh
}
