import Foundation

enum ReviewAction: Sendable {
    case keep
    case trash
    case pass
}

enum ReviewPhase: String, Codable, Sendable {
    case initial
    case passed
    case complete
}

struct ReviewSession: Codable, Equatable, Sendable {
    var sourceBookmark: Data
    var keepDestinationBookmark: Data?
    var passedRelativePaths: [String]
    let sourceFolderIdentity: String

    init(
        sourceBookmark: Data,
        keepDestinationBookmark: Data?,
        passedRelativePaths: [String],
        sourceFolderIdentity: String
    ) {
        self.sourceBookmark = sourceBookmark
        self.keepDestinationBookmark = keepDestinationBookmark
        self.passedRelativePaths = Self.deduplicated(passedRelativePaths)
        self.sourceFolderIdentity = sourceFolderIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceBookmark = try container.decode(Data.self, forKey: .sourceBookmark)
        keepDestinationBookmark = try container.decodeIfPresent(Data.self, forKey: .keepDestinationBookmark)
        passedRelativePaths = Self.deduplicated(
            try container.decode([String].self, forKey: .passedRelativePaths)
        )
        sourceFolderIdentity = try container.decode(String.self, forKey: .sourceFolderIdentity)
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

struct ResolvedReviewSession: Sendable {
    let session: ReviewSession
    let sourceURL: URL?
    let keepDestinationURL: URL?
}

struct SessionReconciliation: Sendable {
    let session: ReviewSession
    let initialItems: [PhotoItem]
    let passedItems: [PhotoItem]
}
