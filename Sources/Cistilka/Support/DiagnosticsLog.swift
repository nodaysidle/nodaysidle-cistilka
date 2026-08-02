import Foundation

/// Timestamped diagnostic lines for support / FDA troubleshooting.
actor DiagnosticsLog {
    private var lines: [String] = []
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Append a timestamped line.
    func append(_ message: String) {
        let stamp = formatter.string(from: Date())
        lines.append("[\(stamp)] \(message)")
    }

    /// Current lines (oldest first).
    func snapshot() -> [String] {
        lines
    }

    /// Clear all entries.
    func clear() {
        lines.removeAll(keepingCapacity: false)
    }

    /// Write log contents to a unique temp file and return its URL.
    func exportToTemporaryFile() throws -> URL {
        let name = "cistilka-diagnostics-\(UUID().uuidString).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let body: String
        if lines.isEmpty {
            body = ""
        } else {
            body = lines.joined(separator: "\n") + "\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
