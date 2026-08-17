import Foundation
import XCTest
@testable import Piccolo

@MainActor
final class ReviewSessionPersistenceTests: XCTestCase {

    func testSaveAndLoadRoundTripUsesSingleJSONDatabase() async throws {
        let root = try makeDirectory()
        let persistence = ReviewSessionPersistence(applicationSupportRoot: root)
        let session = makeSession(identity: "source-a", passed: ["a.png", "b.png"])

        try await persistence.save(session)
        let loaded = try await persistence.loadSession(forSourceIdentity: "source-a")
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(loaded, session)
        XCTAssertEqual(files.map(\.lastPathComponent), ["ReviewSessions.json"])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: files[0])))
    }

    func testPassedPathsAreDeduplicatedWhilePreservingOrder() {
        let session = makeSession(identity: "source-a", passed: ["b.png", "a.png", "b.png", "a.png"])

        XCTAssertEqual(session.passedRelativePaths, ["b.png", "a.png"])
    }

    func testReconciliationDropsMissingPassedFilesAndPlacesNewImagesInitially() {
        let source = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let a = PhotoItem(url: source.appendingPathComponent("a.png"), relativePath: "a.png")
        let b = PhotoItem(url: source.appendingPathComponent("b.png"), relativePath: "b.png")
        let new = PhotoItem(url: source.appendingPathComponent("new.png"), relativePath: "new.png")
        let session = makeSession(identity: "source-a", passed: ["a.png", "missing.png"])

        let result = ReviewSessionPersistence.reconcile(session: session, availableItems: [a, b, new])

        XCTAssertEqual(result.session.passedRelativePaths, ["a.png"])
        XCTAssertEqual(result.passedItems, [a])
        XCTAssertEqual(result.initialItems, [b, new])
    }

    func testSessionsRemainSeparatedBySourceIdentity() async throws {
        let persistence = ReviewSessionPersistence(applicationSupportRoot: try makeDirectory())
        let first = makeSession(identity: "source-a", passed: ["a.png"])
        let second = makeSession(identity: "source-b", passed: ["b.png"])

        try await persistence.save(first)
        try await persistence.save(second)

        let loadedFirst = try await persistence.loadSession(forSourceIdentity: "source-a")
        let loadedSecond = try await persistence.loadSession(forSourceIdentity: "source-b")
        let mostRecent = try await persistence.loadMostRecentSession()
        XCTAssertEqual(loadedFirst, first)
        XCTAssertEqual(loadedSecond, second)
        XCTAssertEqual(mostRecent, second)
    }

    private func makeSession(identity: String, passed: [String]) -> ReviewSession {
        ReviewSession(
            sourceBookmark: Data("source-\(identity)".utf8),
            keepDestinationBookmark: Data("keep-\(identity)".utf8),
            passedRelativePaths: passed,
            sourceFolderIdentity: identity
        )
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
}
