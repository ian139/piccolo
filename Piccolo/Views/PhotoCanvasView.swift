import CoreGraphics
import SwiftUI

struct PhotoCanvasView: View {
    private enum PreviewState {
        case loading
        case available(CGImage)
        case unavailable
    }

    private struct PreviewRequest: Hashable {
        let itemID: PhotoItem.ID
        let maximumPixelDimension: Int
    }

    @ObservedObject var store: ReviewStore
    let item: PhotoItem

    @Environment(\.displayScale) private var displayScale
    @State private var previewState: PreviewState = .loading

    var body: some View {
        GeometryReader { geometry in
            let maximumPixelDimension = max(
                1,
                Int(max(geometry.size.width, geometry.size.height) * displayScale)
            )

            VStack(spacing: 12) {
                ZStack {
                    Color(white: 0.075)
                    previewContent
                        .padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Preview of \(item.url.lastPathComponent)")

                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Filename: \(item.url.lastPathComponent)")
            }
            .task(id: PreviewRequest(itemID: item.id, maximumPixelDimension: maximumPixelDimension)) {
                previewState = .loading
                let image = await store.preview(
                    for: item,
                    maximumPixelDimension: maximumPixelDimension
                )
                guard !Task.isCancelled else { return }
                previewState = image.map(PreviewState.available) ?? .unavailable
            }
            .onChange(of: maximumPixelDimension) { _, newValue in
                store.updatePreviewDimension(newValue)
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch previewState {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case let .available(image):
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .unavailable:
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Preview unavailable")
                    .font(.headline)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}
