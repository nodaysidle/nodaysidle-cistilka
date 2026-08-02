import Foundation

/// JSON persistence for durable `[ScanLocation]` lists under Application Support.
struct LocationStore: Sendable {
    let fileURL: URL

    /// Uses `Application Support/<bundleID>/locations.json` when `directory` is nil.
    init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent(AppIdentity.bundleID, isDirectory: true)
        }
        self.fileURL = dir.appendingPathComponent("locations.json", isDirectory: false)
    }

    func load() throws -> [ScanLocation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ScanLocation].self, from: data)
    }

    func save(_ locations: [ScanLocation]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(locations)
        try data.write(to: fileURL, options: .atomic)
    }
}
