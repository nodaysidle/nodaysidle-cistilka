import AppKit
import SwiftUI

/// General preferences: packages, scan parallelism, default roots, clear cache.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClearCache = false

    var body: some View {
        @Bindable var prefs = model.preferences

        Form {
            Section {
                Text(AppIdentity.name)
                    .font(.headline)
                Text("Scan performance and local defaults")
                    .foregroundStyle(.secondary)
            }

            Section("Packages") {
                Toggle("Treat packages as leaf", isOn: $prefs.treatPackagesAsLeaf)
                Text(
                    prefs.treatPackagesAsLeaf
                        ? "Apps and bundles are sized as one item (recommended)."
                        : "Packages are expanded like folders (slower; more detail)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Parallelism") {
                Picker("Local scan workers", selection: $prefs.scanParallelism) {
                    ForEach(ScanParallelism.allCases) { level in
                        Text("\(level.displayName) (\(level.localWorkers))")
                            .tag(level)
                    }
                }
                .onChange(of: prefs.scanParallelism) { _, _ in
                    model.applyScanParallelismPreference()
                }
                Text(prefs.scanParallelism.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Gentle uses fewer workers (lower CPU). Aggressive speeds large local trees.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default scan roots") {
                Toggle("Include Home in defaults", isOn: $prefs.includeHomeInDefaults)
                Text("Home and custom folders appear as quick-start targets. Use Scan Volume… for one-off paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(prefs.defaultRootPaths, id: \.self) { path in
                    HStack {
                        Label(path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            prefs.removeDefaultRoot(path)
                        }
                    }
                }

                Button("Add folder…") {
                    addDefaultRoot()
                }
            }

            Section("Cache") {
                Text("Removes stored scan trees from disk and memory. Locations and accounts are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear cached scans…", role: .destructive) {
                    confirmClearCache = true
                }
            }

            Section("Appearance") {
                Text("Cistilka follows system light/dark appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 320)
        .confirmationDialog(
            "Clear all cached scan data?",
            isPresented: $confirmClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear cached scans", role: .destructive) {
                model.clearCachedScans()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In-memory and SQLite trees for every location will be deleted. Rescan to rebuild.")
        }
    }

    private func addDefaultRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a default scan root"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.preferences.addDefaultRoot(url.standardizedFileURL.path)
    }
}

#Preview {
    GeneralSettingsView()
        .environment(AppModel())
}
