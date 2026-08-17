import SwiftUI

struct ReviewControlsView: View {
    @ObservedObject var store: ReviewStore

    var body: some View {
        HStack(spacing: 18) {
            actionButton(
                title: "Keep",
                key: "K",
                systemImage: "checkmark",
                tint: .green,
                action: .keep
            )

            Button(role: .destructive) {
                perform(.trash)
            } label: {
                actionLabel(title: "Trash", key: "⌫", systemImage: "trash")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(store.isBusy)
            .accessibilityLabel("Trash photo")
            .accessibilityHint("Moves the current photo to the macOS Trash")

            actionButton(
                title: "Pass",
                key: "Space",
                systemImage: "arrow.right",
                tint: .accentColor,
                action: .pass
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func actionButton(
        title: String,
        key: String,
        systemImage: String,
        tint: Color,
        action: ReviewAction
    ) -> some View {
        Button {
            perform(action)
        } label: {
            actionLabel(title: title, key: key, systemImage: systemImage)
                .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .disabled(store.isBusy)
        .accessibilityLabel("\(title) photo")
    }

    private func actionLabel(title: String, key: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(title)
                .fontWeight(.semibold)
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.vertical, 4)
    }

    private func perform(_ action: ReviewAction) {
        Task {
            await store.perform(action)
        }
    }
}
