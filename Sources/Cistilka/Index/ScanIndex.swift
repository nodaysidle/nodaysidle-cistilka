import Foundation

/// In-memory storage tree: flat node map + parent→children adjacency.
actor ScanIndex {
    private var nodes: [String: StorageNode] = [:]
    /// Parent key `""` for forest roots (`parentId == nil`).
    private var childrenByParent: [String: [String]] = [:]

    // MARK: - Mutations

    /// Upsert a batch of nodes at `generation`. Re-sorts affected sibling lists.
    func apply(batch: [StorageNode], generation: UInt64) async {
        var dirtyParents = Set<String>()
        for var n in batch {
            n.scanGeneration = generation

            if let existing = nodes[n.id] {
                let oldKey = Self.parentKey(existing.parentId)
                let newKey = Self.parentKey(n.parentId)
                if oldKey != newKey {
                    removeFromChildrenList(id: n.id, parentKey: oldKey)
                    dirtyParents.insert(oldKey)
                }
            }

            nodes[n.id] = n
            let key = Self.parentKey(n.parentId)
            var list = childrenByParent[key] ?? []
            if !list.contains(n.id) {
                list.append(n.id)
            }
            childrenByParent[key] = list
            dirtyParents.insert(key)
        }
        for key in dirtyParents {
            sortChildren(parentKey: key)
        }
    }

    /// Set finalized directory aggregates (scanner-provided).
    func finalizeDirectory(id: String, byteSize: Int64, itemCount: Int64) async {
        guard var node = nodes[id] else { return }
        node.byteSize = byteSize
        node.itemCount = itemCount
        nodes[id] = node
        if let parentId = node.parentId {
            sortChildren(parentKey: Self.parentKey(parentId))
        } else {
            sortChildren(parentKey: "")
        }
    }

    /// Bottom-up recompute of ancestor folder sizes/counts from direct children.
    func reaggregateAncestors(from nodeId: String) async {
        guard let start = nodes[nodeId] else { return }
        var currentParentId = start.parentId
        while let parentId = currentParentId {
            guard var parent = nodes[parentId] else { break }
            let childIds = childrenByParent[parentId] ?? []
            var totalBytes: Int64 = 0
            var totalItems: Int64 = 0
            for cid in childIds {
                guard let child = nodes[cid] else { continue }
                totalBytes += child.byteSize
                totalItems += child.itemCount
            }
            parent.byteSize = totalBytes
            parent.itemCount = totalItems
            nodes[parentId] = parent
            sortChildren(parentKey: Self.parentKey(parent.parentId))
            currentParentId = parent.parentId
        }
    }

    /// Remove nodes and all descendants; reaggregate parents and drop empty child lists.
    func remove(ids: Set<String>) async {
        var toRemove = Set<String>()
        for id in ids {
            collectDescendants(id: id, into: &toRemove)
            toRemove.insert(id)
        }

        var parentsToFix = Set<String?>()
        for id in toRemove {
            guard let node = nodes[id] else { continue }
            parentsToFix.insert(node.parentId)
            removeFromChildrenList(id: id, parentKey: Self.parentKey(node.parentId))
            nodes.removeValue(forKey: id)
            childrenByParent.removeValue(forKey: id)
        }

        // Clean parent keys that are themselves removed.
        for parentId in parentsToFix {
            if let parentId, toRemove.contains(parentId) { continue }
            let key = Self.parentKey(parentId)
            if let list = childrenByParent[key], list.isEmpty {
                childrenByParent.removeValue(forKey: key)
            } else {
                sortChildren(parentKey: key)
            }
        }

        // Reaggregate surviving parents (deepest first via repeated walk).
        var reaggSeeds = Set<String>()
        for parentId in parentsToFix {
            guard let parentId, nodes[parentId] != nil else { continue }
            reaggSeeds.insert(parentId)
        }
        for seed in reaggSeeds {
            // Sum this folder from children, then walk up.
            if var folder = nodes[seed] {
                let childIds = childrenByParent[seed] ?? []
                var totalBytes: Int64 = 0
                var totalItems: Int64 = 0
                for cid in childIds {
                    guard let child = nodes[cid] else { continue }
                    totalBytes += child.byteSize
                    totalItems += child.itemCount
                }
                folder.byteSize = totalBytes
                folder.itemCount = totalItems
                nodes[seed] = folder
            }
            await reaggregateAncestors(from: seed)
        }
    }

    /// Drop nodes for `locationId` whose generation is not `keeping`.
    func discardGeneration(locationId: UUID, keeping generation: UInt64) async {
        let stale = nodes.values
            .filter { $0.locationId == locationId && $0.scanGeneration != generation }
            .map(\.id)
        guard !stale.isEmpty else { return }
        await remove(ids: Set(stale))
    }

    // MARK: - Queries

    func node(id: String) async -> StorageNode? {
        nodes[id]
    }

    /// Children of `parentId` (nil = forest roots), sorted size descending.
    func children(of parentId: String?) async -> [StorageNode] {
        let key = Self.parentKey(parentId)
        let ids = childrenByParent[key] ?? []
        return ids.compactMap { nodes[$0] }
    }

    /// All nodes belonging to `locationId` (any generation).
    func nodes(for locationId: UUID) -> [StorageNode] {
        nodes.values.filter { $0.locationId == locationId }
    }

    /// Drop every node (all locations). Used by “Clear cached scans”.
    func removeAll() async {
        nodes.removeAll(keepingCapacity: false)
        childrenByParent.removeAll(keepingCapacity: false)
    }

    /// Drop every node for `locationId`.
    func removeAll(for locationId: UUID) async {
        let ids = Set(nodes.values.filter { $0.locationId == locationId }.map(\.id))
        guard !ids.isEmpty else { return }
        await remove(ids: ids)
    }

    // MARK: - Internals

    private static func parentKey(_ parentId: String?) -> String {
        parentId ?? ""
    }

    private func removeFromChildrenList(id: String, parentKey: String) {
        guard var list = childrenByParent[parentKey] else { return }
        list.removeAll { $0 == id }
        if list.isEmpty {
            childrenByParent.removeValue(forKey: parentKey)
        } else {
            childrenByParent[parentKey] = list
        }
    }

    private func sortChildren(parentKey: String) {
        guard var list = childrenByParent[parentKey] else { return }
        list.sort { lhs, rhs in
            let a = nodes[lhs]
            let b = nodes[rhs]
            let sizeA = a?.byteSize ?? 0
            let sizeB = b?.byteSize ?? 0
            if sizeA != sizeB { return sizeA > sizeB }
            let nameA = a?.name ?? lhs
            let nameB = b?.name ?? rhs
            if nameA != nameB { return nameA.localizedStandardCompare(nameB) == .orderedAscending }
            return lhs < rhs
        }
        childrenByParent[parentKey] = list
    }

    private func collectDescendants(id: String, into set: inout Set<String>) {
        let kids = childrenByParent[id] ?? []
        for kid in kids {
            set.insert(kid)
            collectDescendants(id: kid, into: &set)
        }
    }

    /// Files under scope for type-total computation (internal to extension).
    func fileNodes(scopeRootId: String?) -> [StorageNode] {
        if let rootId = scopeRootId {
            var collected: [StorageNode] = []
            collectFiles(under: rootId, into: &collected)
            return collected
        }
        return nodes.values.filter { $0.nodeKind == .file }
    }

    private func collectFiles(under id: String, into out: inout [StorageNode]) {
        // Include the node itself if it is a file (unusual for scope root).
        if let node = nodes[id], node.nodeKind == .file {
            out.append(node)
        }
        for childId in childrenByParent[id] ?? [] {
            collectFiles(under: childId, into: &out)
        }
    }
}
