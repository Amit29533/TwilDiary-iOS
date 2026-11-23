import Foundation
import Observation
import TwilDiaryCore

/// Trash with no TwilDiary server (Trakt-only, On this phone): the titles you moved to Trash,
/// kept on this iPhone so you can see and restore them. Moving one here also took its watches,
/// rating, Planned or dropped and favourite off the service (Trakt has no Trash of its own).
@MainActor @Observable final class PhoneTrash {
    static let shared = PhoneTrash()
    private var archived: [MediaTitle] = PhoneTrash.load() {
        didSet { BackgroundFiles.save(archived, to: Self.file) }
    }
    var titles: [MediaTitle] { archived.filter { !PhoneExtras.shared.isPurged($0) } }
    nonisolated private static let file = URL.applicationSupportDirectory.appending(path: "Local/trash.json")
    nonisolated private static func load() -> [MediaTitle] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([MediaTitle].self, from: $0) } ?? []
    }
    func contains(_ id: String) -> Bool { titles.contains { $0.id == id } }
    func add(_ title: MediaTitle) {
        defer { PhoneExtras.shared.touch(.trash) }
        var kept = title
        kept.deletedAt = Date.now.formatted(.iso8601)
        archived.removeAll { PhoneExtras.key($0) == PhoneExtras.key(title) }
        archived.insert(kept, at: 0)
    }
    func remove(_ title: MediaTitle) throws {
        let key = PhoneExtras.key(title)
        let kept = archived.filter { PhoneExtras.key($0) != key }
        guard kept.count != archived.count else { return }
        try BackgroundFiles.saveImmediately(kept, to: Self.file)
        archived = kept
        PhoneExtras.shared.touch(.trash)
    }
    func purge(_ ids: Set<String>) throws {
        let selected = titles.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        try PhoneExtras.shared.recordPurge(selected)
        archived.removeAll { ids.contains($0.id) }
    }
    func replace(_ restored: [MediaTitle]) { archived = restored.filter { !PhoneExtras.shared.isPurged($0) } }
}

extension DiaryStore {
    /// Move to Trash with no server: everything "Remove from watch history" does (every watch off
    /// the service), then the title leaves the library (rating, Planned or dropped, favourite off
    /// too) and waits in the phone's Trash. Restore puts it back as Planned, with its rating.
    func trashOnPhone(_ title: MediaTitle) async -> Bool {
        do {
            try await removeAllPlays(title)
            // The status only takes it off the watchlist; a service that keeps that status as a list
            // of its own (Simkl's Completed and Watching) takes the title off instead (`trashing`).
            trashing.insert(title.id)
            defer { trashing.remove(title.id) }
            try await servicePatch(title, values: ["status": title.isSeries ? "watching" : "completed", "score": NSNull(), "favorite": false])
            try serviceClearLists(title)
            PhoneTrash.shared.add(title)
            Haptics.play(.warning)
            applyDiarySource()
            if SimklAccount.shared.canSend { TrackerPreviewStore.shared.refreshSoon(.simkl, store: self, after: 60) }
            // Said, with no Undo: the title comes back from Trash itself.
            dismissUndo()
            undoLabel = "Moved to Trash"
            return true
        } catch {
            self.error = FriendlyError.message(error)
            return false
        }
    }
    /// Back from the phone's Trash: Planned again (its watches stay removed), with its rating.
    func restoreOnPhone(_ title: MediaTitle) async throws {
        var values: [String: Any] = ["status": "planned"]
        if let score = title.score { values["score"] = score }
        try await servicePatch(title, values: values)
        try PhoneTrash.shared.remove(title)
        Haptics.play(.success)
        applyDiarySource()
    }
}
