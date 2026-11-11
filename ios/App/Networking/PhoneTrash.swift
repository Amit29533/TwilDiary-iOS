import Foundation
import Observation
import TwilDiaryCore

/// Trash with no TwilDiary server (Trakt-only, On this phone): the titles you moved to Trash,
/// kept on this iPhone so you can see and restore them. Moving one here also took its watches,
/// rating, Planned or dropped and favourite off the service (Trakt has no Trash of its own).
@MainActor @Observable final class PhoneTrash {
    static let shared = PhoneTrash()
    private(set) var titles: [MediaTitle] = PhoneTrash.load() {
        didSet { BackgroundFiles.save(titles, to: Self.file) }
    }
    nonisolated private static let file = URL.applicationSupportDirectory.appending(path: "Local/trash.json")
    nonisolated private static func load() -> [MediaTitle] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([MediaTitle].self, from: $0) } ?? []
    }
    func contains(_ id: String) -> Bool { titles.contains { $0.id == id } }
    func add(_ title: MediaTitle) {
        defer { PhoneExtras.shared.touch(.trash) }
        var kept = title
        kept.deletedAt = Date.now.formatted(.iso8601)
        titles.removeAll { $0.id == title.id }
        titles.insert(kept, at: 0)
    }
    func remove(_ ids: Set<String>) { titles.removeAll { ids.contains($0.id) }; PhoneExtras.shared.touch(.trash) }
    func removeAll() { titles = []; PhoneExtras.shared.touch(.trash) }
    func replace(_ restored: [MediaTitle]) { titles = restored }
}

extension DiaryStore {
    /// Move to Trash with no server: everything "Remove from watch history" does (every watch off
    /// the service), then the title leaves the library (rating, Planned or dropped, favourite off
    /// too) and waits in the phone's Trash. Undo puts it back as Planned, with its rating.
    func trashOnPhone(_ title: MediaTitle) async -> Bool {
        do {
            try await removeAllPlays(title)
            try await servicePatch(title, values: ["status": title.isSeries ? "watching" : "completed", "score": NSNull(), "favorite": false])
            PhoneTrash.shared.add(title)
            applyDiarySource()
            undoLabel = "Moved to Trash"
            setUndo([title.id]) { [weak self] in try await self?.restoreOnPhone(title) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    /// Back from the phone's Trash: Planned again (its watches stay removed), with its rating.
    func restoreOnPhone(_ title: MediaTitle) async throws {
        var values: [String: Any] = ["status": "planned"]
        if let score = title.score { values["score"] = score }
        try await servicePatch(title, values: values)
        PhoneTrash.shared.remove([title.id])
        applyDiarySource()
    }
}
