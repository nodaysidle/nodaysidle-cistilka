import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                selectionSection
                Divider()
                typeTotalsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Selection

    @ViewBuilder
    private var selectionSection: some View {
        Text("Selection")
            .font(.headline)

        if model.selectedNodes.isEmpty {
            Text("Select an item in the tree.")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else if model.selectedNodes.count == 1, let node = model.selectedNodes.first {
            singleSelection(node)
        } else {
            multiSelection
        }
    }

    private func singleSelection(_ node: StorageNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Name", node.name)
            labeled("Kind", node.nodeKind.rawValue)
            labeled("Size", ByteFormat.string(bytes: node.byteSize))
            labeled("Items", node.itemCount.formatted())
            labeled("Path", node.logicalPath)
            if let ext = node.fileExtension {
                labeled("Extension", ext)
            }
            if node.permissionsState != .ok {
                labeled("Permissions", node.permissionsState.rawValue)
            }
            if let modified = node.modifiedAt {
                labeled("Modified", modified.formatted(date: .abbreviated, time: .shortened))
            }

            HStack {
                Button("Reveal") {
                    model.revealNode(node)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.logicalPath, forType: .string)
                }
                Button("Trash", role: .destructive) {
                    model.requestTrash(nodes: [node])
                }
                .disabled(node.permissionsState == .denied || !model.canTrashCurrentSelection)
            }
            .controlSize(.small)
        }
        .font(.callout)
    }

    private var multiSelection: some View {
        let totalBytes = model.selectedNodes.reduce(Int64(0)) { $0 + $1.byteSize }
        let totalItems = model.selectedNodes.reduce(Int64(0)) { $0 + $1.itemCount }
        let trashable = model.trashableSelectedNodes.count
        return VStack(alignment: .leading, spacing: 8) {
            labeled("Count", "\(model.selectedNodes.count) items")
            labeled("Total size", ByteFormat.string(bytes: totalBytes))
            labeled("Total items", totalItems.formatted())
            if trashable < model.selectedNodes.count {
                labeled("Trashable", "\(trashable) of \(model.selectedNodes.count)")
            }
            Button("Move to Trash", role: .destructive) {
                model.requestTrashForSelection()
            }
            .controlSize(.small)
            .disabled(!model.canTrashCurrentSelection)
        }
        .font(.callout)
    }

    // MARK: - Type totals

    private var typeTotalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Types")
                .font(.headline)

            if model.typeTotals.isEmpty {
                Text("No type totals yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(Array(model.typeTotals.prefix(40)), id: \.fileExtension) { total in
                    HStack {
                        Text(total.fileExtension)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text("\(total.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(ByteFormat.string(bytes: total.bytes))
                            .font(.caption.monospacedDigit())
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
