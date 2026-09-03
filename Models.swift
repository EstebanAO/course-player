import Foundation

enum LibraryItemKind: String, Codable {
    case folder, video, audio, document, other
}

struct LibraryItem: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let relativePath: String
    let kind: LibraryItemKind
    var children: [LibraryItem]?

    var isPlayable: Bool { kind == .video || kind == .audio }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool { lhs.id == rhs.id }
}

struct ProgressRecord: Codable, Equatable {
    var position: Double = 0
    var duration: Double = 0
    var completed: Bool = false
    var lastOpened: Date = .now
}

struct ProgressFile: Codable {
    var version: Int = 1
    var records: [String: ProgressRecord] = [:]
}
