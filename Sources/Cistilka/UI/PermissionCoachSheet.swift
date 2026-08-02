import SwiftUI

/// Explains Full Disk Access, opens Settings, and supports re-check / diagnostics export.
struct PermissionCoachSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Full Disk Access recommended", systemImage: "lock.shield.fill")
                .font(.title2.weight(.semibold))

            Text(
                """
                Cistilka could not read many folders (or your Home scan looks incomplete). \
                macOS protects Mail, Safari, and other libraries unless Full Disk Access is enabled.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let passed = model.fdaRecheckPassed {
                HStack(spacing: 8) {
                    Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(passed ? .green : .orange)
                    Text(passed
                         ? "Re-check passed — protected folders are readable. Rescan Home for full results."
                         : "Still blocked — enable Cistilka under Full Disk Access, then re-check.")
                        .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Steps")
                    .font(.headline)
                Text("1. Open System Settings → Privacy & Security → Full Disk Access.")
                Text("2. Enable Cistilka (or add the app if missing).")
                Text("3. Return here, re-check, then rescan.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            HStack {
                Button("Open Full Disk Access…") {
                    model.openFullDiskAccessSettings()
                }
                .keyboardShortcut(.defaultAction)

                Button("Re-check") {
                    model.recheckFullDiskAccess()
                }

                Spacer()

                Button("Export diagnostics…") {
                    model.exportDiagnostics()
                }
            }

            HStack {
                Button("Copy instructions") {
                    PermissionCoach.copyFullDiskAccessInstructions()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Not now") {
                    model.dismissFDACoach()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 460)
    }
}

#Preview {
    PermissionCoachSheet()
        .environment(AppModel())
}
