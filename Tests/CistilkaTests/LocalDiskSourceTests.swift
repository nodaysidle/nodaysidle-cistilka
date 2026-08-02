import XCTest
@testable import Cistilka

final class LocalDiskSourceTests: XCTestCase {
    func testScansTempTreeSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("a.bin")
        try Data(repeating: 1, count: 4096).write(to: f)

        let source = LocalDiskSource()
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "t",
            rootRef: root.path,
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        try await source.enumerate(
            location: loc,
            generation: 1,
            onBatch: { await collector.append($0) },
            onProgress: { _ in }
        )
        let nodes = await collector.nodes
        XCTAssertTrue(nodes.contains { $0.name == "a.bin" && $0.byteSize >= 4096 })
    }

    func testDoesNotFollowSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realDir = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1024).write(to: realDir.appendingPathComponent("inside.bin"))

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

        let source = LocalDiskSource()
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "t",
            rootRef: root.path,
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        try await source.enumerate(
            location: loc,
            generation: 1,
            onBatch: { await collector.append($0) },
            onProgress: { _ in }
        )
        let nodes = await collector.nodes
        XCTAssertTrue(nodes.contains { $0.name == "link" && $0.nodeKind == .symlink })
        XCTAssertFalse(nodes.contains { $0.logicalPath.contains("link/inside.bin") })
    }

    func testPackagesAreLeaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Minimal bundle-like package structure marked as package via .app extension
        let app = root.appendingPathComponent("Dummy.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 2048).write(to: contents.appendingPathComponent("payload.bin"))

        let source = LocalDiskSource()
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "t",
            rootRef: root.path,
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        try await source.enumerate(
            location: loc,
            generation: 1,
            onBatch: { await collector.append($0) },
            onProgress: { _ in }
        )
        let nodes = await collector.nodes
        guard let pkg = nodes.first(where: { $0.name == "Dummy.app" }) else {
            XCTFail("expected package node Dummy.app")
            return
        }
        XCTAssertTrue(pkg.isPackage)
        XCTAssertEqual(pkg.nodeKind, .package)
        XCTAssertGreaterThanOrEqual(pkg.byteSize, 2048)
        // Children of package must not appear as separate tree nodes under the package path
        XCTAssertFalse(nodes.contains { $0.parentId == pkg.id })
    }

    func testPackagesExpandedWhenPreferNotLeaf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Dummy.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 2048).write(to: contents.appendingPathComponent("payload.bin"))

        let source = LocalDiskSource(treatPackagesAsLeaf: false, maxConcurrentListings: 2)
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "t",
            rootRef: root.path,
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        try await source.enumerate(
            location: loc,
            generation: 1,
            onBatch: { await collector.append($0) },
            onProgress: { _ in }
        )
        let nodes = await collector.nodes
        guard let pkg = nodes.first(where: { $0.name == "Dummy.app" }) else {
            XCTFail("expected package node Dummy.app")
            return
        }
        XCTAssertTrue(pkg.isPackage)
        // Contents should appear under the package when expanded.
        XCTAssertTrue(nodes.contains { $0.name == "Contents" && $0.parentId == pkg.id })
        XCTAssertTrue(nodes.contains { $0.name == "payload.bin" })
    }

    func testTrashMovesFileOutOfOriginalPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("trash-me.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let node = StorageNode.fixture(
            id: file.path,
            name: "trash-me.txt",
            kind: .file,
            logicalPath: file.path,
            byteSize: 5,
            itemCount: 1
        )
        let source = LocalDiskSource()
        let results = try await source.trash(nodes: [node])
        XCTAssertEqual(results, [.movedToTrash(nodeId: file.path)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testResolveDisplayPathUsesLogicalPath() {
        let node = StorageNode.fixture(
            id: "/tmp/x",
            name: "x",
            logicalPath: "/tmp/x"
        )
        XCTAssertEqual(LocalDiskSource().resolveDisplayPath(node: node), "/tmp/x")
    }

    func testSupportsTrash() {
        XCTAssertTrue(LocalDiskSource().supportsTrash)
    }

    func testUnreadableSubdirectoryDoesNotFailScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            // Restore perms so cleanup can delete.
            let locked = root.appendingPathComponent("locked")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        try Data(repeating: 1, count: 512).write(to: root.appendingPathComponent("ok.bin"))
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 256).write(to: locked.appendingPathComponent("secret.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let source = LocalDiskSource()
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "t",
            rootRef: root.path,
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        // Must complete without throwing.
        try await source.enumerate(
            location: loc,
            generation: 1,
            onBatch: { await collector.append($0) },
            onProgress: { _ in }
        )
        let nodes = await collector.nodes
        XCTAssertTrue(nodes.contains { $0.name == "ok.bin" })
        XCTAssertTrue(nodes.contains { $0.name == "locked" })
    }

    func testFolderAggregatesChildSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: sub.appendingPathComponent("a.bin"))
        try Data(repeating: 1, count: 2000).write(to: sub.appendingPathComponent("b.bin"))

        let source = LocalDiskSource()
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "t",
            rootRef: root.path,
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        try await source.enumerate(
            location: loc,
            generation: 1,
            onBatch: { await collector.append($0) },
            onProgress: { _ in }
        )
        let nodes = await collector.nodes
        // Prefer last occurrence if folder was emitted more than once (running vs final)
        let subNodes = nodes.filter { $0.name == "sub" && $0.nodeKind == .folder }
        XCTAssertFalse(subNodes.isEmpty)
        let subNode = subNodes.last!
        XCTAssertGreaterThanOrEqual(subNode.byteSize, 3000)
        XCTAssertEqual(subNode.itemCount, 2)
    }
}

/// Thread-safe batch collector for concurrent onBatch callbacks.
private actor NodeCollector {
    private var storage: [StorageNode] = []

    func append(_ batch: [StorageNode]) {
        storage.append(contentsOf: batch)
    }

    var nodes: [StorageNode] { storage }
}
