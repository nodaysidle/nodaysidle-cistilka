import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    private var defaultRoots: [String] {
        model.preferences.resolvedDefaultRoots
    }

    var body: some View {
        ContentUnavailableView {
            Label("Cistilka", systemImage: "internaldrive")
        } description: {
            Text("Scan a folder on this Mac to see what’s taking up space. Move items to Trash when you’re ready.")
        } actions: {
            VStack(spacing: 12) {
                ForEach(Array(defaultRoots.enumerated()), id: \.element) { index, path in
                    defaultRootButton(path: path, isPrimary: index == 0)
                }

                Button {
                    model.scanVolume()
                } label: {
                    Label("Scan folder or volume…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: 280)
                }
                .controlSize(.large)
                .modifier(ProminentWhenEmpty(isEmpty: defaultRoots.isEmpty))

                Text("Tip: grant Full Disk Access for a complete scan of Home and system folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 8)

                Button {
                    model.presentFDACoach()
                } label: {
                    Label("Full Disk Access help", systemImage: "lock.shield")
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func defaultRootButton(path: String, isPrimary: Bool) -> some View {
        let title = AppPreferences.displayName(forDefaultRoot: path)
        let isHome = title == "Home"
        let button = Button {
            model.scanDefaultRoot(path: path)
        } label: {
            Label(
                "Scan \(title)",
                systemImage: AppPreferences.systemImage(forDefaultRoot: path)
            )
            .frame(maxWidth: 280)
        }
        .controlSize(.large)
        .help(path)

        if isPrimary {
            if isHome {
                button
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            } else {
                button.buttonStyle(.borderedProminent)
            }
        } else if isHome {
            button.keyboardShortcut("h", modifiers: [.command, .shift])
        } else {
            button
        }
    }
}

/// Makes Scan volume prominent only when there are no configured default roots.
private struct ProminentWhenEmpty: ViewModifier {
    let isEmpty: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEmpty {
            content.buttonStyle(.borderedProminent)
        } else {
            content
        }
    }
}
