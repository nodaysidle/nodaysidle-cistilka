import Foundation

/// Aggregated size/count for one file extension within a scope.
struct TypeTotal: Sendable, Equatable {
    var fileExtension: String
    var count: Int
    var bytes: Int64
}

extension ScanIndex {
    /// File-type totals for all files under `scopeRootId`, or entire index when `nil`.
    /// Sorted by `bytes` descending, then extension name ascending.
    func typeTotals(scopeRootId: String?) async -> [TypeTotal] {
        let files = fileNodes(scopeRootId: scopeRootId)
        var buckets: [String: (count: Int, bytes: Int64)] = [:]
        for file in files {
            let key = Self.normalizedExtension(file.fileExtension)
            var bucket = buckets[key] ?? (count: 0, bytes: 0)
            bucket.count += 1
            bucket.bytes += file.byteSize
            buckets[key] = bucket
        }
        return buckets
            .map { TypeTotal(fileExtension: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { a, b in
                if a.bytes != b.bytes { return a.bytes > b.bytes }
                return a.fileExtension.localizedStandardCompare(b.fileExtension) == .orderedAscending
            }
    }

    /// Lowercased extension without leading dot; missing → `(no extension)`.
    static func normalizedExtension(_ raw: String?) -> String {
        guard var ext = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !ext.isEmpty else {
            return "(no extension)"
        }
        if ext.hasPrefix(".") {
            ext = String(ext.dropFirst())
        }
        if ext.isEmpty { return "(no extension)" }
        return ext.lowercased()
    }
}
