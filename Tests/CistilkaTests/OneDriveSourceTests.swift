import XCTest
@testable import Cistilka

// MARK: - URLProtocol mock

private final class OneDriveMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = OneDriveMockURLProtocol.handler else {
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

final class OneDriveSourceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OneDriveMockURLProtocol.self]
        session = URLSession(configuration: config)
        OneDriveMockURLProtocol.handler = nil
    }

    override func tearDown() {
        OneDriveMockURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    // MARK: Parser

    func testParseListResponseMapsFilesAndFolders() throws {
        let json = """
        {
          "value": [
            {
              "id": "file1",
              "name": "report.pdf",
              "size": 2048,
              "file": { "mimeType": "application/pdf" },
              "lastModifiedDateTime": "2024-06-01T12:00:00.000Z",
              "webUrl": "https://onedrive.live.com/redir?resid=file1"
            },
            {
              "id": "folder1",
              "name": "Photos",
              "folder": { "childCount": 2 },
              "webUrl": "https://onedrive.live.com/redir?resid=folder1"
            }
          ],
          "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=page2"
        }
        """.data(using: .utf8)!

        let page = try OneDriveSource.parseListResponse(data: json)
        XCTAssertEqual(page.value.count, 2)
        XCTAssertEqual(
            page.nextLink,
            "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=page2"
        )

        let pdf = page.value[0]
        XCTAssertEqual(pdf.id, "file1")
        XCTAssertEqual(pdf.name, "report.pdf")
        XCTAssertEqual(pdf.byteSize, 2048)
        XCTAssertFalse(pdf.isFolder)
        XCTAssertEqual(pdf.mimeType, "application/pdf")
        XCTAssertEqual(pdf.webUrl, "https://onedrive.live.com/redir?resid=file1")

        let folder = page.value[1]
        XCTAssertEqual(folder.id, "folder1")
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.byteSize, 0)
    }

    func testMapItemSetsRemoteIdAndExtension() {
        let locationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let item = OneDriveItemDTO(
            id: "abc",
            name: "notes.txt",
            size: 10,
            file: OneDriveFileFacet(mimeType: "text/plain"),
            lastModifiedDateTime: nil,
            webUrl: "https://example.com/notes"
        )
        let node = OneDriveSource.mapItem(
            item,
            parentNodeId: "\(locationId.uuidString)/root",
            locationId: locationId,
            logicalPath: "/OneDrive/notes.txt",
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
            sourceKind: .oneDrive,
            displayName: "OneDrive",
            rootRef: "root",
            accountId: "user@example.com",
            lastScannedAt: nil,
            scanState: .idle
        )

        let listJSON = """
        {
          "value": [
            {
              "id": "f1",
              "name": "a.pdf",
              "size": 100,
              "file": { "mimeType": "application/pdf" }
            },
            {
              "id": "d1",
              "name": "Docs",
              "folder": { "childCount": 0 }
            }
          ]
        }
        """.data(using: .utf8)!

        let emptyFolderJSON = """
        { "value": [] }
        """.data(using: .utf8)!

        OneDriveMockURLProtocol.handler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(url.absoluteString.contains("graph.microsoft.com"))

            let path = url.path
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if path.hasSuffix("/me/drive/root/children") {
                return (response, listJSON)
            }
            if path.contains("/me/drive/items/d1/children") {
                return (response, emptyFolderJSON)
            }
            return (response, emptyFolderJSON)
        }

        let source = OneDriveSource(
            accessTokenProvider: { _ in "test-token" },
            session: session,
            rootItemId: "root",
            rootDisplayName: "OneDrive"
        )

        let collector = OneDriveNodeCollector()
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
        XCTAssertTrue(names.contains("OneDrive"))
        XCTAssertTrue(names.contains("a.pdf"))
        XCTAssertTrue(names.contains("Docs"))

        let pdf = collected.first { $0.name == "a.pdf" }
        XCTAssertEqual(pdf?.remoteId, "f1")
        XCTAssertEqual(pdf?.byteSize, 100)
        XCTAssertEqual(pdf?.nodeKind, .file)

        let folder = collected.first { $0.name == "Docs" }
        XCTAssertEqual(folder?.remoteId, "d1")
        XCTAssertEqual(folder?.nodeKind, .folder)

        let root = collected.first { $0.name == "OneDrive" && $0.parentId == nil }
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.byteSize, 100)
        XCTAssertEqual(root?.itemCount, 1)
    }

    // MARK: Trash via mock

    func testTrashDeletesToRecycleBin() async throws {
        let locationId = UUID()
        let deleted = OneDriveLockedStrings()

        OneDriveMockURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer trash-token")
            let path = url.path
            // Must not hit permanentDelete.
            XCTAssertFalse(path.contains("permanentDelete"))
            XCTAssertTrue(path.contains("/me/drive/items/"))
            if let range = path.range(of: "/me/drive/items/") {
                let idPart = String(path[range.upperBound...])
                deleted.append(idPart)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let source = OneDriveSource(
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
        XCTAssertEqual(Set(deleted.snapshot()), Set(["fileA", "fileB"]))
    }

    func testTrashFailsWithoutRemoteId() async throws {
        OneDriveMockURLProtocol.handler = { _ in
            XCTFail("should not hit network without remoteId")
            throw URLError(.badURL)
        }
        let source = OneDriveSource(
            accessTokenProvider: { _ in "token" },
            session: session
        )
        var bad = StorageNode.fixture(id: "orphan", name: "x", remoteId: nil)
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
            MicrosoftOAuthClient.callbackScheme(from: "msauth.com.nodaysidle.cistilka://auth"),
            "msauth.com.nodaysidle.cistilka"
        )
        XCTAssertEqual(
            MicrosoftOAuthClient.callbackScheme(from: "com.nodaysidle.cistilka:/oauth2redirect/microsoft"),
            "com.nodaysidle.cistilka"
        )
    }

    func testAuthorizationCodeFromCallback() throws {
        let url = URL(string: "msauth.com.nodaysidle.cistilka://auth?code=abc123&state=xyz")!
        let code = try MicrosoftOAuthClient.authorizationCode(from: url, expectedState: "xyz")
        XCTAssertEqual(code, "abc123")
    }

    func testDecodeTokenResponse() throws {
        let json = """
        {
          "access_token": "eyJ0eXAiOiJKV1QiLCJub25jZSI6",
          "expires_in": 3600,
          "refresh_token": "0.AXoA",
          "scope": "Files.ReadWrite User.Read offline_access",
          "token_type": "Bearer"
        }
        """.data(using: .utf8)!
        let tokens = try MicrosoftOAuthClient.decodeTokenResponse(
            data: json,
            provider: .microsoft,
            fallbackRefresh: nil
        )
        XCTAssertEqual(tokens.accessToken, "eyJ0eXAiOiJKV1QiLCJub25jZSI6")
        XCTAssertEqual(tokens.refreshToken, "0.AXoA")
        XCTAssertEqual(tokens.provider, .microsoft)
        XCTAssertNotNil(tokens.expiresAt)
    }

    func testOAuthConfigMicrosoftConfiguredFlag() {
        var config = OAuthConfig()
        XCTAssertFalse(config.isMicrosoftConfigured)
        config.microsoftClientID = "11111111-2222-3333-4444-555555555555"
        config.microsoftRedirectURI = "msauth.com.nodaysidle.cistilka://auth"
        XCTAssertTrue(config.isMicrosoftConfigured)
    }

    func testDefaultScopesIncludeOfflineAndFiles() {
        let scopes = Set(MicrosoftOAuthClient.defaultScopes)
        XCTAssertTrue(scopes.contains("offline_access"))
        XCTAssertTrue(scopes.contains("User.Read"))
        XCTAssertTrue(scopes.contains("Files.ReadWrite"))
    }
}

// MARK: - Collectors

private actor OneDriveNodeCollector {
    private(set) var nodes: [StorageNode] = []
    func append(_ batch: [StorageNode]) {
        nodes.append(contentsOf: batch)
    }
}

private final class OneDriveLockedStrings: @unchecked Sendable {
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
