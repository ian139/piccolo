import Foundation

struct PhotoItem: Identifiable, Hashable, Codable, Sendable {
    var id: String { relativePath }

    let url: URL
    let relativePath: String

    init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
}
