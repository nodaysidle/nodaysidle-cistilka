import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var inspectorPresented = true

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detailColumn
        }
        .navigationTitle(model.selectedLocation?.displayName ?? "Cistilka")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.addLocation()
                } label: {
                    Label("Add Location", systemImage: "plus")
                }
                .help("Add a folder or volume to scan")

                Button {
                    model.rescanSelected()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.selectedLocation == nil)
                .help("Rescan the selected location")

                Button {
                    model.stopSelected()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!(model.selectedLocation?.scanState == .scanning))
                .help("Stop the current scan")
            }

            ToolbarItem(placement: .automatic) {
                TextField("Search", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)
                    .onChange(of: model.searchQuery) { _, _ in
                        Task { await model.refreshSnapshots() }
                    }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle inspector")
            }
        }
        .alert(
            "Coming soon",
            isPresented: Binding(
                get: { model.pendingNotice != nil },
                set: { if !$0 { model.clearPendingNotice() } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.clearPendingNotice()
            }
        } message: {
            Text(model.pendingNotice ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { model.isTrashConfirmPresented },
                set: { model.isTrashConfirmPresented = $0 }
            )
        ) {
            if let pending = model.removalService.pendingTrash {
                ConfirmTrashSheet(
                    message: pending.confirmationMessage,
                    detailMessage: pending.detailMessage,
                    requiresStrongConfirm: pending.requiresStrongConfirm,
                    onConfirm: { model.confirmTrash() },
                    onCancel: { model.cancelTrashConfirm() }
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.needsFDACoach },
                set: { if !$0 { model.dismissFDACoach() } }
            )
        ) {
            PermissionCoachSheet()
                .environment(model)
        }
        .sheet(
            isPresented: Binding(
                get: { model.isSSHProfileSheetPresented },
                set: { newValue in
                    if !newValue {
                        model.dismissSSHProfileSheet()
                    } else {
                        model.isSSHProfileSheetPresented = true
                    }
                }
            )
        ) {
            SSHProfileSheet(existingProfile: model.editingSSHProfile)
                .environment(model)
        }
        // Global ⌘⌫ — same path as context menu.
        .background {
            Button("Move to Trash") {
                model.requestTrashForSelection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        let showEmpty = model.locations.isEmpty && model.treeRows.isEmpty
            && model.selectedLocation?.scanState != .scanning

        HSplitView {
            VStack(spacing: 0) {
                ProgressHeaderView()
                if showEmpty {
                    EmptyStateView()
                } else if model.selectedLocationID == nil {
                    EmptyStateView()
                } else {
                    TreeTableView()
                }
                // Drag-to-trash bar: visible with selection or during drag (same RemovalService path as ⌘⌫).
                TrashDropBar()
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            if inspectorPresented {
                InspectorView()
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 960, height: 640)
}
