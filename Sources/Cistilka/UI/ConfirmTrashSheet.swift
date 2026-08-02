import SwiftUI

/// Confirmation dialog before moving items to Trash (or permanent SSH delete).
struct ConfirmTrashSheet: View {
    let message: String
    var detailMessage: String? = nil
    var requiresStrongConfirm: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var typedConfirm: String = ""

    private var canConfirm: Bool {
        if requiresStrongConfirm {
            return typedConfirm == PendingTrashRequest.strongConfirmPhrase
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(requiresStrongConfirm ? "Permanent delete" : "Move to Trash")
                .font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if let detailMessage {
                Text(detailMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if requiresStrongConfirm {
                Text("Type \(PendingTrashRequest.strongConfirmPhrase) to confirm:")
                    .font(.caption)
                TextField(PendingTrashRequest.strongConfirmPhrase, text: $typedConfirm)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(
                    requiresStrongConfirm ? "Delete permanently" : "Move to Trash",
                    role: .destructive,
                    action: onConfirm
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
