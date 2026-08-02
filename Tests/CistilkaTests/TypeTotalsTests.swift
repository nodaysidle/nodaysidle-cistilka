import XCTest
@testable import Cistilka

final class TypeTotalsTests: XCTestCase {
    func testTypeTotalsByExtension() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, name: "root", kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "p1", parentId: "root", locationId: loc, name: "a.png", kind: .file, byteSize: 100, itemCount: 1, ext: "png", generation: gen),
            .fixture(id: "p2", parentId: "root", locationId: loc, name: "b.png", kind: .file, byteSize: 200, itemCount: 1, ext: "png", generation: gen),
            .fixture(id: "m1", parentId: "root", locationId: loc, name: "c.mov", kind: .file, byteSize: 1000, itemCount: 1, ext: "mov", generation: gen),
        ], generation: gen)
        let totals = await index.typeTotals(scopeRootId: "root")
        XCTAssertEqual(totals.first?.fileExtension, "mov")
        XCTAssertEqual(totals.first?.bytes, 1000)
        XCTAssertEqual(totals.first?.count, 1)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[1].fileExtension, "png")
        XCTAssertEqual(totals[1].bytes, 300)
        XCTAssertEqual(totals[1].count, 2)
    }

    func testTypeTotalsScopeLimitsToSubtree() async {
        let index = ScanIndex()
        let loc = UUID()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", locationId: loc, kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "sub", parentId: "root", locationId: loc, kind: .folder, byteSize: 0, itemCount: 0, generation: gen),
            .fixture(id: "in", parentId: "sub", locationId: loc, kind: .file, byteSize: 10, itemCount: 1, ext: "a", generation: gen),
            .fixture(id: "out", parentId: "root", locationId: loc, kind: .file, byteSize: 999, itemCount: 1, ext: "b", generation: gen),
        ], generation: gen)
        let totals = await index.typeTotals(scopeRootId: "sub")
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.fileExtension, "a")
        XCTAssertEqual(totals.first?.bytes, 10)
    }

    func testTypeTotalsNilScopeUsesAllFiles() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "f1", kind: .file, byteSize: 5, ext: "txt", generation: gen),
            .fixture(id: "f2", kind: .file, byteSize: 7, ext: "txt", generation: gen),
        ], generation: gen)
        let totals = await index.typeTotals(scopeRootId: nil)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.fileExtension, "txt")
        XCTAssertEqual(totals.first?.count, 2)
        XCTAssertEqual(totals.first?.bytes, 12)
    }

    func testTypeTotalsNoExtensionBucket() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "f", kind: .file, byteSize: 3, ext: nil, generation: gen),
        ], generation: gen)
        let totals = await index.typeTotals(scopeRootId: nil)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.fileExtension, "(no extension)")
        XCTAssertEqual(totals.first?.bytes, 3)
    }

    func testTypeTotalsIgnoresFolders() async {
        let index = ScanIndex()
        let gen: UInt64 = 1
        await index.apply(batch: [
            .fixture(id: "root", kind: .folder, byteSize: 100, itemCount: 0, generation: gen),
            .fixture(id: "f", parentId: "root", kind: .file, byteSize: 10, itemCount: 1, ext: "x", generation: gen),
        ], generation: gen)
        let totals = await index.typeTotals(scopeRootId: "root")
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.fileExtension, "x")
        XCTAssertEqual(totals.first?.bytes, 10)
    }

    func testTypeTotalEquality() {
        let a = TypeTotal(fileExtension: "png", count: 2, bytes: 300)
        let b = TypeTotal(fileExtension: "png", count: 2, bytes: 300)
        XCTAssertEqual(a, b)
    }
}
