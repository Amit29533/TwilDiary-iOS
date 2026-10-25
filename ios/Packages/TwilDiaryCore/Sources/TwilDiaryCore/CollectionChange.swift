import Foundation

public enum CollectionChange: Equatable, Sendable {
    case trash, restore, purge, status(String), queue(Bool), favorite(Bool)
    public var action: String { switch self { case .trash: "trash"; case .restore: "restore"; case .purge: "purge"; case .status: "status"; case .queue: "queue"; case .favorite: "favorite" } }
    public var archived: Bool { self == .restore || self == .purge }
    public var destructive: Bool { self == .trash || self == .purge }
    public var heading: String {
        switch self {
        case .trash: "Move to Trash?"
        case .restore: "Restore titles?"
        case .purge: "Delete permanently?"
        case .status(let value): "Mark as \(value)?"
        case .queue(let value): value ? "Add to Queue?" : "Remove from Queue?"
        case .favorite(let value): value ? "Add to favorites?" : "Remove from favorites?"
        }
    }
    public var explanation: String {
        switch self {
        case .trash: "Your notes, episode history, and file mappings stay safe in Trash. Restore them anytime."
        case .restore: "Your titles return with their notes, progress, and file mappings."
        case .purge: "This removes the selected titles, notes, episode history, and file mappings from this diary. It cannot be undone. Files on your disks stay untouched."
        case .status("planned"): "Progress resets to zero, including rewatches. Undo restores the previous history and dates."
        case .status("completed"): "Unwatched movies and regular episodes are marked watched. Existing watch dates are kept. Unreleased episodes cannot be completed. Undo restores the previous progress."
        case .status: "Partial progress and recorded viewings stay as they are."
        case .queue: "Only your download reminder changes. Watch status and episode history stay as they are."
        case .favorite: "Your selection’s favorite setting will be updated."
        }
    }
}

public struct CollectionRequest: Encodable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable { public let id: String, expectedVersion: Int }
    public static let limit = 60
    public let change: CollectionChange, items: [Item]
    public enum ValidationError: LocalizedError {
        case selection, state, version, status
        public var errorDescription: String? {
            switch self {
            case .selection: "Select between 1 and 60 different titles."
            case .state: "Your selection changed. Refresh it before trying again."
            case .version: "Refresh your selection before changing it."
            case .status: "Choose a valid watch status."
            }
        }
    }
    public init(titles: [MediaTitle], change: CollectionChange) throws {
        guard !titles.isEmpty, titles.count <= Self.limit, Set(titles.map(\.id)).count == titles.count else { throw ValidationError.selection }
        guard titles.allSatisfy({ ($0.deletedAt != nil) == change.archived }) else { throw ValidationError.state }
        if case .status(let value) = change, !["planned", "watching", "completed", "dropped"].contains(value) { throw ValidationError.status }
        self.items = try titles.map { title in guard let version = title.version, version > 0 else { throw ValidationError.version }; return Item(id: title.id, expectedVersion: version) }
        self.change = change
    }
    private enum CodingKeys: String, CodingKey { case action, items, status, queued, favorite, confirmation }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(change.action, forKey: .action); try container.encode(items, forKey: .items)
        switch change {
        case .status(let value): try container.encode(value, forKey: .status)
        case .queue(let value): try container.encode(value, forKey: .queued)
        case .favorite(let value): try container.encode(value, forKey: .favorite)
        case .purge: try container.encode("DELETE", forKey: .confirmation)
        default: break
        }
    }
}
