import Foundation
import XCTest
@testable import Piccolo

@MainActor
final class PhotoFileSystemTests: XCTestCase {

    func testEnumerationFiltersSortsAndDoesNotRecurse() async throws {
        let source = try makeDirectory()
        try tinyPNG.write(to: source.appendingPathComponent("photo10.png"))
        try tinyPNG.write(to: source.appendingPathComponent("photo2.png"))
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try tinyPNG.write(to: source.appendingPathComponent(".hidden.png"))
        let nested = source.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try tinyPNG.write(to: nested.appendingPathComponent("photo1.png"))

        let items = try await LocalPhotoFileSystem().enumerateImages(in: source)

        XCTAssertEqual(items.map(\.relativePath), ["photo2.png", "photo10.png"])
    }

    func testMoveRemovesSourceAndPreservesBytes() async throws {
        let source = try makeDirectory()
        let destination = try makeDirectory()
        let bytes = Data([0, 1, 2, 3, 4])
        let original = source.appendingPathComponent("photo.jpg")
        try bytes.write(to: original)

        let moved = try await LocalPhotoFileSystem().moveItem(at: original, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(moved.lastPathComponent, "photo.jpg")
        XCTAssertEqual(try Data(contentsOf: moved), bytes)
    }

    func testMoveUsesIncrementingCollisionNamesWithoutOverwriting() async throws {
        let source = try makeDirectory()
        let destination = try makeDirectory()
        let existing = Data("existing".utf8)
        let second = Data("second".utf8)
        let incoming = Data("incoming".utf8)
        try existing.write(to: destination.appendingPathComponent("photo.jpg"))
        try second.write(to: destination.appendingPathComponent("photo-2.jpg"))
        let original = source.appendingPathComponent("photo.jpg")
        try incoming.write(to: original)

        let moved = try await LocalPhotoFileSystem().moveItem(at: original, to: destination)

        XCTAssertEqual(moved.lastPathComponent, "photo-3.jpg")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photo.jpg")), existing)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photo-2.jpg")), second)
        XCTAssertEqual(try Data(contentsOf: moved), incoming)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private var tinyPNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
