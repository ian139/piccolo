import SwiftUI

struct PhotoReviewView: View {
    @ObservedObject var store: ReviewStore

    var body: some View {
        Group {
            if !store.reviewStarted {
                setupView
            } else if store.isActiveReviewVisible, let item = store.currentItem {
                activeReview(item: item)
            } else {
                summaryView
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await store.reload()
        }
        .alert(item: $store.presentedError) { error in
            Alert(
                title: Text(error.headline),
                message: Text(error.details),
                dismissButton: .default(Text("OK"), action: store.dismissError)
            )
        }
    }

    private var setupView: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Photo Review")
                .font(.largeTitle)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 18) {
                folderRow(
                    title: "Photo folder",
                    path: store.sourceURL?.path,
                    buttonTitle: "Choose Photo Folder"
                ) {
                    await store.choosePhotoFolder()
                }
                folderRow(
                    title: "Keep folder",
                    path: store.keepDestinationURL?.path,
                    buttonTitle: "Choose Keep Folder"
                ) {
                    await store.chooseKeepFolder()
                }
            }
            .frame(maxWidth: 680)

            Button("Start Reviewing") {
                store.startReviewing()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canStartReviewing)
            .accessibilityHint("Begins reviewing the selected photo folder")

            Spacer()
        }
        .padding(40)
    }

    private func folderRow(
        title: String,
        path: String?,
        buttonTitle: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            HStack(spacing: 12) {
                Text(path ?? "Not selected")
                    .foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(buttonTitle) {
                    Task { await action() }
                }
                .disabled(store.isBusy)
            }
        }
    }

    private func activeReview(item: PhotoItem) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Reviewed \(store.completedCount) of \(store.totalCount)")
                    .font(.headline)
                Spacer()
                if store.phase == .initial {
                    Text("\(store.persistedPassedCount) passed")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            PhotoCanvasView(store: store, item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ReviewControlsView(store: store)
        }
        .padding(20)
    }

    private var summaryView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(store.hasPassedPhotos ? "Round Complete" : "Review Complete")
                .font(.largeTitle)
                .fontWeight(.semibold)

            HStack(spacing: 32) {
                summaryCount(store.keptCount, label: "Kept")
                summaryCount(store.trashedCount, label: "Trashed")
                summaryCount(store.passedCount, label: "Passed")
            }
            .accessibilityElement(children: .combine)

            if store.hasPassedPhotos {
                Button("Review Passed Photos") {
                    store.startPassedReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isBusy)
            }

            Button("Choose Another Folder") {
                Task { await store.chooseAnotherFolder() }
            }
            .controlSize(.large)
            .disabled(store.isBusy)

            Spacer()
        }
        .padding(40)
    }

    private func summaryCount(_ count: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text(count, format: .number)
                .font(.title)
                .fontWeight(.semibold)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 90)
    }
}
