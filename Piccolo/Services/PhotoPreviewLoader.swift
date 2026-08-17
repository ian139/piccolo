import CoreGraphics
import Foundation
import ImageIO

actor PhotoPreviewLoader {
    private struct CachedPreview {
        let image: CGImage
        let maximumPixelDimension: Int
    }

    private struct PendingPreview {
        let id: UUID
        let maximumPixelDimension: Int
        let task: Task<CGImage?, Never>
    }

    private var cached: [URL: CachedPreview] = [:]
    private var pending: [URL: PendingPreview] = [:]
    private var retainedURLs = Set<URL>()
    private var lastMaximumPixelDimension = 2_048

    func image(
        for item: PhotoItem,
        nextItem: PhotoItem?,
        maximumPixelDimension: Int
    ) async -> CGImage? {
        prepare(
            current: item,
            next: nextItem,
            maximumPixelDimension: maximumPixelDimension
        )
        if let cached = cached[item.url],
           cached.maximumPixelDimension == lastMaximumPixelDimension {
            return cached.image
        }
        guard let pending = pending[item.url] else { return nil }
        let image = await pending.task.value
        finish(url: item.url, id: pending.id, image: image)
        return image
    }

    func prepare(
        current: PhotoItem?,
        next: PhotoItem?,
        maximumPixelDimension: Int? = nil
    ) {
        if let maximumPixelDimension {
            lastMaximumPixelDimension = max(1, maximumPixelDimension)
        }
        retainedURLs = Set([current?.url, next?.url].compactMap { $0 })

        let obsoleteURLs = pending.keys.filter { !retainedURLs.contains($0) }
        for url in obsoleteURLs {
            pending[url]?.task.cancel()
            pending[url] = nil
        }
        cached = cached.filter { retainedURLs.contains($0.key) }

        for item in [current, next].compactMap({ $0 }) {
            scheduleIfNeeded(item)
        }
    }

    func removeAll() {
        for work in pending.values {
            work.task.cancel()
        }
        pending.removeAll()
        cached.removeAll()
        retainedURLs.removeAll()
    }

    private func scheduleIfNeeded(_ item: PhotoItem) {
        if let preview = cached[item.url],
           preview.maximumPixelDimension == lastMaximumPixelDimension {
            return
        }
        if let work = pending[item.url] {
            if work.maximumPixelDimension == lastMaximumPixelDimension {
                return
            }
            work.task.cancel()
        }

        cached[item.url] = nil
        let id = UUID()
        let dimension = lastMaximumPixelDimension
        let url = item.url
        let task = Task.detached(priority: .userInitiated) {
            Self.downsample(url: url, maximumPixelDimension: dimension)
        }
        pending[url] = PendingPreview(
            id: id,
            maximumPixelDimension: dimension,
            task: task
        )

        Task {
            let image = await task.value
            finish(url: url, id: id, image: image)
        }
    }

    private func finish(url: URL, id: UUID, image: CGImage?) {
        guard let work = pending[url], work.id == id else { return }
        pending[url] = nil
        guard retainedURLs.contains(url), let image else { return }
        cached[url] = CachedPreview(
            image: image,
            maximumPixelDimension: work.maximumPixelDimension
        )
    }

    nonisolated private static func downsample(
        url: URL,
        maximumPixelDimension: Int
    ) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard !Task.isCancelled else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
