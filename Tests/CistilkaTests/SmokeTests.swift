import XCTest
@testable import Cistilka

final class SmokeTests: XCTestCase {
    func testBundleNameConstant() {
        XCTAssertEqual(AppIdentity.name, "Cistilka")
    }
}
