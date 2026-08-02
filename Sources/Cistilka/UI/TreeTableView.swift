import AppKit
import SwiftUI

struct TreeTableView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            columnHeader
            Divider()
            if model.treeRows.isEmpty {
                emptyTree
            } else {
                treeList
            }
        }
    }

    // MARK: - Breadcrumbs

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        if crumb.id.hasPrefix("location:") {
                            model.focusNode(id: nil)
                        } else {
                            model.focusNode(id: crumb.id)
                        }
                    } label: {
                        Text(crumb.title)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
            Text("Items")
                .frame(width: 72, alignment: .trailing)
            Text("Size")
                .frame(width: 88, alignment: .trailing)
            Text("% Parent")
                .frame(width: 120, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - List

    private var treeList: some View {
        List(selection: Binding(
            get: { model.selectedNodeIDs },
            set: { model.updateSelection($0) }
        )) {
            ForEach(model.treeRows) { row in
                TreeRowView(row: row) {
                    model.toggleExpanded(id: row.id)
                }
                .tag(row.id)
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 8))
                .draggable(StorageNodeIDList(ids: model.dragPayloadIDs(for: row.id))) {
                    // Preview: multi-select count when dragging the selection.
                    let ids = model.dragPayloadIDs(for: row.id)
                    HStack(spacing: 6) {
                        Image(systemName: ids.count > 1 ? "doc.on.doc" : "doc")
                        Text(ids.count == 1 ? row.name : "\(ids.count) items")
                            .lineLimit(1)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .onAppear { model.isNodeDragActive = true }
                    .onDisappear { model.isNodeDragActive = false }
                }
                .contextMenu {
                    if row.isDirectoryLike {
                        Button("Focus Here") {
                            model.focusNode(id: row.id)
                        }
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.logicalPath, forType: .string)
                    }
                    Button("Reveal in Finder") {
                        if let node = model.selectedNodes.first(where: { $0.id == row.id }) {
                            model.revealNode(node)
                        } else {
                            Task {
                                if let node = await model.index.node(id: row.id) {
                                    model.revealNode(node)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        model.requestTrashFromContext(rowID: row.id)
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(row.permissionsState == .denied)
                }
                .onTapGesture(count: 2) {
                    if row.isDirectoryLike {
                        model.focusNode(id: row.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 22)
    }

    private var emptyTree: some View {
        ContentUnavailableView {
            Label("No items", systemImage: "folder")
        } description: {
            if model.selectedLocation?.scanState == .scanning {
                Text("Scan in progress…")
            } else if !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No names match “\(model.searchQuery)”.")
            } else {
                Text("Run a scan to populate the tree.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TreeRowView: View {
    let row: TreeOutlineRow
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Color.clear.frame(width: CGFloat(row.depth) * 14)

                if row.isDirectoryLike {
                    Button(action: onToggle) {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }

                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if row.permissionsState == .denied {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.itemCount.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            Text(ByteFormat.string(bytes: row.byteSize))
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            PercentParentBar(fraction: row.percentOfParent)
                .frame(width: 120)
                .padding(.leading, 8)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch row.nodeKind {
        case .folder: return "folder.fill"
        case .file: return "doc"
        case .symlink: return "link"
        case .package: return "shippingbox.fill"
        case .unknown: return "questionmark.square"
        }
    }

    private var iconColor: Color {
        switch row.nodeKind {
        case .folder: return .blue
        case .package: return .purple
        case .symlink: return .secondary
        case .file: return .secondary
        case .unknown: return .orange
        }
    }
}

struct PercentParentBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(2, geo.size.width * clamped))
                Text(percentLabel)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: clamped > 0.55 ? .leading : .trailing)
            }
        }
        .frame(height: 14)
        .help(percentLabel)
    }

    private var percentLabel: String {
        let pct = min(max(fraction, 0), 1) * 100
        if pct >= 10 {
            return String(format: "%.0f%%", pct)
        }
        if pct >= 1 {
            return String(format: "%.1f%%", pct)
        }
        if fraction > 0 {
            return "<1%"
        }
        return "0%"
    }
}
