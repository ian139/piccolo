import Foundation

protocol ReviewSessionPersisting: Sendable {
    func loadMostRecentSession() async throws -> ReviewSession?
    func loadSession(forSourceIdentity identity: String) async throws -> ReviewSession?
    func save(_ session: ReviewSession) async throws
    func sourceIdentity(for url: URL) async throws -> String
    func bookmarkData(for url: URL) async throws -> Data
    func resolve(_ session: ReviewSession) async -> ResolvedReviewSession
}

actor ReviewSessionPersistence: ReviewSessionPersisting {
    private struct Database: Codable {
        var sessions: [String: ReviewSession] = [:]
        var mostRecentSourceIdentity: String?
    }

    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(applicationSupportRoot: URL? = nil) {
        let root: URL
        if let applicationSupportRoot {
            root = applicationSupportRoot
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            root = applicationSupport.appendingPathComponent("Piccolo", isDirectory: true)
        }
        databaseURL = root.appendingPathComponent("ReviewSessions.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func loadMostRecentSession() throws -> ReviewSession? {
        let database = try loadDatabase()
        guard let identity = database.mostRecentSourceIdentity else { return nil }
        return database.sessions[identity]
    }

    func loadSession(forSourceIdentity identity: String) throws -> ReviewSession? {
        try loadDatabase().sessions[identity]
    }

    func save(_ session: ReviewSession) throws {
        var database = try loadDatabase()
        database.sessions[session.sourceFolderIdentity] = session
        database.mostRecentSourceIdentity = session.sourceFolderIdentity
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(database)
        try data.write(to: databaseURL, options: .atomic)
    }

    func sourceIdentity(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey])
        guard let fileIdentifier = values.fileResourceIdentifier else {
            throw PersistenceError.missingSourceIdentity
        }
        let volume = values.volumeIdentifier.map { String(describing: $0) } ?? "unknown-volume"
        return "\(volume):\(String(describing: fileIdentifier))"
    }

    func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey],
            relativeTo: nil
        )
    }

    func resolve(_ originalSession: ReviewSession) async -> ResolvedReviewSession {
        var session = originalSession
        var changed = false

        let sourceResolution = resolveBookmark(session.sourceBookmark)
        if let sourceResolution, sourceResolution.isStale,
           let refreshed = try? bookmarkData(for: sourceResolution.url) {
            session.sourceBookmark = refreshed
            changed = true
        }

        var keepURL: URL?
        if let bookmark = session.keepDestinationBookmark,
           let keepResolution = resolveBookmark(bookmark) {
            keepURL = keepResolution.url
            if keepResolution.isStale,
               let refreshed = try? bookmarkData(for: keepResolution.url) {
                session.keepDestinationBookmark = refreshed
                changed = true
            }
        }

        if changed {
            try? save(session)
        }

        return ResolvedReviewSession(
            session: session,
            sourceURL: sourceResolution?.url,
            keepDestinationURL: keepURL
        )
    }

    nonisolated static func reconcile(
        session originalSession: ReviewSession,
        availableItems: [PhotoItem]
    ) -> SessionReconciliation {
        let itemsByPath = Dictionary(uniqueKeysWithValues: availableItems.map { ($0.relativePath, $0) })
        let existingPassedPaths = originalSession.passedRelativePaths.filter { itemsByPath[$0] != nil }
        var session = originalSession
        session.passedRelativePaths = existingPassedPaths
        let passedSet = Set(existingPassedPaths)
        let initialItems = availableItems.filter { !passedSet.contains($0.relativePath) }
        let passedItems = existingPassedPaths.compactMap { itemsByPath[$0] }
        return SessionReconciliation(
            session: session,
            initialItems: initialItems,
            passedItems: passedItems
        )
    }

    private func loadDatabase() throws -> Database {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Database()
        }
        return try decoder.decode(Database.self, from: Data(contentsOf: databaseURL))
    }

    private func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }
}

enum PersistenceError: LocalizedError {
    case missingSourceIdentity

    var errorDescription: String? {
        switch self {
        case .missingSourceIdentity:
            "The selected photo folder could not be identified."
        }
    }
}
