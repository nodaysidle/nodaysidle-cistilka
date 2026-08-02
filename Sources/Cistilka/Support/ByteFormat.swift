import Foundation

/// Human-readable byte counts for UI and tests.
enum ByteFormat {
    /// Formats using 1024-based binary file units (e.g. `"12 GB"` for 12 × 1024³).
    ///
    /// Rule (locked): `countStyle = .binary`, adaptive units, includes unit label.
    /// Whole multiples of a unit render without a fractional part (e.g. `"12 GB"`, not `"12.0 GB"`).
    static func string(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
