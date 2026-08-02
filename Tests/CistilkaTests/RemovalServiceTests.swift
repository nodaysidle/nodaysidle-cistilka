import XCTest
@testable import Cistilka

final class RemovalServiceTests: XCTestCase {
    @MainActor
    func testPerformTrashCallsSourceAndRemovesFromIndex() async throws {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(
                id: "keep",
                parentId: "root",
                locationId: loc,
                name: "keep.txt",
                kind: .file,
                byteSize: 100,
                itemCount: 1,
                ext: "txt",
                generation: gen
            ),
            .fixture(
                id: "gone",
                parentId: "root",
                locationId: loc,
                name: "gone.txt",
                kind: .file,
                byteSize: 50,
                itemCount: 1,
                ext: "txt",
                generation: gen
            ),
        ], generation: gen)
        await index.finalizeDirectory(id: "root", byteSize: 150, itemCount: 2)

        let mock = MockTrashSource()
        let service = RemovalService(index: index)
        let gone = await index.node(id: "gone")!
        let results = await service.performTrash(nodes: [gone], source: mock)

        XCTAssertEqual(results, [.movedToTrash(nodeId: "gone")])
        XCTAssertEqual(mock.trashedIDs, [["gone"]])

        let removed = await index.node(id: "gone")
        XCTAssertNil(removed)
        let keep = await index.node(id: "keep")
        XCTAssertNotNil(keep)

        let root = await index.node(id: "root")
        XCTAssertEqual(root?.byteSize, 100)
        XCTAssertEqual(root?.itemCount, 1)

        let totals = await index.typeTotals(scopeRootId: "root")
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.bytes, 100)
        XCTAssertEqual(totals.first?.count, 1)
    }

    @MainActor
    func testPerformTrashLeavesFailedNodesInIndex() async throws {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "ok", name: "ok.txt", kind: .file, byteSize: 10, generation: gen),
            .fixture(id: "bad", name: "bad.txt", kind: .file, byteSize: 20, generation: gen),
        ], generation: gen)

        let mock = MockTrashSource()
        mock.failIDs = ["bad"]

        let service = RemovalService(index: index)
        let ok = await index.node(id: "ok")
        let bad = await index.node(id: "bad")
        XCTAssertNotNil(ok)
        XCTAssertNotNil(bad)
        let results = await service.performTrash(nodes: [ok!, bad!], source: mock)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], .movedToTrash(nodeId: "ok"))
        XCTAssertEqual(results[1], .failed(nodeId: "bad", message: "denied"))
        let okNode = await index.node(id: "ok")
        let badNode = await index.node(id: "bad")
        XCTAssertNil(okNode)
        XCTAssertNotNil(badNode)
    }

    @MainActor
    func testRequestTrashSetsPendingConfirmation() {
        let index = ScanIndex()
        let service = RemovalService(index: index)
        let mock = MockTrashSource()
        let nodes = [
            StorageNode.fixture(id: "a", name: "a", byteSize: 40),
            StorageNode.fixture(id: "b", name: "b", byteSize: 60),
        ]

        XCTAssertNil(service.pendingTrash)
        // Give parentId so these are not scan roots (root warning is tested separately).
        let withParents = nodes.map {
            StorageNode.fixture(id: $0.id, parentId: "root", name: $0.name, byteSize: $0.byteSize)
        }
        service.requestTrash(nodes: withParents, source: mock)

        let pending = service.pendingTrash
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(pending?.totalBytes, 100)
        XCTAssertEqual(pending?.itemCount, 2)
        XCTAssertEqual(
            pending?.confirmationMessage,
            "Move 2 items (\(ByteFormat.string(bytes: 100))) from This Mac to Trash?"
        )
        XCTAssertEqual(pending?.requiresStrongConfirm, false)
        XCTAssertEqual(pending?.sourceKindToken, .local)
        XCTAssertEqual(pending?.includesScanRoot, false)
    }

    @MainActor
    func testTrashableNodesFiltersDenied() {
        let ok = StorageNode.fixture(id: "ok", permissionsState: .ok)
        let denied = StorageNode.fixture(id: "no", permissionsState: .denied)
        let partial = StorageNode.fixture(id: "part", permissionsState: .partial)
        let filtered = RemovalService.trashableNodes(from: [ok, denied, partial])
        XCTAssertEqual(filtered.map(\.id), ["ok", "part"])
        XCTAssertFalse(RemovalService.isTrashable(denied))
        XCTAssertTrue(RemovalService.isTrashable(ok))
    }

    @MainActor
    func testRequestTrashSkipsDeniedNodes() {
        let service = RemovalService(index: ScanIndex())
        let mock = MockTrashSource()
        service.requestTrash(
            nodes: [
                StorageNode.fixture(id: "ok", name: "ok", byteSize: 10, permissionsState: .ok),
                StorageNode.fixture(id: "no", name: "no", byteSize: 99, permissionsState: .denied),
            ],
            source: mock
        )
        XCTAssertEqual(service.pendingTrash?.nodes.map(\.id), ["ok"])
        XCTAssertEqual(service.pendingTrash?.totalBytes, 10)
    }

    @MainActor
    func testRequestTrashAllDeniedDoesNotPresent() {
        let service = RemovalService(index: ScanIndex())
        service.requestTrash(
            nodes: [StorageNode.fixture(id: "no", permissionsState: .denied)],
            source: MockTrashSource()
        )
        XCTAssertNil(service.pendingTrash)
    }

    @MainActor
    func testRequestTrashGroupedQueuesBySourceKind() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "local-a", name: "a", byteSize: 1, generation: gen),
            .fixture(id: "ssh-b", name: "b", byteSize: 2, remoteId: "/b", generation: gen),
        ], generation: gen)

        let service = RemovalService(index: index)
        let local = MockTrashSource()
        let profile = SSHProfile(
            displayName: "box",
            host: "example.com",
            username: "u",
            remotePath: "/data",
            remoteTrashPath: "/.trash"
        )
        let ssh = SSHSource(profile: profile, clientFactory: { FakeSFTPClient() })

        service.requestTrashGrouped(groups: [
            (nodes: [StorageNode.fixture(id: "ssh-b", name: "b", byteSize: 2, remoteId: "/b")], source: ssh),
            (nodes: [StorageNode.fixture(id: "local-a", name: "a", byteSize: 1)], source: local),
        ])

        // Local first (kind order), then SSH remains queued.
        XCTAssertEqual(service.pendingTrash?.sourceKindToken, .local)
        XCTAssertEqual(service.pendingTrash?.nodes.map(\.id), ["local-a"])
        XCTAssertEqual(service.pendingTrash?.remainingGroupCount, 1)
        XCTAssertTrue(service.pendingTrash?.detailMessage?.contains("1 more source group") == true)

        _ = await service.confirmPending()
        XCTAssertEqual(service.pendingTrash?.sourceKindToken, .ssh)
        XCTAssertEqual(service.pendingTrash?.nodes.map(\.id), ["ssh-b"])
        XCTAssertEqual(service.pendingTrash?.remainingGroupCount, 0)

        service.cancelPending()
        XCTAssertNil(service.pendingTrash)
    }

    @MainActor
    func testRequestTrashGroupedSkipsUnsupportedSource() {
        let service = RemovalService(index: ScanIndex())
        let unsupported = MockTrashSource()
        unsupported.supportsTrash = false
        let ok = MockTrashSource()
        service.requestTrashGrouped(groups: [
            (nodes: [StorageNode.fixture(id: "x", byteSize: 1)], source: unsupported),
            (nodes: [StorageNode.fixture(id: "y", byteSize: 2)], source: ok),
        ])
        XCTAssertEqual(service.pendingTrash?.nodes.map(\.id), ["y"])
        XCTAssertEqual(service.pendingTrash?.remainingGroupCount, 0)
    }

    @MainActor
    func testSSHWithoutTrashPathRequiresStrongConfirm() {
        let index = ScanIndex()
        let service = RemovalService(index: index)
        let profile = SSHProfile(
            displayName: "box",
            host: "example.com",
            username: "u",
            remotePath: "/data",
            remoteTrashPath: nil
        )
        let source = SSHSource(profile: profile, clientFactory: { FakeSFTPClient() })
        service.requestTrash(
            nodes: [StorageNode.fixture(id: "r", name: "r", byteSize: 10, remoteId: "/data/r")],
            source: source
        )
        XCTAssertEqual(service.pendingTrash?.requiresStrongConfirm, true)
        XCTAssertTrue(service.pendingTrash?.confirmationMessage.contains("Permanently delete") == true)
    }

    @MainActor
    func testSSHWithTrashPathDoesNotRequireStrongConfirm() {
        let service = RemovalService(index: ScanIndex())
        let profile = SSHProfile(
            displayName: "box",
            host: "example.com",
            username: "u",
            remotePath: "/data",
            remoteTrashPath: "/.trash"
        )
        let source = SSHSource(profile: profile, clientFactory: { FakeSFTPClient() })
        service.requestTrash(
            nodes: [StorageNode.fixture(id: "r", name: "r", byteSize: 10)],
            source: source
        )
        XCTAssertEqual(service.pendingTrash?.requiresStrongConfirm, false)
    }

    @MainActor
    func testRequestTrashIgnoresEmptySelection() {
        let service = RemovalService(index: ScanIndex())
        service.requestTrash(nodes: [], source: MockTrashSource())
        XCTAssertNil(service.pendingTrash)
    }

    @MainActor
    func testConfirmPendingPerformsTrashAndClearsPending() async throws {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "x", name: "x.bin", kind: .file, byteSize: 8, generation: gen),
        ], generation: gen)

        let mock = MockTrashSource()
        let service = RemovalService(index: index)
        let node = await index.node(id: "x")!
        service.requestTrash(nodes: [node], source: mock)

        let results = await service.confirmPending()
        XCTAssertEqual(results, [.movedToTrash(nodeId: "x")])
        XCTAssertNil(service.pendingTrash)
        XCTAssertEqual(mock.trashedIDs, [["x"]])
        let xNode = await index.node(id: "x")
        XCTAssertNil(xNode)
    }

    @MainActor
    func testCancelPendingDoesNotTrash() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "y", name: "y", kind: .file, byteSize: 1, generation: gen),
        ], generation: gen)

        let mock = MockTrashSource()
        let service = RemovalService(index: index)
        service.requestTrash(nodes: [await index.node(id: "y")!], source: mock)
        service.cancelPending()

        XCTAssertNil(service.pendingTrash)
        XCTAssertTrue(mock.trashedIDs.isEmpty)
        let yNode = await index.node(id: "y")
        XCTAssertNotNil(yNode)
    }

    @MainActor
    func testConfirmMessageSingular() {
        let service = RemovalService(index: ScanIndex())
        let mock = MockTrashSource()
        // Non-root (has parent) so message is the simple form.
        service.requestTrash(
            nodes: [StorageNode.fixture(id: "one", parentId: "root", name: "one", byteSize: 1024)],
            source: mock
        )
        XCTAssertEqual(
            service.pendingTrash?.confirmationMessage,
            "Move 1 item (\(ByteFormat.string(bytes: 1024))) from This Mac to Trash?"
        )
        XCTAssertEqual(service.pendingTrash?.includesScanRoot, false)
    }

    @MainActor
    func testPerformTrashPersistsRemainingNodesToSQLite() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistilka-trash-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("index.sqlite")
        let store = try SQLiteStore(url: dbURL)

        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        let batch: [StorageNode] = [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 150, itemCount: 2, generation: gen),
            .fixture(
                id: "keep",
                parentId: "root",
                locationId: loc,
                name: "keep.txt",
                kind: .file,
                byteSize: 100,
                itemCount: 1,
                ext: "txt",
                generation: gen
            ),
            .fixture(
                id: "gone",
                parentId: "root",
                locationId: loc,
                name: "gone.txt",
                kind: .file,
                byteSize: 50,
                itemCount: 1,
                ext: "txt",
                generation: gen
            ),
        ]
        await index.apply(batch: batch, generation: gen)
        try await store.save(nodes: batch)

        let mock = MockTrashSource()
        let service = RemovalService(index: index, store: store)
        let gone = await index.node(id: "gone")!
        _ = await service.performTrash(nodes: [gone], source: mock)

        // Fresh store load must not include the trashed node.
        let reloaded = try SQLiteStore(url: dbURL)
        let loaded = try await reloaded.load(locationId: loc)
        XCTAssertFalse(loaded.contains { $0.id == "gone" })
        XCTAssertTrue(loaded.contains { $0.id == "keep" })
        XCTAssertTrue(loaded.contains { $0.id == "root" })
        // Root reaggregated in index should be reflected after save.
        let root = loaded.first { $0.id == "root" }
        XCTAssertEqual(root?.byteSize, 100)
        XCTAssertEqual(root?.itemCount, 1)
    }

    @MainActor
    func testRequestTrashScanRootAddsWarning() {
        let service = RemovalService(index: ScanIndex())
        let mock = MockTrashSource()
        // parentId == nil → forest / scan root
        service.requestTrash(
            nodes: [StorageNode.fixture(id: "scan-root", parentId: nil, name: "Home", byteSize: 999)],
            source: mock
        )
        let pending = service.pendingTrash
        XCTAssertEqual(pending?.includesScanRoot, true)
        XCTAssertTrue(pending?.confirmationMessage.contains("scan root") == true)
        XCTAssertTrue(pending?.detailMessage?.contains("scan root") == true)
    }

    @MainActor
    func testRequestTrashNonRootDoesNotFlagScanRoot() {
        let service = RemovalService(index: ScanIndex())
        service.requestTrash(
            nodes: [StorageNode.fixture(id: "child", parentId: "root", name: "f", byteSize: 1)],
            source: MockTrashSource()
        )
        XCTAssertEqual(service.pendingTrash?.includesScanRoot, false)
        XCTAssertFalse(service.pendingTrash?.confirmationMessage.contains("scan root") == true)
    }
}

// MARK: - Mock

/// Records trash calls; optional fail set for mixed success/failure results.
final class MockTrashSource: ScanSource, @unchecked Sendable {
    var supportsTrash: Bool = true
    private(set) var trashedIDs: [[String]] = []
    /// Node IDs that should return `.failed` instead of trash success.
    var failIDs: Set<String> = []
    var throwOnTrash: Error?

    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws {}

    func trash(nodes: [StorageNode]) async throws -> [RemovalResult] {
        trashedIDs.append(nodes.map(\.id))
        if let throwOnTrash { throw throwOnTrash }
        return nodes.map { node in
            if failIDs.contains(node.id) {
                return .failed(nodeId: node.id, message: "denied")
            }
            return .movedToTrash(nodeId: node.id)
        }
    }

    func reveal(node: StorageNode) async throws {}

    func resolveDisplayPath(node: StorageNode) -> String {
        node.logicalPath
    }
}
