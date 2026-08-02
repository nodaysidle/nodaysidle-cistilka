import AppKit
import Foundation

/// Microsoft Graph OneDrive `ScanSource`: list children, trash via DELETE (recycle bin), reveal via webUrl.
///
/// Trash uses `DELETE /me/drive/items/{id}` which moves items to the OneDrive recycle bin.
/// Never call `permanentDelete` — that permanently purges and is forbidden for v1.
struct OneDriveSource: ScanSource {
    /// - Parameter forceRefresh: When true, caller should refresh even if access token is not yet expired (401 retry).
    typealias AccessTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    var supportsTrash: Bool { true }

    /// Supplies a Bearer access token per request (refresh handled by `AuthStore`).
    var accessTokenProvider: AccessTokenProvider
    /// Injectable for URLProtocol mocks in tests.
    var session: URLSession
    /// Graph item id for the drive root (`"root"` alias for list paths).
    var rootItemId: String
    /// Display name for the emitted root folder node.
    var rootDisplayName: String
    /// Optional local CloudStorage mirror base (e.g. `~/Library/CloudStorage/OneDrive-…`).
    var cloudStorageRoot: URL?

    private let pageSize = 200
    private let selectFields =
        "id,name,size,folder,file,parentReference,lastModifiedDateTime,webUrl,@microsoft.graph.downloadUrl"

    init(
        accessTokenProvider: @escaping AccessTokenProvider,
        session: URLSession = .shared,
        rootItemId: String = "root",
        rootDisplayName: String = "OneDrive",
        cloudStorageRoot: URL? = nil
    ) {
        self.accessTokenProvider = accessTokenProvider
        self.session = session
        self.rootItemId = rootItemId
        self.rootDisplayName = rootDisplayName
        self.cloudStorageRoot = cloudStorageRoot
    }

    // MARK: - ScanSource

    func enumerate(
        location: ScanLocation,
        generation: UInt64,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws {
        let progress = OneDriveProgressState()
        // Token is fetched per HTTP request (not frozen for the whole tree).

        let rootNodeId = nodeId(itemId: rootItemId, locationId: location.id)
        let rootAggregate = try await scanFolder(
            itemId: rootItemId,
            nodeId: rootNodeId,
            parentNodeId: nil,
            name: rootDisplayName,
            logicalPath: "/\(rootDisplayName)",
            webUrl: nil,
            locationId: location.id,
            generation: generation,
            progress: progress,
            onBatch: onBatch,
            onProgress: onProgress
        )
        await onBatch([rootAggregate])
        await onProgress(await progress.snapshot())
    }

    func trash(nodes: [StorageNode]) async throws -> [RemovalResult] {
        var results: [RemovalResult] = []
        results.reserveCapacity(nodes.count)
        for node in nodes {
            guard let remoteId = node.remoteId ?? itemId(fromNodeId: node.id), !remoteId.isEmpty else {
                results.append(.failed(nodeId: node.id, message: "Missing OneDrive item id"))
                continue
            }
            // Never permanentDelete — only DELETE to recycle bin.
            do {
                try await deleteToRecycleBin(itemId: remoteId)
                results.append(.movedToTrash(nodeId: node.id))
            } catch {
                results.append(.failed(nodeId: node.id, message: error.localizedDescription))
            }
        }
        return results
    }

    func reveal(node: StorageNode) async throws {
        // Prefer Finder when a CloudStorage mirror path exists.
        if let mirrored = mirroredLocalURL(for: node) {
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([mirrored])
            }
            return
        }

        let itemId = node.remoteId ?? itemId(fromNodeId: node.id) ?? rootItemId

        if let webURL = try await fetchWebURL(itemId: itemId) {
            let opened: Bool = await MainActor.run {
                NSWorkspace.shared.open(webURL)
            }
            _ = opened
            return
        }

        // Fallback landing page when metadata lacks webUrl.
        let fallback = URL(string: "https://onedrive.live.com/")!
        let opened: Bool = await MainActor.run {
            NSWorkspace.shared.open(fallback)
        }
        _ = opened
    }

    func resolveDisplayPath(node: StorageNode) -> String {
        node.logicalPath
    }

    // MARK: - Recursive list

    private func scanFolder(
        itemId: String,
        nodeId: String,
        parentNodeId: String?,
        name: String,
        logicalPath: String,
        webUrl: String?,
        locationId: UUID,
        generation: UInt64,
        progress: OneDriveProgressState,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> StorageNode {
        try Task.checkCancellation()
        await progress.noteDir(path: logicalPath)
        await onProgress(await progress.snapshot())

        let children = try await listAllChildren(itemId: itemId)

        var leafNodes: [StorageNode] = []
        var subfolders: [(OneDriveItemDTO, String, String)] = [] // dto, childNodeId, childPath

        for item in children {
            try Task.checkCancellation()
            let childId = self.nodeId(itemId: item.id, locationId: locationId)
            let childPath = logicalPath == "/" ? "/\(item.name)" : "\(logicalPath)/\(item.name)"

            if item.isFolder {
                subfolders.append((item, childId, childPath))
                continue
            }

            let size = item.byteSize
            let ext = Self.fileExtension(name: item.name, mimeType: item.mimeType)
            let node = StorageNode(
                id: childId,
                parentId: nodeId,
                locationId: locationId,
                name: item.name,
                nodeKind: .file,
                logicalPath: childPath,
                byteSize: size,
                itemCount: 1,
                fileExtension: ext,
                contentType: item.mimeType,
                isPackage: false,
                permissionsState: .ok,
                modifiedAt: item.modifiedDate,
                remoteId: item.id,
                scanGeneration: generation
            )
            leafNodes.append(node)
            await progress.noteFile(bytes: size, path: childPath)
        }

        if !leafNodes.isEmpty {
            await onBatch(leafNodes)
            await onProgress(await progress.snapshot())
        }

        var folderNodes: [StorageNode] = []
        folderNodes.reserveCapacity(subfolders.count)

        let maxConcurrent = 4
        try await withThrowingTaskGroup(of: StorageNode.self) { group in
            var iterator = subfolders.makeIterator()
            var inFlight = 0

            func enqueueNext() {
                while inFlight < maxConcurrent, let next = iterator.next() {
                    inFlight += 1
                    let (dto, childId, childPath) = next
                    group.addTask {
                        try await self.scanFolder(
                            itemId: dto.id,
                            nodeId: childId,
                            parentNodeId: nodeId,
                            name: dto.name,
                            logicalPath: childPath,
                            webUrl: dto.webUrl,
                            locationId: locationId,
                            generation: generation,
                            progress: progress,
                            onBatch: onBatch,
                            onProgress: onProgress
                        )
                    }
                }
            }

            enqueueNext()
            for try await folderNode in group {
                inFlight -= 1
                folderNodes.append(folderNode)
                enqueueNext()
            }
        }

        if !folderNodes.isEmpty {
            await onBatch(folderNodes)
        }

        let totalBytes = leafNodes.reduce(Int64(0)) { $0 + $1.byteSize }
            + folderNodes.reduce(Int64(0)) { $0 + $1.byteSize }
        let totalItems = leafNodes.reduce(Int64(0)) { $0 + $1.itemCount }
            + folderNodes.reduce(Int64(0)) { $0 + $1.itemCount }

        return StorageNode(
            id: nodeId,
            parentId: parentNodeId,
            locationId: locationId,
            name: name,
            nodeKind: .folder,
            logicalPath: logicalPath,
            byteSize: totalBytes,
            itemCount: totalItems,
            fileExtension: nil,
            contentType: "folder",
            isPackage: false,
            permissionsState: .ok,
            modifiedAt: nil,
            remoteId: itemId,
            scanGeneration: generation
        )
    }

    private func listAllChildren(itemId: String) async throws -> [OneDriveItemDTO] {
        var nextURL: URL? = childrenListURL(itemId: itemId)
        var all: [OneDriveItemDTO] = []
        while let url = nextURL {
            let page = try await listPage(url: url)
            all.append(contentsOf: page.value)
            if let link = page.nextLink, let next = URL(string: link) {
                nextURL = next
            } else {
                nextURL = nil
            }
        }
        return all
    }

    private func childrenListURL(itemId: String) -> URL {
        let path: String
        if itemId == "root" {
            path = "https://graph.microsoft.com/v1.0/me/drive/root/children"
        } else {
            // Percent-encode id path segment (ids are usually safe alphanumerics + !).
            let encoded = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
            path = "https://graph.microsoft.com/v1.0/me/drive/items/\(encoded)/children"
        }
        var components = URLComponents(string: path)!
        components.queryItems = [
            URLQueryItem(name: "$top", value: String(pageSize)),
            URLQueryItem(name: "$select", value: selectFields),
        ]
        return components.url!
    }

    private func listPage(url: URL) async throws -> OneDriveListPage {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithAuth(request)
        try Self.throwIfHTTPError(data: data, response: response)
        return try Self.parseListResponse(data: data)
    }

    /// DELETE moves the item to the recycle bin (not permanent purge).
    private func deleteToRecycleBin(itemId: String) async throws {
        // Guard against accidental permanent purge endpoint.
        precondition(!itemId.contains("permanentDelete"), "permanentDelete is forbidden")
        let encoded = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(encoded)") else {
            throw OneDriveAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await dataWithAuth(request)
        try Self.throwIfHTTPError(data: data, response: response)
    }

    private func fetchWebURL(itemId: String) async throws -> URL? {
        let path: String
        if itemId == "root" {
            path = "https://graph.microsoft.com/v1.0/me/drive/root?$select=webUrl"
        } else {
            let encoded = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
            path = "https://graph.microsoft.com/v1.0/me/drive/items/\(encoded)?$select=webUrl"
        }
        guard let url = URL(string: path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithAuth(request)
        try Self.throwIfHTTPError(data: data, response: response)
        struct WebOnly: Decodable {
            var webUrl: String?
        }
        let parsed = try JSONDecoder().decode(WebOnly.self, from: data)
        guard let s = parsed.webUrl, let web = URL(string: s) else { return nil }
        return web
    }

    /// Fetch a fresh token per request; on HTTP 401 force-refresh once and retry.
    private func dataWithAuth(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastData = Data()
        var lastResponse: URLResponse = URLResponse()
        for attempt in 0..<2 {
            let forceRefresh = attempt > 0
            let token = try await accessTokenProvider(forceRefresh)
            var authorized = request
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: authorized)
            lastData = data
            lastResponse = response
            if let http = response as? HTTPURLResponse, http.statusCode == 401, attempt == 0 {
                continue
            }
            return (data, response)
        }
        return (lastData, lastResponse)
    }

    // MARK: - IDs / paths

    private func nodeId(itemId: String, locationId: UUID) -> String {
        "\(locationId.uuidString)/\(itemId)"
    }

    private func itemId(fromNodeId id: String) -> String? {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }

    private func mirroredLocalURL(for node: StorageNode) -> URL? {
        guard let root = cloudStorageRoot else { return nil }
        var relative = node.logicalPath
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        let parts = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        let remainder = parts.count > 1 ? String(parts[1]) : ""
        let candidate: URL
        if remainder.isEmpty {
            candidate = root
        } else {
            candidate = root.appendingPathComponent(remainder)
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Parsing (public for tests)

    /// Parse a Graph `children` JSON body (`value` + `@odata.nextLink`).
    static func parseListResponse(data: Data) throws -> OneDriveListPage {
        let decoder = JSONDecoder()
        return try decoder.decode(OneDriveListPage.self, from: data)
    }

    /// Map a Graph driveItem into a `StorageNode` (test helper).
    static func mapItem(
        _ item: OneDriveItemDTO,
        parentNodeId: String?,
        locationId: UUID,
        logicalPath: String,
        generation: UInt64
    ) -> StorageNode {
        let isFolder = item.isFolder
        let ext = isFolder ? nil : fileExtension(name: item.name, mimeType: item.mimeType)
        return StorageNode(
            id: "\(locationId.uuidString)/\(item.id)",
            parentId: parentNodeId,
            locationId: locationId,
            name: item.name,
            nodeKind: isFolder ? .folder : .file,
            logicalPath: logicalPath,
            byteSize: isFolder ? 0 : item.byteSize,
            itemCount: isFolder ? 0 : 1,
            fileExtension: ext,
            contentType: isFolder ? "folder" : item.mimeType,
            isPackage: false,
            permissionsState: .ok,
            modifiedAt: item.modifiedDate,
            remoteId: item.id,
            scanGeneration: generation
        )
    }

    static func fileExtension(name: String, mimeType: String?) -> String? {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty {
            return ext.lowercased()
        }
        return nil
    }

    private static func throwIfHTTPError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        // DELETE recycle-bin success is often 204 No Content.
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OneDriveAPIError.httpStatus(http.statusCode, body)
        }
    }
}

// MARK: - DTOs

struct OneDriveListPage: Decodable, Sendable, Equatable {
    var value: [OneDriveItemDTO]
    var nextLink: String?

    init(value: [OneDriveItemDTO], nextLink: String? = nil) {
        self.value = value
        self.nextLink = nextLink
    }

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent([OneDriveItemDTO].self, forKey: .value) ?? []
        nextLink = try c.decodeIfPresent(String.self, forKey: .nextLink)
    }
}

struct OneDriveItemDTO: Decodable, Sendable, Equatable {
    var id: String
    var name: String
    var size: Int64?
    var folder: OneDriveFolderFacet?
    var file: OneDriveFileFacet?
    var parentReference: OneDriveParentReference?
    var lastModifiedDateTime: String?
    var webUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, folder, file, parentReference, lastModifiedDateTime, webUrl
    }

    init(
        id: String,
        name: String,
        size: Int64? = nil,
        folder: OneDriveFolderFacet? = nil,
        file: OneDriveFileFacet? = nil,
        parentReference: OneDriveParentReference? = nil,
        lastModifiedDateTime: String? = nil,
        webUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.folder = folder
        self.file = file
        self.parentReference = parentReference
        self.lastModifiedDateTime = lastModifiedDateTime
        self.webUrl = webUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        folder = try c.decodeIfPresent(OneDriveFolderFacet.self, forKey: .folder)
        file = try c.decodeIfPresent(OneDriveFileFacet.self, forKey: .file)
        parentReference = try c.decodeIfPresent(OneDriveParentReference.self, forKey: .parentReference)
        lastModifiedDateTime = try c.decodeIfPresent(String.self, forKey: .lastModifiedDateTime)
        webUrl = try c.decodeIfPresent(String.self, forKey: .webUrl)
    }

    var isFolder: Bool {
        folder != nil
    }

    var byteSize: Int64 {
        size ?? 0
    }

    var mimeType: String? {
        file?.mimeType
    }

    var modifiedDate: Date? {
        guard let lastModifiedDateTime else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: lastModifiedDateTime) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: lastModifiedDateTime)
    }
}

struct OneDriveFolderFacet: Decodable, Sendable, Equatable {
    var childCount: Int?
}

struct OneDriveFileFacet: Decodable, Sendable, Equatable {
    var mimeType: String?
}

struct OneDriveParentReference: Decodable, Sendable, Equatable {
    var id: String?
    var path: String?
}

enum OneDriveAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Microsoft Graph API URL."
        case .httpStatus(let code, let body):
            let snippet = body.prefix(200)
            return "Microsoft Graph API error HTTP \(code): \(snippet)"
        }
    }
}

// MARK: - Progress

private actor OneDriveProgressState {
    private var dirsVisited = 0
    private var filesVisited = 0
    private var bytesSeen: Int64 = 0
    private var currentPath = ""

    func noteDir(path: String) {
        dirsVisited += 1
        currentPath = path
    }

    func noteFile(bytes: Int64, path: String) {
        filesVisited += 1
        bytesSeen += bytes
        currentPath = path
    }

    func snapshot() -> ScanProgress {
        ScanProgress(
            dirsVisited: dirsVisited,
            filesVisited: filesVisited,
            bytesSeen: bytesSeen,
            currentPath: currentPath
        )
    }
}
