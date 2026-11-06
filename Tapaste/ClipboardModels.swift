import Foundation

nonisolated enum ClipKind: String, Codable, Equatable {
    case text
    case image
}

nonisolated struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ClipKind
    var text: String
    var imageFileName: String?
    var imageByteCount: Int
    var sourceApp: String
    var sourceBundleID: String?
    var lastCopiedAt: Date
    var note: String
    var groupID: UUID?
    var isLocked: Bool
}

nonisolated struct ClipGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
}
