import Crypto
import Foundation
import NIOSSH
import XCTest
@testable import Cistilka

final class SSHSourceTests: XCTestCase {
    func testHostKeyFingerprintIsStableSHA256OfWireKey() throws {
        let key = try Self.makeEd25519PublicKey(seedByte: 0x42)
        let a = CitadelSFTPBridge.fingerprint(for: key)
        let b = CitadelSFTPBridge.fingerprint(for: key)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("SHA256:"))
        XCTAssertEqual(a.count, "SHA256:".count + 64)
        XCTAssertNotEqual(a, String(describing: key))

        let other = try Self.makeEd25519PublicKey(seedByte: 0x99)
        XCTAssertNotEqual(a, CitadelSFTPBridge.fingerprint(for: other))

        let again = try Self.makeEd25519PublicKey(seedByte: 0x42)
        XCTAssertEqual(a, CitadelSFTPBridge.fingerprint(for: again))
    }

    /// Deterministic ed25519 host key from a fixed seed (OpenSSH public key format).
    private static func makeEd25519PublicKey(seedByte: UInt8) throws -> NIOSSHPublicKey {
        let seed = Data(repeating: seedByte, count: 32)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let algo = Array("ssh-ed25519".utf8)
        let raw = Array(privateKey.publicKey.rawRepresentation)
        var blob = Data()
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(algo.count).bigEndian, Array.init))
        blob.append(contentsOf: algo)
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(raw.count).bigEndian, Array.init))
        blob.append(contentsOf: raw)
        let openSSHString = "ssh-ed25519 \(blob.base64EncodedString())"
        return try NIOSSHPublicKey(openSSHPublicKey: openSSHString)
    }

    func testEnumerateBuildsTreeWithSizes() async throws {
        let fake = FakeSFTPClient.withTree([
            (path: "/data", isDirectory: true, size: 0),
            (path: "/data/a.txt", isDirectory: false, size: 100),
            (path: "/data/sub", isDirectory: true, size: 0),
            (path: "/data/sub/b.bin", isDirectory: false, size: 50),
        ])
        let profile = SSHProfile(
            displayName: "Data",
            host: "h",
            username: "u",
            remotePath: "/data"
        )
        let source = SSHSource(profile: profile, clientFactory: { fake })
        let location = ScanLocation(
            id: UUID(),
            sourceKind: .ssh,
            displayName: "Data",
            rootRef: profile.rootRef,
            accountId: profile.id.uuidString,
            lastScannedAt: nil,
            scanState: .idle
        )

        let collector = NodeBatchCollector()
        try await source.enumerate(
            location: location,
            generation: 1,
            onBatch: { batch in await collector.append(batch) },
            onProgress: { _ in }
        )

        let all = await collector.nodes
        let byPath = Dictionary(uniqueKeysWithValues: all.map { ($0.logicalPath, $0) })
        XCTAssertNotNil(byPath["/data"])
        XCTAssertEqual(byPath["/data"]?.byteSize, 150)
        XCTAssertEqual(byPath["/data"]?.itemCount, 2)
        XCTAssertEqual(byPath["/data/a.txt"]?.byteSize, 100)
        XCTAssertEqual(byPath["/data/sub/b.bin"]?.byteSize, 50)
        XCTAssertEqual(byPath["/data/a.txt"]?.remoteId, "/data/a.txt")
        XCTAssertEqual(byPath["/data/a.txt"]?.fileExtension, "txt")
    }

    func testTrashRenamesIntoRemoteTrashPath() async throws {
        let fake = FakeSFTPClient.withTree([
            (path: "/data", isDirectory: true, size: 0),
            (path: "/data/gone.txt", isDirectory: false, size: 10),
            (path: "/.trash", isDirectory: true, size: 0),
        ])
        let profile = SSHProfile(
            displayName: "Data",
            host: "h",
            username: "u",
            remotePath: "/data",
            remoteTrashPath: "/.trash"
        )
        let source = SSHSource(profile: profile, clientFactory: { fake })
        let node = StorageNode.fixture(
            id: "n1",
            name: "gone.txt",
            kind: .file,
            logicalPath: "/data/gone.txt",
            byteSize: 10,
            remoteId: "/data/gone.txt"
        )
        let results = try await source.trash(nodes: [node])
        XCTAssertEqual(results, [.movedToTrash(nodeId: "n1")])

        // Original gone; something under trash.
        do {
            _ = try await fake.getAttributes(at: "/data/gone.txt")
            XCTFail("expected path removed")
        } catch {
            // expected
        }
        let trashKids = try await fake.listDirectory(at: "/.trash")
        XCTAssertEqual(trashKids.count, 1)
        XCTAssertTrue(trashKids[0].name.contains("gone.txt"))
    }

    func testTrashWithoutPathBlockedUnlessAllowPermanent() async throws {
        let fake = FakeSFTPClient.withTree([
            (path: "/data/x", isDirectory: false, size: 1),
        ])
        let profile = SSHProfile(
            displayName: "Data",
            host: "h",
            username: "u",
            remotePath: "/data",
            remoteTrashPath: nil
        )
        let blocked = SSHSource(
            profile: profile,
            allowPermanentDelete: false,
            clientFactory: { fake }
        )
        let node = StorageNode.fixture(
            id: "x",
            name: "x",
            remoteId: "/data/x"
        )
        let failed = try await blocked.trash(nodes: [node])
        guard case .failed = failed[0] else {
            return XCTFail("expected failure without allowPermanentDelete")
        }
        // Still present
        _ = try await fake.getAttributes(at: "/data/x")

        let allowed = SSHSource(
            profile: profile,
            allowPermanentDelete: true,
            clientFactory: { fake }
        )
        let ok = try await allowed.trash(nodes: [node])
        XCTAssertEqual(ok, [.movedToTrash(nodeId: "x")])
    }

    func testRequiresPermanentDeleteConfirmFlag() {
        let withTrash = SSHSource(
            profile: SSHProfile(
                displayName: "a",
                host: "h",
                username: "u",
                remoteTrashPath: "/t"
            ),
            clientFactory: { FakeSFTPClient() }
        )
        XCTAssertFalse(withTrash.requiresPermanentDeleteConfirm)

        let without = SSHSource(
            profile: SSHProfile(
                displayName: "a",
                host: "h",
                username: "u",
                remoteTrashPath: nil
            ),
            clientFactory: { FakeSFTPClient() }
        )
        XCTAssertTrue(without.requiresPermanentDeleteConfirm)
    }
}

private actor NodeBatchCollector {
    private(set) var nodes: [StorageNode] = []
    func append(_ batch: [StorageNode]) {
        nodes.append(contentsOf: batch)
    }
}
