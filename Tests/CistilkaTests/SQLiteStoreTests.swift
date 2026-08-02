import XCTest
@testable import Cistilka

final class SQLiteStoreTests: XCTestCase {
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistilka-sqlite-test-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL)
        }
        dbURL = nil
        try super.tearDownWithError()
    }

    func testRoundTripSaveLoad() async throws {
        let store = try SQLiteStore(url: dbURL)
        let loc = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let nodes: [StorageNode] = [
            .fixture(
                id: "root",
                parentId: nil,
                locationId: loc,
                name: "Root",
                kind: .folder,
                logicalPath: "/Root",
                byteSize: 150,
                itemCount: 2,
                generation: 3
            ),
            .fixture(
                id: "a",
                parentId: "root",
                locationId: loc,
                name: "a.txt",
                kind: .file,
                logicalPath: "/Root/a.txt",
                byteSize: 100,
                itemCount: 1,
                ext: "txt",
                isPackage: false,
                permissionsState: .ok,
                modifiedAt: modified,
                remoteId: "remote-a",
                generation: 3
            ),
            .fixture(
                id: "b",
                parentId: "root",
                locationId: loc,
                name: "b.app",
                kind: .package,
                logicalPath: "/Root/b.app",
                byteSize: 50,
                itemCount: 1,
                ext: "app",
                isPackage: true,
                permissionsState: .partial,
                generation: 3
            ),
        ]

        try await store.save(nodes: nodes)
        let loaded = try await store.load(locationId: loc)

        XCTAssertEqual(loaded.count, 3)
        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        XCTAssertEqual(byId["root"]?.name, "Root")
        XCTAssertEqual(byId["root"]?.parentId, nil)
        XCTAssertEqual(byId["root"]?.nodeKind, .folder)
        XCTAssertEqual(byId["root"]?.byteSize, 150)
        XCTAssertEqual(byId["root"]?.itemCount, 2)
        XCTAssertEqual(byId["root"]?.scanGeneration, 3)
        XCTAssertEqual(byId["root"]?.locationId, loc)

        XCTAssertEqual(byId["a"]?.parentId, "root")
        XCTAssertEqual(byId["a"]?.fileExtension, "txt")
        XCTAssertEqual(byId["a"]?.remoteId, "remote-a")
        XCTAssertEqual(byId["a"]?.modifiedAt?.timeIntervalSince1970, modified.timeIntervalSince1970)
        XCTAssertEqual(byId["a"]?.permissionsState, .ok)

        XCTAssertEqual(byId["b"]?.isPackage, true)
        XCTAssertEqual(byId["b"]?.nodeKind, .package)
        XCTAssertEqual(byId["b"]?.permissionsState, .partial)
    }

    func testDeleteLocationRemovesOnlyThatLocation() async throws {
        let store = try SQLiteStore(url: dbURL)
        let locA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let locB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        try await store.save(nodes: [
            .fixture(id: "a1", locationId: locA, name: "a1", kind: .file, byteSize: 1, generation: 1),
            .fixture(id: "b1", locationId: locB, name: "b1", kind: .file, byteSize: 2, generation: 1),
        ])
        try await store.delete(locationId: locA)
        let aNodes = try await store.load(locationId: locA)
        let bNodes = try await store.load(locationId: locB)
        XCTAssertTrue(aNodes.isEmpty)
        XCTAssertEqual(bNodes.map(\.id), ["b1"])
    }

    func testSaveReplacesExistingNodesForLocation() async throws {
        let store = try SQLiteStore(url: dbURL)
        let loc = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        try await store.save(nodes: [
            .fixture(id: "old", locationId: loc, name: "old", kind: .file, byteSize: 1, generation: 1),
        ])
        try await store.save(nodes: [
            .fixture(id: "new", locationId: loc, name: "new", kind: .file, byteSize: 9, generation: 2),
        ])
        let loaded = try await store.load(locationId: loc)
        XCTAssertEqual(loaded.map(\.id), ["new"])
        XCTAssertEqual(loaded.first?.byteSize, 9)
    }

    func testNilFileExtensionRoundTripsAsNil() async throws {
        let store = try SQLiteStore(url: dbURL)
        let loc = UUID()
        try await store.save(nodes: [
            .fixture(id: "n", locationId: loc, name: "noext", kind: .file, byteSize: 1, ext: nil, generation: 1),
        ])
        let loaded = try await store.load(locationId: loc)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.fileExtension)
    }
}
