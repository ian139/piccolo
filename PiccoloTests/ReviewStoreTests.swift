import Foundation
import XCTest
@testable import Piccolo

@MainActor
final class ReviewStoreTests: XCTestCase {
    func testInitialPassAdvancesWithoutFilesystemMutation() async throws {
        let fixture = makeFixture(names: ["a.png", "b.png"])
        let store = try await fixture.loadedStore()

        await store.perform(.pass)

        XCTAssertEqual(store.currentItem?.relativePath, "b.png")
        XCTAssertEqual(store.completedCount, 1)
        XCTAssertEqual(store.passedCount, 1)
        let mutations = await fixture.fileSystem.mutationCount
        XCTAssertEqual(mutations, 0)
        let saved = await fixture.persistence.storedSession
        XCTAssertEqual(saved?.passedRelativePaths, ["a.png"])
    }

    func testPassedItemsStayOutOfInitialQueueAfterReloadAndCanBeStartedLater() async throws {
        let fixture = makeFixture(names: ["a.png", "b.png"])
        let firstStore = try await fixture.loadedStore()
        await firstStore.perform(.pass)

        let reloadedStore = try await fixture.loadedStore()

        XCTAssertEqual(reloadedStore.initialQueue.map(\.relativePath), ["b.png"])
        XCTAssertEqual(reloadedStore.persistedPassedCount, 1)
        await reloadedStore.perform(.keep)
        XCTAssertEqual(reloadedStore.phase, .complete)

        reloadedStore.startPassedReview()
        try await waitUntil { reloadedStore.phase == .passed && !reloadedStore.isBusy }

        XCTAssertEqual(reloadedStore.currentItem?.relativePath, "a.png")
        XCTAssertEqual(reloadedStore.passedQueue.map(\.relativePath), ["a.png"])
    }

    func testPassingEveryItemInPassedRoundStopsAtSummary() async throws {
        let fixture = makeFixture(names: ["a.png", "b.png"])
        let store = try await fixture.loadedStore()
        await store.perform(.pass)
        await store.perform(.pass)
        XCTAssertEqual(store.phase, .complete)

        store.startPassedReview()
        try await waitUntil { store.phase == .passed && !store.isBusy }
        await store.perform(.pass)
        XCTAssertEqual(store.phase, .passed)
        await store.perform(.pass)

        XCTAssertEqual(store.phase, .complete)
        XCTAssertNil(store.currentItem)
        XCTAssertEqual(store.persistedPassedCount, 2)
    }

    func testFailedKeepAndTrashRetainCurrentSelection() async throws {
        for action in [ReviewAction.keep, .trash] {
            let fixture = makeFixture(names: ["a.png", "b.png"])
            await fixture.fileSystem.setFailure(action: action)
            let store = try await fixture.loadedStore()
            let originalID = store.currentItem?.id

            await store.perform(action)

            XCTAssertEqual(store.currentItem?.id, originalID)
            XCTAssertEqual(store.initialQueue.map(\.relativePath), ["a.png", "b.png"])
            XCTAssertEqual(store.completedCount, 0)
            switch action {
            case .keep:
                XCTAssertEqual(store.presentedError?.headline, "Couldn’t move “a.png” to the Keep folder.")
            case .trash:
                XCTAssertEqual(store.presentedError?.headline, "Couldn’t move “a.png” to Trash.")
            case .pass:
                XCTFail("Unexpected action")
            }
        }
    }

    func testBusyStatePreventsDuplicateCommands() async throws {
        let fixture = makeFixture(names: ["a.png", "b.png"])
        await fixture.fileSystem.setMoveSuspended(true)
        let store = try await fixture.loadedStore()

        let first = Task { await store.perform(.keep) }
        try await waitUntil { await fixture.fileSystem.moveHasStarted }
        XCTAssertTrue(store.isBusy)

        await store.perform(.keep)
        let callsWhileBusy = await fixture.fileSystem.moveCallCount
        XCTAssertEqual(callsWhileBusy, 1)

        await fixture.fileSystem.releaseMove()
        await first.value
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.currentItem?.relativePath, "b.png")
    }

    func testSameSourceAndKeepFolderIsRejectedWithoutChangingQueue() async throws {
        let fixture = makeFixture(names: ["a.png"], sameFolders: true)
        let store = ReviewStore(
            fileSystem: fixture.fileSystem,
            persistence: fixture.persistence,
            previewLoader: PhotoPreviewLoader()
        )

        await store.reload()

        XCTAssertNil(store.sourceURL)
        XCTAssertEqual(
            store.presentedError?.headline,
            "Choose a different Keep folder; it cannot be the same as the photo folder."
        )
        XCTAssertTrue(store.initialQueue.isEmpty)
    }

    private func makeFixture(names: [String], sameFolders: Bool = false) -> StoreFixture {
        let source = URL(fileURLWithPath: "/source", isDirectory: true)
        let keep = sameFolders ? source : URL(fileURLWithPath: "/keep", isDirectory: true)
        let items = names.map {
            PhotoItem(url: source.appendingPathComponent($0), relativePath: $0)
        }
        let session = ReviewSession(
            sourceBookmark: Data("source".utf8),
            keepDestinationBookmark: Data("keep".utf8),
            passedRelativePaths: [],
            sourceFolderIdentity: "source-id"
        )
        return StoreFixture(
            fileSystem: FakePhotoFileSystem(items: items),
            persistence: FakeReviewSessionPersistence(session: session, sourceURL: source, keepURL: keep)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                throw TestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct StoreFixture {
    let fileSystem: FakePhotoFileSystem
    let persistence: FakeReviewSessionPersistence

    @MainActor
    func loadedStore() async throws -> ReviewStore {
        let store = ReviewStore(
            fileSystem: fileSystem,
            persistence: persistence,
            previewLoader: PhotoPreviewLoader()
        )
        await store.reload()
        store.startReviewing()
        return store
    }
}

private actor FakePhotoFileSystem: PhotoFileSystem {
    private let items: [PhotoItem]
    private var failingAction: ReviewAction?
    private var suspendMove = false
    private var moveContinuation: CheckedContinuation<Void, Never>?
    private(set) var moveCallCount = 0
    private(set) var trashCallCount = 0
    private(set) var moveHasStarted = false

    init(items: [PhotoItem]) {
        self.items = items
    }

    var mutationCount: Int { moveCallCount + trashCallCount }

    func setFailure(action: ReviewAction) {
        failingAction = action
    }

    func setMoveSuspended(_ suspended: Bool) {
        suspendMove = suspended
    }

    func releaseMove() {
        moveContinuation?.resume()
        moveContinuation = nil
        suspendMove = false
    }

    func enumerateImages(in directory: URL) async throws -> [PhotoItem] {
        items
    }

    func moveItem(at sourceURL: URL, to destinationDirectory: URL) async throws -> URL {
        moveCallCount += 1
        moveHasStarted = true
        if suspendMove {
            await withCheckedContinuation { continuation in
                moveContinuation = continuation
            }
        }
        if failingAction == .keep {
            throw TestError.operationFailed
        }
        return destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
    }

    func trashItem(at sourceURL: URL) async throws {
        trashCallCount += 1
        if failingAction == .trash {
            throw TestError.operationFailed
        }
    }
}

private actor FakeReviewSessionPersistence: ReviewSessionPersisting {
    private(set) var storedSession: ReviewSession?
    private let sourceURL: URL
    private let keepURL: URL

    init(session: ReviewSession, sourceURL: URL, keepURL: URL) {
        storedSession = session
        self.sourceURL = sourceURL
        self.keepURL = keepURL
    }

    func loadMostRecentSession() async throws -> ReviewSession? {
        storedSession
    }

    func loadSession(forSourceIdentity identity: String) async throws -> ReviewSession? {
        storedSession?.sourceFolderIdentity == identity ? storedSession : nil
    }

    func save(_ session: ReviewSession) async throws {
        storedSession = session
    }

    func sourceIdentity(for url: URL) async throws -> String {
        "source-id"
    }

    func bookmarkData(for url: URL) async throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ session: ReviewSession) async -> ResolvedReviewSession {
        ResolvedReviewSession(session: session, sourceURL: sourceURL, keepDestinationURL: keepURL)
    }
}

private enum TestError: Error {
    case operationFailed
    case timedOut
}
