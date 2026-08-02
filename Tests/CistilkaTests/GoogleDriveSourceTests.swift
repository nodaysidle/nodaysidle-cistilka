import XCTest
@testable import Cistilka

// MARK: - URLProtocol mock

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class GoogleDriveSourceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        MockURLProtocol.handler = nil
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    // MARK: Parser

    func testParseListResponseMapsFilesAndFolders() throws {
        let json = """
        {
          "files": [
            {
              "id": "file1",
              "name": "report.pdf",
              "mimeType": "application/pdf",
              "size": "2048",
              "parents": ["root"],
              "modifiedTime": "2024-06-01T12:00:00.000Z"
            },
            {
              "id": "folder1",
              "name": "Photos",
              "mimeType": "application/vnd.google-apps.folder",
              "parents": ["root"]
            }
          ],
          "nextPageToken": "page2"
        }
        """.data(using: .utf8)!

        let page = try GoogleDriveSource.parseListResponse(data: json)
        XCTAssertEqual(page.files.count, 2)
        XCTAssertEqual(page.nextPageToken, "page2")

        let pdf = page.files[0]
        XCTAssertEqual(pdf.id, "file1")
        XCTAssertEqual(pdf.name, "report.pdf")
        XCTAssertEqual(pdf.byteSize, 2048)
        XCTAssertFalse(pdf.isFolder)

        let folder = page.files[1]
        XCTAssertEqual(folder.id, "folder1")
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.byteSize, 0)
    }

    func testMapFileSetsRemoteIdAndExtension() {
        let locationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let file = DriveFileDTO(
            id: "abc",
            name: "notes.txt",
            mimeType: "text/plain",
            size: "10",
            parents: ["root"],
            modifiedTime: nil
        )
        let node = GoogleDriveSource.mapFile(
            file,
            parentNodeId: "\(locationId.uuidString)/root",
            locationId: locationId,
            logicalPath: "/My Drive/notes.txt",
            generation: 3
        )
        XCTAssertEqual(node.remoteId, "abc")
        XCTAssertEqual(node.fileExtension, "txt")
        XCTAssertEqual(node.byteSize, 10)
        XCTAssertEqual(node.nodeKind, .file)
        XCTAssertEqual(node.scanGeneration, 3)
    }

    // MARK: Enumerate via mock

    func testEnumerateListsRootChildren() async throws {
        let locationId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let location = ScanLocation(
            id: locationId,
            sourceKind: .googleDrive,
            displayName: "Google Drive",
            rootRef: "root",
            accountId: "user@example.com",
            lastScannedAt: nil,
            scanState: .idle
        )

        let listJSON = """
        {
          "files": [
            {
              "id": "f1",
              "name": "a.pdf",
              "mimeType": "application/pdf",
              "size": "100",
              "parents": ["root"]
            },
            {
              "id": "d1",
              "name": "Docs",
              "mimeType": "application/vnd.google-apps.folder",
              "parents": ["root"]
            }
          ]
        }
        """.data(using: .utf8)!

        let emptyFolderJSON = """
        { "files": [] }
        """.data(using: .utf8)!

        MockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            // Only files.list GETs.
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(url.absoluteString.contains("www.googleapis.com/drive/v3/files"))

            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = query.first(where: { $0.name == "q" })?.value ?? ""
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if q.contains("'root' in parents") {
                return (response, listJSON)
            }
            if q.contains("'d1' in parents") {
                return (response, emptyFolderJSON)
            }
            return (response, emptyFolderJSON)
        }

        let source = GoogleDriveSource(
            accessTokenProvider: { _ in "test-token" },
            session: session,
            rootParentId: "root",
            rootDisplayName: "My Drive"
        )

        let collector = NodeCollector()
        try await source.enumerate(
            location: location,
            generation: 1,
            onBatch: { batch in
                await collector.append(batch)
            },
            onProgress: { _ in }
        )

        let collected = await collector.nodes
        let names = Set(collected.map(\.name))
        XCTAssertTrue(names.contains("My Drive"))
        XCTAssertTrue(names.contains("a.pdf"))
        XCTAssertTrue(names.contains("Docs"))

        let pdf = collected.first { $0.name == "a.pdf" }
        XCTAssertEqual(pdf?.remoteId, "f1")
        XCTAssertEqual(pdf?.byteSize, 100)
        XCTAssertEqual(pdf?.nodeKind, .file)

        let folder = collected.first { $0.name == "Docs" }
        XCTAssertEqual(folder?.remoteId, "d1")
        XCTAssertEqual(folder?.nodeKind, .folder)

        let root = collected.first { $0.name == "My Drive" && $0.parentId == nil }
        XCTAssertNotNil(root)
        // Root size = children aggregate (100 from a.pdf + 0 from empty Docs).
        XCTAssertEqual(root?.byteSize, 100)
        XCTAssertEqual(root?.itemCount, 1)
    }

    // MARK: Trash via mock

    func testTrashPatchesTrashedTrue() async throws {
        let locationId = UUID()
        let patched = LockedStrings()

        MockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer trash-token")
            let path = url.path
            // /drive/v3/files/{id}
            if let range = path.range(of: "/drive/v3/files/") {
                let idPart = String(path[range.upperBound...])
                patched.append(idPart)
            }
            if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
                XCTAssertTrue(text.contains("trashed"))
                XCTAssertTrue(text.contains("true"))
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"x","trashed":true}"#.utf8))
        }

        let source = GoogleDriveSource(
            accessTokenProvider: { _ in "trash-token" },
            session: session
        )

        let nodes = [
            StorageNode.fixture(
                id: "\(locationId.uuidString)/fileA",
                locationId: locationId,
                name: "a.pdf",
                remoteId: "fileA"
            ),
            StorageNode.fixture(
                id: "\(locationId.uuidString)/fileB",
                locationId: locationId,
                name: "b.txt",
                remoteId: "fileB"
            ),
        ]

        let results = try await source.trash(nodes: nodes)
        XCTAssertEqual(results.count, 2)
        for result in results {
            if case .movedToTrash = result {
                // ok
            } else {
                XCTFail("expected movedToTrash, got \(result)")
            }
        }
        XCTAssertEqual(Set(patched.snapshot()), Set(["fileA", "fileB"]))
    }

    func testListRetriesOnceAfter401WithForceRefresh() async throws {
        let tokensUsed = LockedStrings()
        let callCount = LockedCounter()
        let emptyFolderJSON = Data(#"{"files":[]}"#.utf8)

        MockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            tokensUsed.append(auth)
            let n = callCount.increment()
            guard let url = request.url else { throw URLError(.badURL) }
            if n == 1 {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, emptyFolderJSON)
        }

        let forceFlags = LockedBools()
        let source = GoogleDriveSource(
            accessTokenProvider: { force in
                forceFlags.append(force)
                return force ? "fresh-token" : "stale-token"
            },
            session: session
        )

        let location = ScanLocation(
            id: UUID(),
            sourceKind: .googleDrive,
            displayName: "Drive",
            rootRef: "root",
            accountId: "a@b.c",
            lastScannedAt: nil,
            scanState: .idle
        )
        let collector = NodeCollector()
        try await source.enumerate(
            location: location,
            generation: 1,
            onBatch: { batch in await collector.append(batch) },
            onProgress: { _ in }
        )

        let flags = forceFlags.snapshot()
        XCTAssertTrue(flags.contains(false))
        XCTAssertTrue(flags.contains(true), "expected forceRefresh on 401 retry")
        let auths = tokensUsed.snapshot()
        XCTAssertTrue(auths.contains("Bearer stale-token"))
        XCTAssertTrue(auths.contains("Bearer fresh-token"))
    }

    func testTrashFailsWithoutRemoteId() async throws {
        MockURLProtocol.handler = { _ in
            XCTFail("should not hit network without remoteId")
            throw URLError(.badURL)
        }
        let source = GoogleDriveSource(
            accessTokenProvider: { _ in "token" },
            session: session
        )
        // id with no slash and nil remoteId → fail
        let node = StorageNode.fixture(id: "orphan", name: "x", remoteId: nil)
        // Force remoteId nil and id without slash file segment usable as id — our source falls back to id.
        // Use empty remoteId explicitly by clearing after fixture: fixture allows remoteId nil;
        // fileId(fromNodeId: "orphan") returns "orphan", so it would still PATCH. Use empty string remoteId?
        // Implementation: `node.remoteId ?? fileId(fromNodeId: node.id)` — so nil remoteId uses id.
        // For true failure need empty remoteId and empty id path. Override:
        var bad = node
        bad.remoteId = ""
        bad.id = ""
        let results = try await source.trash(nodes: [bad])
        XCTAssertEqual(results.count, 1)
        if case .failed(let id, _) = results[0] {
            XCTAssertEqual(id, "")
        } else {
            XCTFail("expected failure")
        }
    }

    // MARK: OAuth helpers

    func testCallbackSchemeFromRedirectURI() {
        XCTAssertEqual(
            GoogleOAuthClient.callbackScheme(from: "com.nodaysidle.cistilka:/oauth2redirect/google"),
            "com.nodaysidle.cistilka"
        )
        XCTAssertEqual(
            GoogleOAuthClient.callbackScheme(from: "com.nodaysidle.cistilka://oauth2redirect/google"),
            "com.nodaysidle.cistilka"
        )
    }

    func testAuthorizationCodeFromCallback() throws {
        let url = URL(string: "com.nodaysidle.cistilka:/oauth2redirect/google?code=abc123&state=xyz")!
        let code = try GoogleOAuthClient.authorizationCode(from: url, expectedState: "xyz")
        XCTAssertEqual(code, "abc123")
    }

    func testDecodeTokenResponse() throws {
        let json = """
        {
          "access_token": "ya29.a0",
          "expires_in": 3600,
          "refresh_token": "1//0",
          "scope": "https://www.googleapis.com/auth/drive",
          "token_type": "Bearer"
        }
        """.data(using: .utf8)!
        let tokens = try GoogleOAuthClient.decodeTokenResponse(
            data: json,
            provider: .google,
            fallbackRefresh: nil
        )
        XCTAssertEqual(tokens.accessToken, "ya29.a0")
        XCTAssertEqual(tokens.refreshToken, "1//0")
        XCTAssertEqual(tokens.provider, .google)
        XCTAssertNotNil(tokens.expiresAt)
    }

    func testOAuthConfigGoogleConfiguredFlag() {
        var config = OAuthConfig()
        XCTAssertFalse(config.isGoogleConfigured)
        config.googleClientID = "client.apps.googleusercontent.com"
        config.googleRedirectURI = "com.nodaysidle.cistilka:/oauth2redirect/google"
        XCTAssertTrue(config.isGoogleConfigured)
    }
}

// MARK: - Collectors

private actor NodeCollector {
    private(set) var nodes: [StorageNode] = []
    func append(_ batch: [StorageNode]) {
        nodes.append(contentsOf: batch)
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        value += 1
        let v = value
        lock.unlock()
        return v
    }
}

private final class LockedBools: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}


