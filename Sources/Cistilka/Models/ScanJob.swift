import Foundation

/// How a scan job walks the location tree.
enum ScanMode: Sendable, Equatable {
    case full
    case refreshSubtree(nodeId: String)
}

/// In-flight or completed scan work unit for a location.
struct ScanJob: Identifiable, Sendable, Equatable {
    var id: UUID
    var locationId: UUID
    var mode: ScanMode
    var progress: ScanProgress
    var errors: [String]
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        locationId: UUID,
        mode: ScanMode = .full,
        progress: ScanProgress = ScanProgress(),
        errors: [String] = [],
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.locationId = locationId
        self.mode = mode
        self.progress = progress
        self.errors = errors
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Streaming counters reported during a scan.
struct ScanProgress: Sendable, Equatable {
    var dirsVisited: Int
    var filesVisited: Int
    var bytesSeen: Int64
    var currentPath: String

    init(
        dirsVisited: Int = 0,
        filesVisited: Int = 0,
        bytesSeen: Int64 = 0,
        currentPath: String = ""
    ) {
        self.dirsVisited = dirsVisited
        self.filesVisited = filesVisited
        self.bytesSeen = bytesSeen
        self.currentPath = currentPath
    }
}
