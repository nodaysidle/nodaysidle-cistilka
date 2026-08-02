import AppKit
import Foundation

/// Full Disk Access coaching: pure thresholds + Settings open + re-check probe.
enum PermissionCoach {
    /// Default: coach when more than this many nodes are permission-denied.
    static let defaultDeniedThreshold = 50
    /// Default: home scan under this many bytes is treated as suspiciously incomplete.
    static let defaultSuspiciousHomeBytesCeiling: Int64 = 50_000_000

    /// Pure decision: whether to show the Full Disk Access coach after a scan.
    ///
    /// - Coaches when `deniedNodeCount` **>** `deniedThreshold` (default 50).
    /// - Coaches when `isHomeScan` and `totalScannedBytes` **<** `suspiciousHomeBytesCeiling`.
    static func needsFDACoach(
        deniedNodeCount: Int,
        totalScannedBytes: Int64,
        isHomeScan: Bool,
        deniedThreshold: Int = defaultDeniedThreshold,
        suspiciousHomeBytesCeiling: Int64 = defaultSuspiciousHomeBytesCeiling
    ) -> Bool {
        if deniedNodeCount > deniedThreshold {
            return true
        }
        if isHomeScan && totalScannedBytes < suspiciousHomeBytesCeiling {
            return true
        }
        return false
    }

    /// Whether `path` is the current user's home directory root.
    static func isHomeRootPath(_ path: String) -> Bool {
        let home = (NSHomeDirectory() as NSString).standardizingPath
        let candidate = (path as NSString).standardizingPath
        return home == candidate
    }

    /// Candidate URLs for the Full Disk Access privacy pane (newest first).
    static var fullDiskAccessSettingsURLCandidates: [URL] {
        [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ].compactMap { URL(string: $0) }
    }

    /// Human fallback when no Settings URL opens.
    static let fullDiskAccessInstructions = """
    Open System Settings → Privacy & Security → Full Disk Access, then enable Cistilka and rescan.
    """

    /// Opens Full Disk Access settings; returns `false` if no URL could be opened.
    @MainActor
    @discardableResult
    static func openFullDiskAccessSettings() -> Bool {
        for url in fullDiskAccessSettingsURLCandidates {
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    /// Copy manual FDA steps to the pasteboard.
    @MainActor
    static func copyFullDiskAccessInstructions() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullDiskAccessInstructions, forType: .string)
    }

    /// Probe known TCC-protected paths under the home directory.
    ///
    /// - Returns `true` if at least one existing protected directory can be listed.
    /// - Returns `false` if protected directories exist but none are listable (likely no FDA).
    /// - Returns `true` when no probe paths exist (inconclusive; do not force failure).
    static func hasLikelyFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let relativeProbes = [
            "Library/Mail",
            "Library/Safari",
            "Library/Cookies",
            "Library/IntelligencePlatform",
            "Library/Application Support/CallHistoryDB",
        ]

        var sawProtected = false
        for rel in relativeProbes {
            let path = (home as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            sawProtected = true
            if (try? fileManager.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        // No known protected paths present → do not treat as denial.
        return !sawProtected
    }
}
