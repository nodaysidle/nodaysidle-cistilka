import XCTest
@testable import Cistilka

final class ByteFormatTests: XCTestCase {
    func testFormatsGigabytes() {
        // 12 * 1024^3 — locked to adaptive file-style output (no fractional part for whole GB)
        XCTAssertEqual(ByteFormat.string(bytes: 12_884_901_888), "12 GB")
    }

    func testFormatsZero() {
        let result = ByteFormat.string(bytes: 0)
        XCTAssertFalse(result.isEmpty)
        // ByteCountFormatter binary style may yield "Zero KB" depending on OS/locale.
        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("0") || result.localizedCaseInsensitiveContains("zero"),
            "unexpected zero format: \(result)"
        )
    }

    func testFormatsKilobytes() {
        let result = ByteFormat.string(bytes: 1024)
        XCTAssertEqual(result, "1 KB")
    }
}
