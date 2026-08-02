import AppKit
import Foundation

/// Google Drive v3 `ScanSource`: list by parent, trash via `trashed=true`, reveal in browser/Finder.
struct GoogleDriveSource: ScanSource {
    /// - Parameter forceRefresh: When true, caller should refresh even if access token is not yet expired (401 retry).
    typealias AccessTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    var supportsTrash: Bool { true }

    /// Supplies a Bearer access token per request (refresh handled by `AuthStore`).
    var accessTokenProvider: AccessTokenProvider
    /// Injectable for URLProtocol mocks in tests.
    var session: URLSession
    /// Root parent id for My Drive (`"root"` alias).
    var rootParentId: String
    /// Display name for the emitted root folder node.
    var rootDisplayName: String
    /// Optional local CloudStorage mirror base (e.g. `~/Library/CloudStorage/GoogleDrive-…`).
    var cloudStorageRoot: URL?

    private let folderMimeType = "application/vnd.google-apps.folder"
    private let pageSize = 1000
    private let fields =
        "nextPageToken,files(id,name,mimeType,size,parents,modifiedTime,md5Checksum)"

    init(
        accessTokenProvider: @escaping AccessTokenProvider,
        session: URLSession = .shared,
        rootParentId: String = "root",
        rootDisplayName: String = "My Drive",
        cloudStorageRoot: URL? = nil
    ) {
        self.accessTokenProvider = accessTokenProvider
        self.session = session
        self.rootParentId = rootParentId
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
        let progress = DriveProgressState()
        // Token is fetched per HTTP request (not frozen for the whole tree).

        let rootNodeId = nodeId(fileId: rootParentId, locationId: location.id)
        let rootAggregate = try await scanFolder(
            fileId: rootParentId,
            nodeId: rootNodeId,
            parentNodeId: nil,
            name: rootDisplayName,
            logicalPath: "/\(rootDisplayName)",
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
            guard let remoteId = node.remoteId ?? fileId(fromNodeId: node.id), !remoteId.isEmpty else {
                results.append(.failed(nodeId: node.id, message: "Missing Drive file id"))
                continue
            }
            // Never permanently delete — only mark trashed.
            do {
                try await patchTrashed(fileId: remoteId)
                results.append(.movedToTrash(nodeId: node.id))
            } catch {
                results.append(.failed(nodeId: node.id, message: error.localizedDescription))
            }
        }
        return results
    }

    func reveal(node: StorageNode) async throws {
        let fileId = node.remoteId ?? fileId(fromNodeId: node.id) ?? rootParentId

        // Prefer Finder when a CloudStorage mirror path exists.
        if let mirrored = mirroredLocalURL(for: node) {
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([mirrored])
            }
            return
        }

        let url: URL
        if node.nodeKind == .folder || fileId == rootParentId || fileId == "root" {
            if fileId == rootParentId || fileId == "root" {
                url = URL(string: "https://drive.google.com/drive/my-drive")!
            } else {
                url = URL(string: "https://drive.google.com/drive/folders/\(fileId)")!
            }
        } else {
            url = URL(string: "https://drive.google.com/file/d/\(fileId)/view")!
        }
        let opened: Bool = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        _ = opened
    }

    func resolveDisplayPath(node: StorageNode) -> String {
        node.logicalPath
    }

    // MARK: - Recursive list

    private func scanFolder(
        fileId: String,
        nodeId: String,
        parentNodeId: String?,
        name: String,
        logicalPath: String,
        locationId: UUID,
        generation: UInt64,
        progress: DriveProgressState,
        onBatch: @escaping @Sendable ([StorageNode]) async -> Void,
        onProgress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> StorageNode {
        try Task.checkCancellation()
        await progress.noteDir(path: logicalPath)
        await onProgress(await progress.snapshot())

        let files = try await listAllChildren(parentId: fileId)

        var leafNodes: [StorageNode] = []
        var subfolders: [(DriveFileDTO, String, String)] = [] // dto, childNodeId, childPath

        for file in files {
            try Task.checkCancellation()
            let childId = self.nodeId(fileId: file.id, locationId: locationId)
            let childPath = logicalPath == "/" ? "/\(file.name)" : "\(logicalPath)/\(file.name)"

            if file.isFolder {
                subfolders.append((file, childId, childPath))
                continue
            }

            let size = file.byteSize
            let ext = Self.fileExtension(name: file.name, mimeType: file.mimeType)
            let node = StorageNode(
                id: childId,
                parentId: nodeId,
                locationId: locationId,
                name: file.name,
                nodeKind: .file,
                logicalPath: childPath,
                byteSize: size,
                itemCount: 1,
                fileExtension: ext,
                contentType: file.mimeType,
                isPackage: false,
                permissionsState: .ok,
                modifiedAt: file.modifiedDate,
                remoteId: file.id,
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

        // Bounded concurrency for remote listing.
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
                            fileId: dto.id,
                            nodeId: childId,
                            parentNodeId: nodeId,
                            name: dto.name,
                            logicalPath: childPath,
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
            contentType: folderMimeType,
            isPackage: false,
            permissionsState: .ok,
            modifiedAt: nil,
            remoteId: fileId,
            scanGeneration: generation
        )
    }

    private func listAllChildren(parentId: String) async throws -> [DriveFileDTO] {
        var pageToken: String?
        var all: [DriveFileDTO] = []
        repeat {
            let page = try await listPage(parentId: parentId, pageToken: pageToken)
            all.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    private func listPage(parentId: String, pageToken: String?) async throws -> DriveListPage {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        // Escape single quotes in parent id for Drive query language.
        let safeParent = parentId.replacingOccurrences(of: "'", with: "\\'")
        let q = "'\(safeParent)' in parents and trashed = false"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "false"),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw DriveAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await dataWithAuth(request)
        try Self.throwIfHTTPError(data: data, response: response)
        return try Self.parseListResponse(data: data)
    }

    private func patchTrashed(fileId: String) async throws {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?supportsAllDrives=true") else {
            throw DriveAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"trashed":true}"#.utf8)

        let (data, response) = try await dataWithAuth(request)
        try Self.throwIfHTTPError(data: data, response: response)
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

    private func nodeId(fileId: String, locationId: UUID) -> String {
        "\(locationId.uuidString)/\(fileId)"
    }

    private func fileId(fromNodeId id: String) -> String? {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }

    private func mirroredLocalURL(for node: StorageNode) -> URL? {
        guard let root = cloudStorageRoot else { return nil }
        // logicalPath is "/My Drive/…" — strip first path component for mirror relative path.
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

    /// Parse a Drive v3 `files.list` JSON body.
    static func parseListResponse(data: Data) throws -> DriveListPage {
        let decoder = JSONDecoder()
        return try decoder.decode(DriveListPage.self, from: data)
    }

    /// Map a Drive file resource JSON object into a `StorageNode` (test helper).
    static func mapFile(
        _ file: DriveFileDTO,
        parentNodeId: String?,
        locationId: UUID,
        logicalPath: String,
        generation: UInt64
    ) -> StorageNode {
        let isFolder = file.isFolder
        let ext = isFolder ? nil : fileExtension(name: file.name, mimeType: file.mimeType)
        return StorageNode(
            id: "\(locationId.uuidString)/\(file.id)",
            parentId: parentNodeId,
            locationId: locationId,
            name: file.name,
            nodeKind: isFolder ? .folder : .file,
            logicalPath: logicalPath,
            byteSize: isFolder ? 0 : file.byteSize,
            itemCount: isFolder ? 0 : 1,
            fileExtension: ext,
            contentType: file.mimeType,
            isPackage: false,
            permissionsState: .ok,
            modifiedAt: file.modifiedDate,
            remoteId: file.id,
            scanGeneration: generation
        )
    }

    static func fileExtension(name: String, mimeType: String?) -> String? {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty {
            return ext.lowercased()
        }
        // Google Docs native types often have no extension and size 0.
        if let mimeType, mimeType.hasPrefix("application/vnd.google-apps.") {
            let suffix = mimeType.replacingOccurrences(of: "application/vnd.google-apps.", with: "")
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }

    private static func throwIfHTTPError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DriveAPIError.httpStatus(http.statusCode, body)
        }
    }
}

// MARK: - DTOs

struct DriveListPage: Decodable, Sendable, Equatable {
    var files: [DriveFileDTO]
    var nextPageToken: String?

    init(files: [DriveFileDTO], nextPageToken: String? = nil) {
        self.files = files
        self.nextPageToken = nextPageToken
    }

    enum CodingKeys: String, CodingKey {
        case files
        case nextPageToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([DriveFileDTO].self, forKey: .files) ?? []
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

struct DriveFileDTO: Decodable, Sendable, Equatable {
    var id: String
    var name: String
    var mimeType: String?
    /// Drive returns size as a string for files; folders omit it.
    var size: String?
    var parents: [String]?
    var modifiedTime: String?

    enum CodingKeys: String, CodingKey {
        case id, name, mimeType, size, parents, modifiedTime
    }

    init(
        id: String,
        name: String,
        mimeType: String? = nil,
        size: String? = nil,
        parents: [String]? = nil,
        modifiedTime: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.parents = parents
        self.modifiedTime = modifiedTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        parents = try c.decodeIfPresent([String].self, forKey: .parents)
        modifiedTime = try c.decodeIfPresent(String.self, forKey: .modifiedTime)
    }

    var isFolder: Bool {
        mimeType == "application/vnd.google-apps.folder"
    }

    var byteSize: Int64 {
        guard let size, let value = Int64(size) else { return 0 }
        return value
    }

    var modifiedDate: Date? {
        guard let modifiedTime else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: modifiedTime) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: modifiedTime)
    }
}

enum DriveAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Google Drive API URL."
        case .httpStatus(let code, let body):
            let snippet = body.prefix(200)
            return "Google Drive API error HTTP \(code): \(snippet)"
        }
    }
}

// MARK: - Progress

private actor DriveProgressState {
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
