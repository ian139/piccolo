import Foundation
import UniformTypeIdentifiers

protocol PhotoFileSystem: Sendable {
    func enumerateImages(in directory: URL) async throws -> [PhotoItem]
    func moveItem(at sourceURL: URL, to destinationDirectory: URL) async throws -> URL
    func trashItem(at sourceURL: URL) async throws
}

struct LocalPhotoFileSystem: PhotoFileSystem {
    func enumerateImages(in directory: URL) async throws -> [PhotoItem] {
        try await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.contentTypeKey, .isHiddenKey, .isRegularFileKey, .nameKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            return try urls.compactMap { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true,
                      values.isHidden != true,
                      values.contentType?.conforms(to: .image) == true else {
                    return nil
                }
                return PhotoItem(url: url, relativePath: url.lastPathComponent)
            }
            .sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    func moveItem(at sourceURL: URL, to destinationDirectory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let destination = Self.availableDestination(
                for: sourceURL.lastPathComponent,
                in: destinationDirectory,
                fileManager: manager
            )
            try manager.moveItem(at: sourceURL, to: destination)
            return destination
        }.value
    }

    func trashItem(at sourceURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
        }.value
    }

    private static func availableDestination(
        for filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let original = directory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let filenameURL = URL(fileURLWithPath: filename)
        let fileExtension = filenameURL.pathExtension
        let stem = filenameURL.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(stem)-\(suffix)"
            } else {
                candidateName = "\(stem)-\(suffix).\(fileExtension)"
            }
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
