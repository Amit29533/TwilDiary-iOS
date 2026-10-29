import Foundation
import Observation

/// A hearted cast member (TMDB person) or anime character (AniList). Kept on this iPhone for now;
/// the shape (kind, provider ID, name, image) can move to the diary server later unchanged.
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

@MainActor @Observable final class FavouritesStore {
    static let shared = FavouritesStore()
    static let storageKey = "favourites.v1"
    /// Newest first.
    private(set) var items: [Favourite]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([Favourite].self, from: $0) } ?? []
    }
    func contains(_ kind: Favourite.Kind, _ ref: Int) -> Bool { items.contains { $0.kind == kind && $0.ref == ref } }
    func items(_ kind: Favourite.Kind) -> [Favourite] { items.filter { $0.kind == kind } }
    func toggle(_ kind: Favourite.Kind, ref: Int, name: String, image: String?, subtitle: String?) {
        if contains(kind, ref) { items.removeAll { $0.kind == kind && $0.ref == ref } }
        else { items.insert(Favourite(kind: kind, ref: ref, name: name, image: image, subtitle: subtitle, savedAt: .now), at: 0) }
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.storageKey)
    }
    /// UI tests start empty.
    func reset() { items = []; defaults.removeObject(forKey: Self.storageKey) }
}
