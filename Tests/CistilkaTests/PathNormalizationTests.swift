import XCTest
@testable import Cistilka

final class PathNormalizationTests: XCTestCase {
    func testEmptyBecomesRoot() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("   "), "/")
    }

    func testRelativeBecomesAbsolute() {
        XCTAssertEqual(RemotePath.normalize("home/user"), "/home/user")
        XCTAssertEqual(RemotePath.normalize("var"), "/var")
    }

    func testCollapseSlashes() {
        XCTAssertEqual(RemotePath.normalize("//home///user//"), "/home/user")
        XCTAssertEqual(RemotePath.normalize("/a//b/c/"), "/a/b/c")
    }

    func testResolveDotSegments() {
        XCTAssertEqual(RemotePath.normalize("/home/./user"), "/home/user")
        XCTAssertEqual(RemotePath.normalize("/././x"), "/x")
        XCTAssertEqual(RemotePath.normalize("/a/b/."), "/a/b")
    }

    func testResolveParentSegments() {
        XCTAssertEqual(RemotePath.normalize("/home/user/../docs"), "/home/docs")
        XCTAssertEqual(RemotePath.normalize("/a/b/../../c"), "/c")
        XCTAssertEqual(RemotePath.normalize("/../x"), "/x")
        XCTAssertEqual(RemotePath.normalize("/.."), "/")
    }

    func testRootStable() {
        XCTAssertEqual(RemotePath.normalize("/"), "/")
        XCTAssertEqual(RemotePath.normalize("///"), "/")
    }

    func testJoin() {
        XCTAssertEqual(RemotePath.join("/home", "user"), "/home/user")
        XCTAssertEqual(RemotePath.join("/", "etc"), "/etc")
        XCTAssertEqual(RemotePath.join("/var/", "/log"), "/var/log")
        XCTAssertEqual(RemotePath.join("/a/b", "."), "/a/b")
    }

    func testLastComponentAndParent() {
        XCTAssertEqual(RemotePath.lastComponent("/home/user/file.txt"), "file.txt")
        XCTAssertEqual(RemotePath.lastComponent("/"), "/")
        XCTAssertEqual(RemotePath.parent("/home/user/file.txt"), "/home/user")
        XCTAssertEqual(RemotePath.parent("/home"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
    }

    func testSSHProfileRootRef() {
        let p = SSHProfile(
            displayName: "lab",
            host: "lab.local",
            port: 22,
            username: "arch",
            remotePath: "data/./proj//"
        )
        XCTAssertEqual(p.rootRef, "arch@lab.local:/data/proj")

        let nonDefault = SSHProfile(
            displayName: "lab",
            host: "lab.local",
            port: 2222,
            username: "arch",
            remotePath: "/tmp"
        )
        XCTAssertEqual(nonDefault.rootRef, "arch@lab.local#2222:/tmp")
    }
}
