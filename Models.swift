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
    var completionSource: String?
}

struct ProgressFile: Codable {
    var version: Int = 1
    var records: [String: ProgressRecord] = [:]
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unstarted, inProgress, completed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Todos"
        case .unstarted: return "Pendientes"
        case .inProgress: return "En progreso"
        case .completed: return "Completados"
        }
    }
}

enum NoteSaveState: Equatable {
    case idle, saving, saved, failed

    var title: String {
        switch self {
        case .idle: return ""
        case .saving: return "Guardando…"
        case .saved: return "Guardado"
        case .failed: return "No se pudo guardar"
        }
    }
}

struct AppIssue: Identifiable, Equatable {
    enum Action: Equatable { case retryVideo, chooseFFmpeg, revealLibrary }
    let id = UUID()
    let title: String
    let message: String
    let action: Action?
}
