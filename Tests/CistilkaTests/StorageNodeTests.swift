import XCTest
@testable import Cistilka

final class StorageNodeTests: XCTestCase {
    func testPercentOfParent() {
        let parent = StorageNode.fixture(id: "p", byteSize: 1000, itemCount: 2)
        let child = StorageNode.fixture(id: "c", parentId: "p", byteSize: 250, itemCount: 1)
        XCTAssertEqual(child.percentOfParent(parentSize: parent.byteSize), 0.25, accuracy: 0.0001)
    }

    func testPercentOfParentZeroSafe() {
        let child = StorageNode.fixture(id: "c", byteSize: 10, itemCount: 1)
        XCTAssertEqual(child.percentOfParent(parentSize: 0), 0)
    }

    func testFixtureDefaults() {
        let node = StorageNode.fixture(id: "n1")
        XCTAssertEqual(node.id, "n1")
        XCTAssertNil(node.parentId)
        XCTAssertEqual(node.nodeKind, .file)
        XCTAssertEqual(node.byteSize, 0)
        XCTAssertEqual(node.itemCount, 1)
        XCTAssertEqual(node.permissionsState, .ok)
        XCTAssertEqual(node.scanGeneration, 1)
    }

    func testSourceKindCodable() throws {
        let encoded = try JSONEncoder().encode(SourceKind.googleDrive)
        let decoded = try JSONDecoder().decode(SourceKind.self, from: encoded)
        XCTAssertEqual(decoded, .googleDrive)
    }

    func testScanLocationIdentity() {
        let id = UUID()
        let location = ScanLocation(
            id: id,
            sourceKind: .local,
            displayName: "Home",
            rootRef: "/Users/test",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        XCTAssertEqual(location.id, id)
        XCTAssertEqual(location.scanState, .idle)
    }
}
