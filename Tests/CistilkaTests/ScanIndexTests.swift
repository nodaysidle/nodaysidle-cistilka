import XCTest
@testable import Cistilka

final class ScanIndexTests: XCTestCase {
    func testAggregatesFolderSizeFromChildren() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "a", parentId: "root", locationId: loc, name: "a.txt", kind: .file, byteSize: 100, itemCount: 1, ext: "txt", generation: gen),
            .fixture(id: "b", parentId: "root", locationId: loc, name: "b.txt", kind: .file, byteSize: 50, itemCount: 1, ext: "txt", generation: gen),
        ], generation: gen)
        await index.finalizeDirectory(id: "root", byteSize: 150, itemCount: 2)
        let root = await index.node(id: "root")
        XCTAssertEqual(root?.byteSize, 150)
        XCTAssertEqual(root?.itemCount, 2)
    }

    func testChildrenSortedBySizeDescending() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "small", parentId: "root", locationId: loc, name: "small", kind: .file, byteSize: 10, itemCount: 1, generation: gen),
            .fixture(id: "big", parentId: "root", locationId: loc, name: "big", kind: .file, byteSize: 99, itemCount: 1, generation: gen),
        ], generation: gen)
        let kids = await index.children(of: "root")
        XCTAssertEqual(kids.map(\.id), ["big", "small"])
    }

    func testNodeLookup() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "x", name: "x", kind: .file, byteSize: 1, generation: gen),
        ], generation: gen)
        let found = await index.node(id: "x")
        XCTAssertEqual(found?.name, "x")
        let missing = await index.node(id: "nope")
        XCTAssertNil(missing)
    }

    func testReaggregateAncestorsBottomUp() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "dir", parentId: "root", locationId: loc, name: "dir", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "f", parentId: "dir", locationId: loc, name: "f.bin", kind: .file, byteSize: 40, itemCount: 1, ext: "bin", generation: gen),
        ], generation: gen)
        await index.reaggregateAncestors(from: "f")
        let dir = await index.node(id: "dir")
        let root = await index.node(id: "root")
        XCTAssertEqual(dir?.byteSize, 40)
        XCTAssertEqual(dir?.itemCount, 1)
        XCTAssertEqual(root?.byteSize, 40)
        XCTAssertEqual(root?.itemCount, 1)
    }

    func testRemoveUpdatesParentTotals() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "keep", parentId: "root", locationId: loc, name: "keep.txt", kind: .file, byteSize: 100, itemCount: 1, ext: "txt", generation: gen),
            .fixture(id: "gone", parentId: "root", locationId: loc, name: "gone.txt", kind: .file, byteSize: 50, itemCount: 1, ext: "txt", generation: gen),
        ], generation: gen)
        await index.finalizeDirectory(id: "root", byteSize: 150, itemCount: 2)
        await index.remove(ids: ["gone"])
        let root = await index.node(id: "root")
        XCTAssertEqual(root?.byteSize, 100)
        XCTAssertEqual(root?.itemCount, 1)
        let kids = await index.children(of: "root")
        XCTAssertEqual(kids.map(\.id), ["keep"])
        let gone = await index.node(id: "gone")
        XCTAssertNil(gone)
        let totals = await index.typeTotals(scopeRootId: "root")
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.fileExtension, "txt")
        XCTAssertEqual(totals.first?.count, 1)
        XCTAssertEqual(totals.first?.bytes, 100)
    }

    func testRemoveCascadesToDescendants() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "dir", parentId: "root", locationId: loc, kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "leaf", parentId: "dir", locationId: loc, kind: .file, byteSize: 20, itemCount: 1, ext: "dat", generation: gen),
        ], generation: gen)
        await index.reaggregateAncestors(from: "leaf")
        await index.remove(ids: ["dir"])
        let removedDir = await index.node(id: "dir")
        let removedLeaf = await index.node(id: "leaf")
        XCTAssertNil(removedDir)
        XCTAssertNil(removedLeaf)
        let root = await index.node(id: "root")
        XCTAssertEqual(root?.byteSize, 0)
        XCTAssertEqual(root?.itemCount, 0)
    }

    func testDiscardGenerationKeepsCurrentOnly() async {
        let index = ScanIndex()
        let loc = UUID()
        await index.apply(batch: [
            .fixture(id: "old", locationId: loc, name: "old", kind: .file, byteSize: 1, generation: 1),
        ], generation: 1)
        await index.apply(batch: [
            .fixture(id: "new", locationId: loc, name: "new", kind: .file, byteSize: 2, generation: 2),
        ], generation: 2)
        await index.discardGeneration(locationId: loc, keeping: 2)
        let old = await index.node(id: "old")
        let newNode = await index.node(id: "new")
        XCTAssertNil(old)
        XCTAssertNotNil(newNode)
    }

    func testDiscardGenerationIgnoresOtherLocations() async {
        let index = ScanIndex()
        let locA = UUID()
        let locB = UUID()
        await index.apply(batch: [
            .fixture(id: "a1", locationId: locA, kind: .file, byteSize: 1, generation: 1),
            .fixture(id: "b1", locationId: locB, kind: .file, byteSize: 1, generation: 1),
        ], generation: 1)
        await index.discardGeneration(locationId: locA, keeping: 99)
        let a1 = await index.node(id: "a1")
        let b1 = await index.node(id: "b1")
        XCTAssertNil(a1)
        XCTAssertNotNil(b1)
    }

    func testApplySetsScanGeneration() async {
        let index = ScanIndex()
        await index.apply(batch: [
            .fixture(id: "n", kind: .file, byteSize: 1, generation: 0),
        ], generation: 7)
        let n = await index.node(id: "n")
        XCTAssertEqual(n?.scanGeneration, 7)
    }

    func testForestRootsViaNilParent() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "r1", name: "r1", kind: .folder, byteSize: 5, itemCount: 0, generation: gen),
            .fixture(id: "r2", name: "r2", kind: .folder, byteSize: 50, itemCount: 0, generation: gen),
        ], generation: gen)
        let roots = await index.children(of: nil)
        XCTAssertEqual(roots.map(\.id), ["r2", "r1"])
    }
}
