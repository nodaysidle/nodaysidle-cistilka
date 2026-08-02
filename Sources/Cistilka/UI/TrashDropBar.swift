import SwiftUI
import UniformTypeIdentifiers

/// Bottom drop target: drag tree rows here (or click) to move to Trash via RemovalService.
struct TrashDropBar: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        let selectionCount = model.selectedNodeIDs.count
        let trashableCount = model.trashableSelectedNodes.count
        let canTrashSelection = model.canTrashCurrentSelection
        let showBar = selectionCount > 0 || isTargeted || model.isNodeDragActive
        let highlighted = isTargeted && (canAcceptDrop || canTrashSelection)

        Group {
            if showBar {
                barContent(
                    selectionCount: selectionCount,
                    trashableCount: trashableCount,
                    canTrashSelection: canTrashSelection,
                    highlighted: highlighted
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showBar)
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
    }

    private var canAcceptDrop: Bool {
        // While dragging, accept if current selection is trashable or drop payload will be resolved later.
        // Actual eligibility is re-checked on drop via AppModel.
        model.canTrashCurrentSelection || model.isNodeDragActive
    }

    private func barContent(
        selectionCount: Int,
        trashableCount: Int,
        canTrashSelection: Bool,
        highlighted: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: highlighted ? "trash.fill" : "trash")
                .font(.title3)
                .foregroundStyle(iconColor(highlighted: highlighted, canTrash: canTrashSelection))

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLabel(selectionCount: selectionCount, trashableCount: trashableCount, highlighted: highlighted))
                    .font(.callout.weight(.semibold))
                Text(secondaryLabel(selectionCount: selectionCount, trashableCount: trashableCount, canTrash: canTrashSelection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if selectionCount > 0 {
                Button("Move to Trash", role: .destructive) {
                    model.requestTrashForSelection()
                }
                .controlSize(.small)
                .disabled(!canTrashSelection)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(background(highlighted: highlighted, canTrash: canTrashSelection))
        .overlay(alignment: .top) {
            Divider()
        }
        .dropDestination(for: StorageNodeIDList.self) { items, _ in
            let ids = items.flatMap(\.ids)
            guard !ids.isEmpty else { return false }
            return model.handleTrashDrop(nodeIDs: ids)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trash drop bar")
        .accessibilityHint("Drop selected items here to move them to Trash")
    }

    private func primaryLabel(selectionCount: Int, trashableCount: Int, highlighted: Bool) -> String {
        if highlighted {
            return "Drop to move to Trash"
        }
        if selectionCount == 0 {
            return "Drop to move to Trash"
        }
        if trashableCount == 0 {
            return "Cannot trash selection"
        }
        if selectionCount == 1 {
            return "1 item selected"
        }
        return "\(selectionCount) items selected"
    }

    private func secondaryLabel(selectionCount: Int, trashableCount: Int, canTrash: Bool) -> String {
        if selectionCount == 0 {
            return "Drag files or folders from the tree"
        }
        if !canTrash {
            if model.selectedLocation.flatMap({ model.scanSource(for: $0)?.supportsTrash }) == false {
                return "This source does not support Trash"
            }
            return "Permission denied or unsupported items"
        }
        if trashableCount < selectionCount {
            return "\(trashableCount) of \(selectionCount) can be moved to Trash"
        }
        let bytes = model.trashableSelectedNodes.reduce(Int64(0)) { $0 + $1.byteSize }
        return "\(ByteFormat.string(bytes: bytes)) · same as menu / ⌘⌫"
    }

    private func iconColor(highlighted: Bool, canTrash: Bool) -> Color {
        if highlighted { return .red }
        if !canTrash && model.selectedNodeIDs.count > 0 { return .secondary }
        return .primary
    }

    private func background(highlighted: Bool, canTrash: Bool) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(
                highlighted
                    ? Color.red.opacity(0.18)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(Color.red.opacity(0.55), lineWidth: 2)
                }
            }
            .opacity((!canTrash && model.selectedNodeIDs.count > 0 && !highlighted) ? 0.85 : 1)
    }
}
