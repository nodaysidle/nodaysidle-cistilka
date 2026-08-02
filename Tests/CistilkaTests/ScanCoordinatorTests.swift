import XCTest
@testable import Cistilka

final class ScanCoordinatorTests: XCTestCase {
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistilka-coord-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL)
        }
        dbURL = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testAppliesBatchesIntoIndexFromFakeSource() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store)

        let locId = UUID()
        let location = ScanLocation(
            id: locId,
            sourceKind: .local,
            displayName: "Fake",
            rootRef: "/fake",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )

        let nodes: [StorageNode] = [
            .fixture(id: "root", locationId: locId, name: "root", kind: .folder, byteSize: 30, itemCount: 2, generation: 0),
            .fixture(id: "a", parentId: "root", locationId: locId, name: "a.txt", kind: .file, byteSize: 10, itemCount: 1, ext: "txt", generation: 0),
            .fixture(id: "b", parentId: "root", locationId: locId, name: "b.txt", kind: .file, byteSize: 20, itemCount: 1, ext: "txt", generation: 0),
        ]
        let source = FakeScanSource(batches: [
            [nodes[1], nodes[2]],
            [nodes[0]],
        ])

        var updatedStates: [ScanState] = []
        coordinator.onLocationUpdate = { updatedStates.append($0.scanState) }

        await coordinator.startScan(location: location, source: source, mode: .full)

        let root = await index.node(id: "root")
        let a = await index.node(id: "a")
        let b = await index.node(id: "b")
        XCTAssertEqual(root?.name, "root")
        XCTAssertEqual(a?.byteSize, 10)
        XCTAssertEqual(b?.byteSize, 20)
        XCTAssertEqual(root?.scanGeneration, 1)
        XCTAssertEqual(a?.scanGeneration, 1)

        XCTAssertTrue(updatedStates.contains(.scanning))
        XCTAssertEqual(updatedStates.last, .complete)

        let loaded = try await store.load(locationId: locId)
        XCTAssertEqual(loaded.count, 3)
    }

    @MainActor
    func testCancelStopsFurtherBatches() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store)

        let locId = UUID()
        let location = ScanLocation(
            id: locId,
            sourceKind: .local,
            displayName: "Slow",
            rootRef: "/slow",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )

        let batch1: [StorageNode] = [
            .fixture(id: "early", locationId: locId, name: "early", kind: .file, byteSize: 1, generation: 0),
        ]
        let batch2: [StorageNode] = [
            .fixture(id: "late", locationId: locId, name: "late", kind: .file, byteSize: 2, generation: 0),
        ]
        let source = FakeScanSource(
            batches: [batch1, batch2],
            delayBetweenBatches: .milliseconds(200),
            cancelAfterBatchCount: 1
        )

        var finalState: ScanState?
        coordinator.onLocationUpdate = { finalState = $0.scanState }

        let scanTask = Task {
            await coordinator.startScan(location: location, source: source, mode: .full)
        }

        // Wait until first batch is visible, then cancel.
        var sawEarly = false
        for _ in 0..<50 {
            if await index.node(id: "early") != nil {
                sawEarly = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawEarly, "expected first batch to land before cancel")

        coordinator.cancel(locationId: locId)
        await scanTask.value

        let early = await index.node(id: "early")
        let late = await index.node(id: "late")
        XCTAssertNotNil(early)
        XCTAssertNil(late, "second batch must not apply after cancel")
        XCTAssertEqual(finalState, .cancelled)
    }

    func testLocationStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cistilka-loc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LocationStore(directory: dir)
        let loc = ScanLocation(
            id: UUID(),
            sourceKind: .local,
            displayName: "Home",
            rootRef: "/Users/test",
            accountId: nil,
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scanState: .complete
        )
        try store.save([loc])
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, loc.id)
        XCTAssertEqual(loaded.first?.displayName, "Home")
        XCTAssertEqual(loaded.first?.scanState, .complete)
        XCTAssertEqual(loaded.first?.lastScannedAt?.timeIntervalSince1970, 1_700_000_000)
    }

    @MainActor
    func testConcurrentScanCapIsTwo() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store, maxConcurrent: 2)

        let gate = ConcurrentGate()
        var locations: [ScanLocation] = []
        var sources: [FakeScanSource] = []
        for i in 0..<3 {
            let id = UUID()
            locations.append(
                ScanLocation(
                    id: id,
                    sourceKind: .local,
                    displayName: "L\(i)",
                    rootRef: "/l\(i)",
                    accountId: nil,
                    lastScannedAt: nil,
                    scanState: .idle
                )
            )
            sources.append(
                FakeScanSource(
                    batches: [[.fixture(id: "n\(i)", locationId: id, name: "n\(i)", kind: .file, byteSize: 1, generation: 0)]],
                    delayBetweenBatches: .milliseconds(150),
                    concurrentGate: gate
                )
            )
        }

        async let a: Void = coordinator.startScan(location: locations[0], source: sources[0], mode: .full)
        async let b: Void = coordinator.startScan(location: locations[1], source: sources[1], mode: .full)
        async let c: Void = coordinator.startScan(location: locations[2], source: sources[2], mode: .full)

        // While scans are in flight, peak concurrency must never exceed 2.
        try await Task.sleep(for: .milliseconds(50))
        let peak = await gate.peakInFlight
        await a
        await b
        await c
        XCTAssertLessThanOrEqual(peak, 2)
        let finalPeak = await gate.peakInFlight
        XCTAssertLessThanOrEqual(finalPeak, 2)
    }

    /// complete gen1 → start gen2 → cancel gen2 → gen1 nodes still present
    @MainActor
    func testCancelRescanKeepsPreviousGenerationNodes() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store)

        let locId = UUID()
        let location = ScanLocation(
            id: locId,
            sourceKind: .local,
            displayName: "Rescan",
            rootRef: "/rescan",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )

        let gen1Nodes: [StorageNode] = [
            .fixture(id: "g1-root", locationId: locId, name: "g1-root", kind: .folder, byteSize: 10, itemCount: 1, generation: 0),
            .fixture(id: "g1-file", parentId: "g1-root", locationId: locId, name: "old.txt", kind: .file, byteSize: 10, itemCount: 1, ext: "txt", generation: 0),
        ]
        let source1 = FakeScanSource(batches: [gen1Nodes])
        await coordinator.startScan(location: location, source: source1, mode: .full)

        let afterGen1 = await index.node(id: "g1-root")
        XCTAssertNotNil(afterGen1)
        XCTAssertEqual(afterGen1?.scanGeneration, 1)

        let gen2Partial: [StorageNode] = [
            .fixture(id: "g2-early", locationId: locId, name: "new-early", kind: .file, byteSize: 5, generation: 0),
        ]
        let gen2Late: [StorageNode] = [
            .fixture(id: "g2-late", locationId: locId, name: "new-late", kind: .file, byteSize: 6, generation: 0),
        ]
        let source2 = FakeScanSource(
            batches: [gen2Partial, gen2Late],
            delayBetweenBatches: .milliseconds(200),
            cancelAfterBatchCount: 1
        )

        var finalState: ScanState?
        coordinator.onLocationUpdate = { finalState = $0.scanState }

        let scanTask = Task {
            await coordinator.startScan(location: location, source: source2, mode: .full)
        }

        var sawGen2 = false
        for _ in 0..<50 {
            if await index.node(id: "g2-early") != nil {
                sawGen2 = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawGen2, "expected incomplete gen2 batch before cancel")

        coordinator.cancel(locationId: locId)
        await scanTask.value

        // Previous generation retained; incomplete new generation discarded.
        let g1Root = await index.node(id: "g1-root")
        let g1File = await index.node(id: "g1-file")
        let g2Early = await index.node(id: "g2-early")
        let g2Late = await index.node(id: "g2-late")
        XCTAssertNotNil(g1Root, "gen1 nodes must survive cancelled rescan")
        XCTAssertNotNil(g1File)
        XCTAssertEqual(g1Root?.scanGeneration, 1)
        XCTAssertNil(g2Early, "incomplete gen2 nodes must be discarded")
        XCTAssertNil(g2Late)
        XCTAssertEqual(finalState, .cancelled)
    }

    /// complete gen1 → start A slow rescan → start B supersedes A → cancel B → gen1 nodes still present.
    /// Guards committed-generation bookkeeping when a superseded start abandons an in-flight gen.
    @MainActor
    func testSupersedeThenCancelKeepsCommittedGenerationNodes() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store)

        let locId = UUID()
        let location = ScanLocation(
            id: locId,
            sourceKind: .local,
            displayName: "Supersede",
            rootRef: "/supersede",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )

        let gen1Nodes: [StorageNode] = [
            .fixture(id: "s-g1-root", locationId: locId, name: "g1-root", kind: .folder, byteSize: 10, itemCount: 1, generation: 0),
            .fixture(id: "s-g1-file", parentId: "s-g1-root", locationId: locId, name: "kept.txt", kind: .file, byteSize: 10, itemCount: 1, ext: "txt", generation: 0),
        ]
        await coordinator.startScan(location: location, source: FakeScanSource(batches: [gen1Nodes]), mode: .full)
        let afterGen1 = await index.node(id: "s-g1-root")
        XCTAssertNotNil(afterGen1)
        XCTAssertEqual(afterGen1?.scanGeneration, 1)

        // A: slow multi-batch rescan (will be superseded mid-flight).
        let slowA = FakeScanSource(
            batches: [
                [.fixture(id: "s-a-early", locationId: locId, name: "a-early", kind: .file, byteSize: 1, generation: 0)],
                [.fixture(id: "s-a-late", locationId: locId, name: "a-late", kind: .file, byteSize: 2, generation: 0)],
            ],
            delayBetweenBatches: .milliseconds(250)
        )
        // B: also slow so we can cancel after it supersedes A.
        let slowB = FakeScanSource(
            batches: [
                [.fixture(id: "s-b-early", locationId: locId, name: "b-early", kind: .file, byteSize: 3, generation: 0)],
                [.fixture(id: "s-b-late", locationId: locId, name: "b-late", kind: .file, byteSize: 4, generation: 0)],
            ],
            delayBetweenBatches: .milliseconds(200),
            cancelAfterBatchCount: 1
        )

        var finalState: ScanState?
        coordinator.onLocationUpdate = { finalState = $0.scanState }

        async let startA: Void = coordinator.startScan(location: location, source: slowA, mode: .full)
        // Let A claim an in-flight generation, then supersede with B.
        try await Task.sleep(for: .milliseconds(80))
        let scanB = Task {
            await coordinator.startScan(location: location, source: slowB, mode: .full)
        }

        // Wait until B's first batch lands (A already cancelled/superseded).
        var sawB = false
        for _ in 0..<80 {
            if await index.node(id: "s-b-early") != nil {
                sawB = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawB, "expected B partial batch before cancel")

        coordinator.cancel(locationId: locId)
        await startA
        await scanB.value

        let g1Root = await index.node(id: "s-g1-root")
        let g1File = await index.node(id: "s-g1-file")
        let aEarly = await index.node(id: "s-a-early")
        let bEarly = await index.node(id: "s-b-early")
        let bLate = await index.node(id: "s-b-late")
        XCTAssertNotNil(g1Root, "committed gen1 must survive supersede-then-cancel of later rescans")
        XCTAssertNotNil(g1File)
        XCTAssertEqual(g1Root?.scanGeneration, 1)
        XCTAssertNil(aEarly, "abandoned A gen must be discarded")
        XCTAssertNil(bEarly, "cancelled B gen must be discarded")
        XCTAssertNil(bLate)
        XCTAssertEqual(finalState, .cancelled)
    }

    /// complete gen1 → complete gen2 → start B rescan → cancel B → gen2 retained (not stale gen1).
    /// Ensures committedGenerations advances on complete so later cancel discard keeps the latest tree.
    @MainActor
    func testSupersedeAfterCompleteKeepsCompletedGenerationNodes() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store)

        let locId = UUID()
        let location = ScanLocation(
            id: locId,
            sourceKind: .local,
            displayName: "CompleteRace",
            rootRef: "/complete-race",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )

        await coordinator.startScan(
            location: location,
            source: FakeScanSource(batches: [
                [.fixture(id: "cr-g1", locationId: locId, name: "g1", kind: .file, byteSize: 1, generation: 0)],
            ]),
            mode: .full
        )
        await coordinator.startScan(
            location: location,
            source: FakeScanSource(batches: [
                [.fixture(id: "cr-g2", locationId: locId, name: "g2", kind: .file, byteSize: 2, generation: 0)],
            ]),
            mode: .full
        )
        let afterGen2 = await index.node(id: "cr-g2")
        let afterGen1 = await index.node(id: "cr-g1")
        XCTAssertNotNil(afterGen2)
        XCTAssertNil(afterGen1)

        let slowB = FakeScanSource(
            batches: [
                [.fixture(id: "cr-b-early", locationId: locId, name: "b-early", kind: .file, byteSize: 3, generation: 0)],
                [.fixture(id: "cr-b-late", locationId: locId, name: "b-late", kind: .file, byteSize: 4, generation: 0)],
            ],
            delayBetweenBatches: .milliseconds(200),
            cancelAfterBatchCount: 1
        )
        let scanB = Task {
            await coordinator.startScan(location: location, source: slowB, mode: .full)
        }

        var sawB = false
        for _ in 0..<80 {
            if await index.node(id: "cr-b-early") != nil {
                sawB = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawB, "expected B partial before cancel")

        coordinator.cancel(locationId: locId)
        await scanB.value

        let g2 = await index.node(id: "cr-g2")
        let bEarly = await index.node(id: "cr-b-early")
        let bLate = await index.node(id: "cr-b-late")
        XCTAssertNotNil(g2, "completed gen2 must survive cancel of later rescan")
        XCTAssertEqual(g2?.scanGeneration, 2)
        XCTAssertNil(bEarly)
        XCTAssertNil(bLate)
    }

    /// Overlapping startScan for the same location must end as scanning/complete of the latest, not stuck cancelled.
    @MainActor
    func testOverlappingStartScanSameLocationLatestWins() async throws {
        let store = try SQLiteStore(url: dbURL)
        let index = ScanIndex()
        let coordinator = ScanCoordinator(index: index, store: store)

        let locId = UUID()
        let location = ScanLocation(
            id: locId,
            sourceKind: .local,
            displayName: "Overlap",
            rootRef: "/overlap",
            accountId: nil,
            lastScannedAt: nil,
            scanState: .idle
        )

        let slowSource = FakeScanSource(
            batches: [[.fixture(id: "slow", locationId: locId, name: "slow", kind: .file, byteSize: 1, generation: 0)]],
            delayBetweenBatches: .milliseconds(400)
        )
        let fastSource = FakeScanSource(
            batches: [[.fixture(id: "fast", locationId: locId, name: "fast", kind: .file, byteSize: 2, generation: 0)]],
            delayBetweenBatches: .milliseconds(50)
        )

        var states: [ScanState] = []
        coordinator.onLocationUpdate = { states.append($0.scanState) }

        async let first: Void = coordinator.startScan(location: location, source: slowSource, mode: .full)
        // Let first claim a slot / begin, then supersede with a second start.
        try await Task.sleep(for: .milliseconds(30))
        async let second: Void = coordinator.startScan(location: location, source: fastSource, mode: .full)

        await first
        await second

        let final = states.last
        XCTAssertTrue(
            final == .complete || final == .scanning,
            "latest startScan must not leave location stuck on superseded cancel; got \(String(describing: final))"
        )
        // Latest scan should complete successfully.
        XCTAssertEqual(final, .complete)
        let fastNode = await index.node(id: "fast")
        XCTAssertNotNil(fastNode)
        // Superseded slow scan must not leave us stuck cancelled from the superseded startScan.
        let all = await index.nodes(for: locId)
        XCTAssertTrue(all.contains { $0.id == "fast" })
        XCTAssertNotEqual(states.last, .cancelled, "must not end stuck cancelled from superseded startScan")
    }
}

// MARK: - Fakes

/// Test double that emits scripted batches with optional delay and cancel hooks.
struct FakeScanSource: ScanSource {
    var supportsTrash: Bool { false }

    var batches: [[StorageNode]]
    var delayBetweenBatches: Duration?
    /// When set, cancels the task after this many batches have been emitted.
    var cancelAfterBatchCount: Int?
    var concurrentGate: ConcurrentGate?

    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws {
        await concurrentGate?.enter()
        do {
            try await emitBatches(
                generation: generation,
                onBatch: onBatch,
                onProgress: onProgress
            )
            await concurrentGate?.leave()
        } catch {
            await concurrentGate?.leave()
            throw error
        }
    }

    private func emitBatches(
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws {
        var emitted = 0
        var files = 0
        for batch in batches {
            try Task.checkCancellation()
            if let delayBetweenBatches {
                try await Task.sleep(for: delayBetweenBatches)
            }
            try Task.checkCancellation()

            var tagged = batch
            for i in tagged.indices {
                tagged[i].scanGeneration = generation
            }
            await onBatch(tagged)
            files += tagged.count
            await onProgress(
                ScanProgress(
                    dirsVisited: 0,
                    filesVisited: files,
                    bytesSeen: tagged.reduce(0) { $0 + $1.byteSize },
                    currentPath: tagged.last?.logicalPath ?? ""
                )
            )
            emitted += 1
            if let cancelAfterBatchCount, emitted >= cancelAfterBatchCount {
                // Hold open so the test can cancel before the next batch.
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func trash(nodes: [StorageNode]) async throws -> [RemovalResult] {
        nodes.map { .failed(nodeId: $0.id, message: "fake") }
    }

    func reveal(node: StorageNode) async throws {}

    func resolveDisplayPath(node: StorageNode) -> String {
        node.logicalPath
    }
}

/// Tracks peak concurrent enumerate calls for cap tests.
actor ConcurrentGate {
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0

    func enter() {
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
    }

    func leave() {
        inFlight -= 1
    }
}
