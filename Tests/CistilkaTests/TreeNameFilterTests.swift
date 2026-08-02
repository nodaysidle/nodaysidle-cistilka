import XCTest
@testable import Cistilka

final class TreeNameFilterTests: XCTestCase {
    func testEmptyQueryReturnsAll() {
        let nodes: [StorageNode] = [
            .fixture(id: "a", name: "Alpha"),
            .fixture(id: "b", name: "Beta"),
        ]
        XCTAssertEqual(TreeNameFilter.filter(nodes: nodes, query: "").count, 2)
        XCTAssertEqual(TreeNameFilter.filter(nodes: nodes, query: "   ").count, 2)
    }

    func testCaseInsensitiveSubstring() {
        let nodes: [StorageNode] = [
            .fixture(id: "a", name: "Report.pdf"),
            .fixture(id: "b", name: "photo.JPG"),
            .fixture(id: "c", name: "notes.txt"),
        ]
        let filtered = TreeNameFilter.filter(nodes: nodes, query: "photo")
        XCTAssertEqual(filtered.map(\.id), ["b"])

        let pdf = TreeNameFilter.filter(nodes: nodes, query: "PDF")
        XCTAssertEqual(pdf.map(\.id), ["a"])
    }
}
