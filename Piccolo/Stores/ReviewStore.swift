import AppKit
import Combine
import CoreGraphics
import Foundation

struct ReviewErrorPresentation: Identifiable, Equatable {
    let id = UUID()
    let headline: String
    let details: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.headline == rhs.headline && lhs.details == rhs.details
    }
}

@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var keepDestinationURL: URL?
    @Published private(set) var initialQueue: [PhotoItem] = []
    @Published private(set) var passedQueue: [PhotoItem] = []
    @Published private(set) var currentItem: PhotoItem?
    @Published private(set) var phase: ReviewPhase = .initial
    @Published private(set) var isBusy = false
    @Published private(set) var reviewStarted = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var keptCount = 0
    @Published private(set) var trashedCount = 0
    @Published private(set) var passedCount = 0
    @Published var presentedError: ReviewErrorPresentation?

    private let fileSystem: any PhotoFileSystem
    private let persistence: any ReviewSessionPersisting
    private let previewLoader: PhotoPreviewLoader
    private var session: ReviewSession?
    private var passedRoundSeen = Set<PhotoItem.ID>()
    private var sourceSecurityScopeActive = false
    private var keepSecurityScopeActive = false
    private var hasLoadedPersistedSession = false

    init(
        fileSystem: any PhotoFileSystem = LocalPhotoFileSystem(),
        persistence: any ReviewSessionPersisting = ReviewSessionPersistence(),
        previewLoader: PhotoPreviewLoader = PhotoPreviewLoader()
    ) {
        self.fileSystem = fileSystem
        self.persistence = persistence
        self.previewLoader = previewLoader
    }

    var canStartReviewing: Bool {
        sourceURL != nil && keepDestinationURL != nil && !isBusy
    }

    var isActiveReviewVisible: Bool {
        reviewStarted && phase != .complete && currentItem != nil
    }

    var persistedPassedCount: Int {
        session?.passedRelativePaths.count ?? 0
    }

    var hasPassedPhotos: Bool {
        persistedPassedCount > 0
    }

    var nextItem: PhotoItem? {
        switch phase {
        case .initial:
            initialQueue.dropFirst().first
        case .passed:
            passedQueue.dropFirst().first
        case .complete:
            nil
        }
    }

    func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            if !hasLoadedPersistedSession {
                session = try await persistence.loadMostRecentSession()
                hasLoadedPersistedSession = true
            }
            guard let storedSession = session else {
                clearQueues()
                return
            }

            let resolved = await persistence.resolve(storedSession)
            session = resolved.session
            guard let resolvedSource = resolved.sourceURL else {
                replaceSourceURL(nil)
                replaceKeepURL(resolved.keepDestinationURL)
                clearQueues()
                return
            }
            replaceSourceURL(resolvedSource)
            replaceKeepURL(resolved.keepDestinationURL)
            if let keep = resolved.keepDestinationURL,
               Self.directoriesAreEqual(resolvedSource, keep) {
                replaceSourceURL(nil)
                replaceKeepURL(keep)
                showSameFolderError()
                clearQueues()
                return
            }

            let items = try await fileSystem.enumerateImages(in: resolvedSource)
            let reconciliation = ReviewSessionPersistence.reconcile(
                session: resolved.session,
                availableItems: items
            )
            if reconciliation.session != resolved.session {
                try await persistence.save(reconciliation.session)
            }
            session = reconciliation.session
            
            configureInitialRound(with: reconciliation.initialItems)
        } catch {
            showGenericError("Couldn’t load the selected photo folder.", error: error)
            clearQueues()
        }
    }

    func choosePhotoFolder() async {
        guard let selected = await chooseDirectory(title: "Choose Photo Folder") else { return }
        await adoptSourceFolder(selected)
    }

    func chooseKeepFolder() async {
        guard let selected = await chooseDirectory(title: "Choose Keep Folder") else { return }
        await adoptKeepFolder(selected)
    }

    func chooseAnotherFolder() async {
        await choosePhotoFolder()
    }

    func startReviewing() {
        guard canStartReviewing else { return }
        reviewStarted = true
        updateCurrentItem()
    }

    func perform(_ action: ReviewAction) async {
        guard !isBusy, isActiveReviewVisible, let item = currentItem else { return }
        isBusy = true
        defer { isBusy = false }

        switch action {
        case .keep:
            guard let destination = keepDestinationURL else { return }
            do {
                _ = try await fileSystem.moveItem(at: item.url, to: destination)
            } catch {
                presentedError = ReviewErrorPresentation(
                    headline: "Couldn’t move “\(item.url.lastPathComponent)” to the Keep folder.",
                    details: error.localizedDescription
                )
                return
            }
            keptCount += 1
            await completeFileDecision(for: item)

        case .trash:
            do {
                try await fileSystem.trashItem(at: item.url)
            } catch {
                presentedError = ReviewErrorPresentation(
                    headline: "Couldn’t move “\(item.url.lastPathComponent)” to Trash.",
                    details: error.localizedDescription
                )
                return
            }
            trashedCount += 1
            await completeFileDecision(for: item)

        case .pass:
            await pass(item)
        }
    }

    func startPassedReview() {
        guard !isBusy, phase == .complete, hasPassedPhotos, sourceURL != nil else { return }
        isBusy = true
        Task { [weak self] in
            await self?.loadPassedRound()
        }
    }

    func dismissError() {
        presentedError = nil
    }

    func preview(for item: PhotoItem, maximumPixelDimension: Int) async -> CGImage? {
        await previewLoader.image(
            for: item,
            nextItem: nextItem,
            maximumPixelDimension: maximumPixelDimension
        )
    }

    func updatePreviewDimension(_ maximumPixelDimension: Int) {
        let current = currentItem
        let next = nextItem
        Task {
            await previewLoader.prepare(
                current: current,
                next: next,
                maximumPixelDimension: maximumPixelDimension
            )
        }
    }

    private func adoptSourceFolder(_ selected: URL) async {
        guard !isBusy else { return }
        if let keepDestinationURL, Self.directoriesAreEqual(selected, keepDestinationURL) {
            showSameFolderError()
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let items = try await fileSystem.enumerateImages(in: selected)
            let identity = try await persistence.sourceIdentity(for: selected)
            let sourceBookmark = try await persistence.bookmarkData(for: selected)
            let stored = try await persistence.loadSession(forSourceIdentity: identity)

            var selectedSession: ReviewSession
            var resolvedKeep: URL?
            if let stored {
                let resolved = await persistence.resolve(stored)
                selectedSession = resolved.session
                resolvedKeep = resolved.keepDestinationURL
            } else {
                var keepBookmark: Data?
                if let currentKeep = keepDestinationURL,
                   !Self.directoriesAreEqual(selected, currentKeep) {
                    keepBookmark = try await persistence.bookmarkData(for: currentKeep)
                    resolvedKeep = currentKeep
                }
                selectedSession = ReviewSession(
                    sourceBookmark: sourceBookmark,
                    keepDestinationBookmark: keepBookmark,
                    passedRelativePaths: [],
                    sourceFolderIdentity: identity
                )
            }
            selectedSession.sourceBookmark = sourceBookmark

            if let resolvedKeep, Self.directoriesAreEqual(selected, resolvedKeep) {
                showSameFolderError()
                return
            }

            let reconciliation = ReviewSessionPersistence.reconcile(
                session: selectedSession,
                availableItems: items
            )
            try await persistence.save(reconciliation.session)

            session = reconciliation.session
            hasLoadedPersistedSession = true
            replaceSourceURL(selected)
            replaceKeepURL(resolvedKeep)
            reviewStarted = false
            resetLaunchCounts()
            configureInitialRound(with: reconciliation.initialItems)
        } catch {
            showGenericError("Couldn’t use the selected photo folder.", error: error)
        }
    }

    private func adoptKeepFolder(_ selected: URL) async {
        guard !isBusy else { return }
        if let sourceURL, Self.directoriesAreEqual(sourceURL, selected) {
            showSameFolderError()
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let bookmark = try await persistence.bookmarkData(for: selected)
            if var session {
                session.keepDestinationBookmark = bookmark
                try await persistence.save(session)
                self.session = session
            }
            replaceKeepURL(selected)
        } catch {
            showGenericError("Couldn’t use the selected Keep folder.", error: error)
        }
    }

    private func pass(_ item: PhotoItem) async {
        switch phase {
        case .initial:
            guard var updatedSession = session else { return }
            if !updatedSession.passedRelativePaths.contains(item.relativePath) {
                updatedSession.passedRelativePaths.append(item.relativePath)
            }
            do {
                try await persistence.save(updatedSession)
            } catch {
                showGenericError("Couldn’t save your review progress.", error: error)
                return
            }
            session = updatedSession
            passedCount += 1
            completedCount += 1
            removeFirstMatching(item, from: &initialQueue)
            if initialQueue.isEmpty {
                finishRound()
            } else {
                updateCurrentItem()
            }

        case .passed:
            removeFirstMatching(item, from: &passedQueue)
            passedQueue.append(item)
            passedRoundSeen.insert(item.id)
            passedCount += 1
            completedCount += 1
            if allRemainingPassedItemsWereSeen {
                finishRound()
            } else {
                updateCurrentItem()
            }

        case .complete:
            break
        }
    }

    private func completeFileDecision(for item: PhotoItem) async {
        completedCount += 1
        switch phase {
        case .initial:
            removeFirstMatching(item, from: &initialQueue)
            if initialQueue.isEmpty {
                finishRound()
            } else {
                updateCurrentItem()
            }

        case .passed:
            removeFirstMatching(item, from: &passedQueue)
            passedRoundSeen.remove(item.id)
            if var updatedSession = session {
                updatedSession.passedRelativePaths.removeAll { $0 == item.relativePath }
                do {
                    try await persistence.save(updatedSession)
                    session = updatedSession
                } catch {
                    session = updatedSession
                    showGenericError("Couldn’t save your review progress.", error: error)
                }
            }
            if passedQueue.isEmpty || allRemainingPassedItemsWereSeen {
                finishRound()
            } else {
                updateCurrentItem()
            }

        case .complete:
            break
        }
    }

    private var allRemainingPassedItemsWereSeen: Bool {
        !passedQueue.isEmpty && passedQueue.allSatisfy { passedRoundSeen.contains($0.id) }
    }

    private func loadPassedRound() async {
        defer { isBusy = false }
        guard let sourceURL, let currentSession = session else { return }
        do {
            let available = try await fileSystem.enumerateImages(in: sourceURL)
            let reconciliation = ReviewSessionPersistence.reconcile(
                session: currentSession,
                availableItems: available
            )
            if reconciliation.session != currentSession {
                try await persistence.save(reconciliation.session)
            }
            session = reconciliation.session
            passedQueue = reconciliation.passedItems
            passedRoundSeen.removeAll()
            phase = passedQueue.isEmpty ? .complete : .passed
            completedCount = 0
            totalCount = passedQueue.count
            reviewStarted = true
            updateCurrentItem()
        } catch {
            showGenericError("Couldn’t load the passed photos.", error: error)
            finishRound()
        }
    }

    private func configureInitialRound(with items: [PhotoItem]) {
        initialQueue = items
        passedQueue.removeAll()
        passedRoundSeen.removeAll()
        phase = items.isEmpty ? .complete : .initial
        completedCount = 0
        totalCount = items.count
        updateCurrentItem()
    }

    private func updateCurrentItem() {
        switch phase {
        case .initial:
            currentItem = initialQueue.first
        case .passed:
            currentItem = passedQueue.first
        case .complete:
            currentItem = nil
        }
        let current = currentItem
        let next = nextItem
        Task {
            await previewLoader.prepare(current: current, next: next)
        }
    }

    private func finishRound() {
        phase = .complete
        currentItem = nil
        passedQueue.removeAll()
        passedRoundSeen.removeAll()
        Task {
            await previewLoader.prepare(current: nil, next: nil)
        }
    }

    private func clearQueues() {
        initialQueue.removeAll()
        passedQueue.removeAll()
        passedRoundSeen.removeAll()
        currentItem = nil
        phase = .initial
        completedCount = 0
        totalCount = 0
        Task {
            await previewLoader.removeAll()
        }
    }

    private func resetLaunchCounts() {
        keptCount = 0
        trashedCount = 0
        passedCount = 0
    }

    private func replaceSourceURL(_ newURL: URL?) {
        if sourceSecurityScopeActive {
            sourceURL?.stopAccessingSecurityScopedResource()
        }
        sourceURL = newURL
        sourceSecurityScopeActive = newURL?.startAccessingSecurityScopedResource() ?? false
    }

    private func replaceKeepURL(_ newURL: URL?) {
        if keepSecurityScopeActive {
            keepDestinationURL?.stopAccessingSecurityScopedResource()
        }
        keepDestinationURL = newURL
        keepSecurityScopeActive = newURL?.startAccessingSecurityScopedResource() ?? false
    }

    private func showSameFolderError() {
        presentedError = ReviewErrorPresentation(
            headline: "Choose a different Keep folder; it cannot be the same as the photo folder.",
            details: "The Photo folder and Keep folder must be different locations."
        )
    }

    private func showGenericError(_ headline: String, error: Error) {
        presentedError = ReviewErrorPresentation(
            headline: headline,
            details: error.localizedDescription
        )
    }

    private func removeFirstMatching(_ item: PhotoItem, from queue: inout [PhotoItem]) {
        if queue.first?.id == item.id {
            queue.removeFirst()
        } else {
            queue.removeAll { $0.id == item.id }
        }
    }

    private func chooseDirectory(title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private static func directoriesAreEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath() ==
            rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
}
