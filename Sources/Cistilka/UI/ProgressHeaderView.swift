import AppKit
import SwiftUI

struct ProgressHeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let location = model.selectedLocation, location.scanState == .scanning {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning \(location.displayName)…")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let progress = model.currentProgress {
                        Text(summary(progress))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop") {
                        model.stopSelected()
                    }
                    .controlSize(.small)
                }
                if let path = model.currentProgress?.currentPath, !path.isEmpty {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
        } else if let status = model.statusMessage, !status.isEmpty {
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func summary(_ p: ScanProgress) -> String {
        "\(p.dirsVisited) dirs · \(p.filesVisited) files · \(ByteFormat.string(bytes: p.bytesSeen))"
    }
}
