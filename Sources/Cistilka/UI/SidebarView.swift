import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(
            get: { model.selectedLocationID },
            set: { model.selectLocation($0) }
        )) {
            Section("This Mac") {
                ForEach(model.localLocations) { location in
                    LocationRow(location: location)
                        .tag(location.id)
                        .contextMenu {
                            locationContextMenu(location)
                        }
                }
                if model.localLocations.isEmpty {
                    Text("No local scans yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                ForEach(model.preferences.resolvedDefaultRoots, id: \.self) { path in
                    let title = AppPreferences.displayName(forDefaultRoot: path)
                    Button {
                        model.scanDefaultRoot(path: path)
                    } label: {
                        Label(
                            "Scan \(title)",
                            systemImage: AppPreferences.systemImage(forDefaultRoot: path)
                        )
                    }
                    .help(path)
                }
            }

            // Cloud / SSH stay available in Settings → Accounts for advanced use.
            // Local Mac scanning is the default product surface.

            Section("Scans") {
                if model.scanningLocations.isEmpty {
                    Text("No active scans")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(model.scanningLocations) { location in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.displayName)
                                if let progress = model.coordinator?.progress[location.id] {
                                    Text(progressSummary(progress))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                        .tag(location.id)
                    }
                }

                let recent = model.locations
                    .filter { $0.scanState == .complete || $0.scanState == .cancelled || $0.scanState == .failed }
                    .sorted { ($0.lastScannedAt ?? .distantPast) > ($1.lastScannedAt ?? .distantPast) }
                ForEach(recent.prefix(8)) { location in
                    Label(location.displayName, systemImage: statusSymbol(location.scanState))
                        .tag(location.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Locations")
    }

    @ViewBuilder
    private func locationContextMenu(_ location: ScanLocation) -> some View {
        Button("Rescan") {
            model.selectLocation(location.id)
            model.rescanSelected()
        }
        Button("Reveal Root") {
            if location.sourceKind == .local {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.rootRef)])
            }
        }
        Divider()
        Button("Remove from List", role: .destructive) {
            model.removeLocation(location.id)
        }
    }

    private func progressSummary(_ p: ScanProgress) -> String {
        let files = p.filesVisited
        let dirs = p.dirsVisited
        let bytes = ByteFormat.string(bytes: p.bytesSeen)
        return "\(dirs) dirs · \(files) files · \(bytes)"
    }

    private func statusSymbol(_ state: ScanState) -> String {
        switch state {
        case .idle: return "circle"
        case .scanning: return "arrow.triangle.2.circlepath"
        case .complete: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

private struct LocationRow: View {
    let location: ScanLocation

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(location.displayName)
                Text(location.rootRef)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        switch location.sourceKind {
        case .local: return "internaldrive"
        case .googleDrive: return "cloud"
        case .oneDrive: return "cloud"
        case .ssh: return "server.rack"
        }
    }
}
