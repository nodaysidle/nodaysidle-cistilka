import Foundation
import Observation

/// Pending trash confirmation presented by the UI sheet.
struct PendingTrashRequest: Identifiable, Sendable {
    let id = UUID()
    let nodes: [StorageNode]
    /// Opaque source token for the confirm → perform path.
    let sourceKindToken: SourceKind
    /// SSH without remote trash: user must type `DELETE` before confirm is enabled.
    let requiresStrongConfirm: Bool
    /// Extra copy when permanent remote delete is required, scan-root warning, or mixed groups.
    let detailMessage: String?
    /// Remaining source groups after this confirm (mixed multi-select).
    let remainingGroupCount: Int
    /// True when any node is a forest root (`parentId == nil`) — stronger warning in copy.
    let includesScanRoot: Bool

    var itemCount: Int { nodes.count }
    var totalBytes: Int64 { nodes.reduce(0) { $0 + $1.byteSize } }

    var sourceDisplayName: String {
        sourceKindToken.displayName
    }

    /// Confirm sheet copy: “Move N items (SIZE) from SOURCE to Trash?” or permanent-delete wording.
    var confirmationMessage: String {
        let n = itemCount
        let noun = n == 1 ? "item" : "items"
        let size = ByteFormat.string(bytes: totalBytes)
        let source = sourceDisplayName
        let base: String
        if requiresStrongConfirm {
            base = "Permanently delete \(n) \(noun) (\(size)) on \(source)? This cannot be undone."
        } else {
            base = "Move \(n) \(noun) (\(size)) from \(source) to Trash?"
        }
        if includesScanRoot {
            return base
                + " This includes a scan root — the entire scanned tree for that location will be removed from Cistilka (items still go to system/cloud Trash, not permanently deleted)."
        }
        return base
    }

    /// Phrase the user must type for strong confirm.
    static let strongConfirmPhrase = "DELETE"

    /// Whether any node is a forest / scan root (`parentId == nil`).
    static func includesScanRoot(_ nodes: [StorageNode]) -> Bool {
        nodes.contains { $0.parentId == nil }
    }
}

extension SourceKind {
    var displayName: String {
        switch self {
        case .local: return "This Mac"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .ssh: return "SSH"
        }
    }
}

/// Confirm → trash per source → update index (+ optional SQLite). UI never calls `ScanSource.trash` directly.
@MainActor
@Observable
final class RemovalService {
    private let index: ScanIndex
    /// When set, successful trash also rewrites remaining nodes for affected locations.
    private let store: SQLiteStore?

    /// When non-nil, the confirm sheet should be presented.
    private(set) var pendingTrash: PendingTrashRequest?

    /// Held only while a confirm is pending (same MainActor session).
    private var pendingSource: (any ScanSource)?
    /// When pending is SSHSource without trash path, we set allowPermanentDelete on confirm.
    private var pendingSSHNeedsPermanent: Bool = false
    /// Remaining mixed-source groups to confirm after the current sheet.
    private var pendingQueue: [(nodes: [StorageNode], source: any ScanSource)] = []

    init(index: ScanIndex, store: SQLiteStore? = nil) {
        self.index = index
        self.store = store
    }

    /// Nodes that may be sent to Trash (excludes permission-denied).
    static func trashableNodes(from nodes: [StorageNode]) -> [StorageNode] {
        nodes.filter { isTrashable($0) }
    }

    /// Denied permission nodes cannot be trashed via UI drop/menu.
    static func isTrashable(_ node: StorageNode) -> Bool {
        node.permissionsState != .denied
    }

    /// Stage a trash operation and show the confirmation sheet.
    func requestTrash(nodes: [StorageNode], source: any ScanSource) {
        let eligible = Self.trashableNodes(from: nodes)
        guard !eligible.isEmpty else { return }
        guard source.supportsTrash else { return }
        pendingQueue = []
        stagePending(nodes: eligible, source: source)
    }

    /// Stage mixed multi-select: group by source kind, confirm one group at a time.
    /// Groups with empty trashable sets or `supportsTrash == false` are skipped.
    func requestTrashGrouped(groups: [(nodes: [StorageNode], source: any ScanSource)]) {
        var prepared: [(nodes: [StorageNode], source: any ScanSource, kind: SourceKind)] = []
        for group in groups {
            let eligible = Self.trashableNodes(from: group.nodes)
            guard !eligible.isEmpty, group.source.supportsTrash else { continue }
            prepared.append((eligible, group.source, sourceKindHint(for: group.source)))
        }
        // Stable order: local → googleDrive → oneDrive → ssh; merge same kind into one batch per source instance.
        let kindOrder: [SourceKind] = [.local, .googleDrive, .oneDrive, .ssh]
        prepared.sort { a, b in
            let ai = kindOrder.firstIndex(of: a.kind) ?? 99
            let bi = kindOrder.firstIndex(of: b.kind) ?? 99
            return ai < bi
        }
        guard !prepared.isEmpty else { return }
        let queue = prepared.map { (nodes: $0.nodes, source: $0.source) }
        pendingQueue = Array(queue.dropFirst())
        stagePending(nodes: queue[0].nodes, source: queue[0].source)
    }

    func cancelPending() {
        pendingTrash = nil
        pendingSource = nil
        pendingSSHNeedsPermanent = false
        pendingQueue = []
    }

    /// User confirmed the sheet; perform trash and advance mixed-source queue if needed.
    @discardableResult
    func confirmPending() async -> [RemovalResult] {
        guard let pending = pendingTrash, let source = pendingSource else {
            return []
        }
        pendingTrash = nil
        pendingSource = nil
        let needsPermanent = pendingSSHNeedsPermanent
        pendingSSHNeedsPermanent = false

        var effective = source
        if needsPermanent, var ssh = source as? SSHSource {
            ssh.allowPermanentDelete = true
            effective = ssh
        }
        let results = await performTrash(nodes: pending.nodes, source: effective)

        if let next = pendingQueue.first {
            pendingQueue.removeFirst()
            stagePending(nodes: next.nodes, source: next.source)
        }

        return results
    }

    /// Trash via source, then remove successes from `ScanIndex` (reaggregates ancestors) and persist SQLite.
    @discardableResult
    func performTrash(nodes: [StorageNode], source: any ScanSource) async -> [RemovalResult] {
        guard !nodes.isEmpty else { return [] }

        let results: [RemovalResult]
        do {
            results = try await source.trash(nodes: nodes)
        } catch {
            return nodes.map { .failed(nodeId: $0.id, message: error.localizedDescription) }
        }

        var successIDs = Set<String>()
        for result in results {
            switch result {
            case .movedToTrash(let nodeId):
                successIDs.insert(nodeId)
            case .failed:
                break
            }
        }

        if !successIDs.isEmpty {
            // Collect affected locations before remove (nodes leave the index).
            var affectedLocationIds = Set<UUID>()
            for id in successIDs {
                if let n = await index.node(id: id) {
                    affectedLocationIds.insert(n.locationId)
                }
            }
            // Also include locationIds from the request nodes (covers any id mapping edge).
            for n in nodes where successIDs.contains(n.id) {
                affectedLocationIds.insert(n.locationId)
            }

            // `remove` drops descendants and reaggregates surviving ancestors.
            await index.remove(ids: successIDs)
            await persistRemainingNodes(for: affectedLocationIds)
        }

        return results
    }

    // MARK: - Private

    /// Rewrite SQLite for each location so trashed nodes do not reappear on load.
    private func persistRemainingNodes(for locationIds: Set<UUID>) async {
        guard let store, !locationIds.isEmpty else { return }
        for locationId in locationIds {
            let remaining = await index.nodes(for: locationId)
            if remaining.isEmpty {
                try? await store.delete(locationId: locationId)
            } else {
                try? await store.save(nodes: remaining)
            }
        }
    }

    private func stagePending(nodes: [StorageNode], source: any ScanSource) {
        let kind = sourceKindHint(for: source)
        var requiresStrong = false
        var detail: String? = nil
        pendingSSHNeedsPermanent = false
        let includesRoot = PendingTrashRequest.includesScanRoot(nodes)

        if let ssh = source as? SSHSource {
            if ssh.requiresPermanentDeleteConfirm {
                requiresStrong = true
                pendingSSHNeedsPermanent = true
                detail =
                    "No remote trash path is configured. Type \(PendingTrashRequest.strongConfirmPhrase) to permanently delete."
            } else {
                detail = "Items will be renamed into the configured remote trash path."
            }
        }

        if includesRoot, !requiresStrong {
            let rootDetail =
                "Selection includes a scan root folder. Local/cloud items go to Trash only (not permanent delete), but Cistilka will drop the whole tree from the index."
            detail = detail.map { "\($0) \(rootDetail)" } ?? rootDetail
        } else if includesRoot, requiresStrong {
            let rootDetail = "Selection includes a scan root."
            detail = detail.map { "\($0) \(rootDetail)" } ?? rootDetail
        }

        if pendingQueue.count > 0 {
            let extra =
                "\(pendingQueue.count) more source group\(pendingQueue.count == 1 ? "" : "s") will be confirmed next."
            detail = detail.map { "\($0) \(extra)" } ?? extra
        }

        pendingSource = source
        pendingTrash = PendingTrashRequest(
            nodes: nodes,
            sourceKindToken: kind,
            requiresStrongConfirm: requiresStrong,
            detailMessage: detail,
            remainingGroupCount: pendingQueue.count,
            includesScanRoot: includesRoot
        )
    }

    private func sourceKindHint(for source: any ScanSource) -> SourceKind {
        if source is LocalDiskSource { return .local }
        if source is GoogleDriveSource { return .googleDrive }
        if source is OneDriveSource { return .oneDrive }
        if source is SSHSource { return .ssh }
        return .local
    }
}
