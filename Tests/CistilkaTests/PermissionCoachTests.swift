import XCTest
@testable import Cistilka

final class PermissionCoachTests: XCTestCase {
    func testDoesNotCoachWhenHealthy() {
        XCTAssertFalse(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 0,
                totalScannedBytes: 5_000_000_000,
                isHomeScan: true
            )
        )
        XCTAssertFalse(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 50,
                totalScannedBytes: 1_000,
                isHomeScan: false
            )
        )
    }

    func testCoachesWhenDeniedExceedsThreshold() {
        XCTAssertTrue(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 51,
                totalScannedBytes: 5_000_000_000,
                isHomeScan: false
            )
        )
        XCTAssertTrue(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 100,
                totalScannedBytes: 0,
                isHomeScan: false,
                deniedThreshold: 50
            )
        )
    }

    func testDeniedAtThresholdDoesNotCoach() {
        // Brief: denied count > threshold (e.g. 50)
        XCTAssertFalse(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 50,
                totalScannedBytes: 5_000_000_000,
                isHomeScan: false
            )
        )
    }

    func testCoachesWhenHomeScanSuspiciouslySmall() {
        XCTAssertTrue(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 0,
                totalScannedBytes: 10_000_000,
                isHomeScan: true
            )
        )
        XCTAssertFalse(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 0,
                totalScannedBytes: 10_000_000,
                isHomeScan: false
            )
        )
    }

    func testCustomThresholds() {
        XCTAssertTrue(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 3,
                totalScannedBytes: 999,
                isHomeScan: false,
                deniedThreshold: 2
            )
        )
        XCTAssertTrue(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 0,
                totalScannedBytes: 100,
                isHomeScan: true,
                suspiciousHomeBytesCeiling: 200
            )
        )
        XCTAssertFalse(
            PermissionCoach.needsFDACoach(
                deniedNodeCount: 0,
                totalScannedBytes: 200,
                isHomeScan: true,
                suspiciousHomeBytesCeiling: 200
            )
        )
    }

    func testIsHomeRootPath() {
        let home = NSHomeDirectory()
        XCTAssertTrue(PermissionCoach.isHomeRootPath(home))
        XCTAssertTrue(PermissionCoach.isHomeRootPath((home as NSString).standardizingPath))
        XCTAssertFalse(PermissionCoach.isHomeRootPath("/Applications"))
        XCTAssertFalse(PermissionCoach.isHomeRootPath("/tmp"))
    }

    func testDiagnosticsLogAppendAndExport() async throws {
        let log = DiagnosticsLog()
        await log.append("scan started")
        await log.append("denied: /private/var")
        let lines = await log.snapshot()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("scan started"))
        XCTAssertTrue(lines[1].contains("denied: /private/var"))

        let url = try await log.exportToTemporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("scan started"))
        XCTAssertTrue(text.contains("denied: /private/var"))
        XCTAssertTrue(url.pathExtension == "log" || url.lastPathComponent.contains("cistilka"))
    }
}
