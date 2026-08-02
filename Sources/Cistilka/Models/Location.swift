import Foundation

/// Lifecycle state of a scan for a durable location.
enum ScanState: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case scanning
    case cancelled
    case failed
    case complete
}

/// Durable scan target (not a one-off path string).
struct ScanLocation: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var sourceKind: SourceKind
    var displayName: String
    /// Bookmark data, drive root, Graph driveId, or `user@host:path`.
    var rootRef: String
    var accountId: String?
    var lastScannedAt: Date?
    var scanState: ScanState
}
