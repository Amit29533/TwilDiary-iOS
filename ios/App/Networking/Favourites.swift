import Foundation
import Observation

/// A hearted cast member (TMDB person) or anime character (AniList).
struct Favourite: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable { case cast, character }
    let kind: Kind
    let ref: Int
    let name: String
    let image: String?
    /// "Voice of Frieren", "Acting" and the like.
    let subtitle: String?
    let savedAt: Date
    var id: String { kind.rawValue + ":" + String(ref) }
}

/// Favourites live on the diary server (so they survive a reinstall or a new phone); this keeps a
/// copy for instant display. A heart changes the copy at once and saves in the background; a save
/// the server refuses is undone, with the reason shown like any other failed change.
@MainActor @Observable final class FavouritesStore {
    static let shared = FavouritesStore()
    static let storageKey = "favourites.v1", uploadedKey = "favourites.uploaded"
    /// Newest first.
    private(set) var items: [Favourite]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([Favourite].self, from: $0) } ?? []
    }
    func contains(_ kind: Favourite.Kind, _ ref: Int) -> Bool { items.contains { $0.kind == kind && $0.ref == ref } }
    func items(_ kind: Favourite.Kind) -> [Favourite] { items.filter { $0.kind == kind } }
    func toggle(_ kind: Favourite.Kind, ref: Int, name: String, image: String?, subtitle: String?, store: DiaryStore) {
        if let existing = items.first(where: { $0.kind == kind && $0.ref == ref }) {
            items.removeAll { $0.id == existing.id }; save()
            Task {
                guard await send(existing, removing: true, store: store) else { items.insert(existing, at: 0); items.sort { $0.savedAt > $1.savedAt }; save(); return }
            }
        } else {
            let added = Favourite(kind: kind, ref: ref, name: name, image: image, subtitle: subtitle, savedAt: .now)
            items.insert(added, at: 0); save()
            Task { guard await send(added, removing: false, store: store) else { items.removeAll { $0.id == added.id }; save(); return } }
        }
    }
    /// The server's list replaces the copy. The first time, hearts saved only on this phone (before
    /// favourites synced) are uploaded with their original dates, so nothing is lost.
    func sync(store: DiaryStore) async {
        #if DEBUG
        if store.isPreview { return }
        #endif
        struct Page: Decodable { let items: [Remote] }
        struct Remote: Decodable { let kind: String; let ref: Int; let name: String; let image: String?; let subtitle: String?; let savedAt: String }
        do {
            if !defaults.bool(forKey: Self.uploadedKey) {
                for item in items { guard await send(item, removing: false, store: store, quiet: true) else { return } }
                defaults.set(true, forKey: Self.uploadedKey)
            }
            let page: Page = try await store.read("/api/favourites")
            items = page.items.compactMap { remote in
                guard let kind = Favourite.Kind(rawValue: remote.kind) else { return nil }
                return Favourite(kind: kind, ref: remote.ref, name: remote.name, image: remote.image, subtitle: remote.subtitle,
                                 savedAt: DiaryDate.parse(remote.savedAt) ?? .distantPast)
            }
            save()
        } catch { /* Offline or an older server: the copy stands until the next sync. */ }
    }
    private func send(_ item: Favourite, removing: Bool, store: DiaryStore, quiet: Bool = false) async -> Bool {
        #if DEBUG
        if store.isPreview { return true }
        #endif
        struct Receipt: Decodable {}
        do {
            if removing { let _: Receipt = try await store.read("/api/favourites/" + item.id, method: "DELETE") }
            else {
                var body: [String: Any] = ["name": item.name, "savedAt": item.savedAt.formatted(.iso8601)]
                if let image = item.image { body["image"] = image }
                if let subtitle = item.subtitle { body["subtitle"] = subtitle }
                let _: Receipt = try await store.read("/api/favourites/" + item.id, method: "PUT", body: body)
            }
            return true
        } catch {
            if !quiet { store.error = "Your favourite wasn’t saved. " + error.localizedDescription }
            return false
        }
    }
    private func save() { defaults.set(try? JSONEncoder().encode(items), forKey: Self.storageKey) }
    /// UI tests start empty.
    func reset() { items = []; defaults.removeObject(forKey: Self.storageKey); defaults.removeObject(forKey: Self.uploadedKey) }
}
