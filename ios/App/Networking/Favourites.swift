import Foundation
import Observation
import TwilDiaryCore

/// A hearted cast member (TMDB person), anime character or voice actor (AniList).
struct Favourite: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case cast, character, voice
        var label: String { switch self { case .cast: "Cast"; case .character: "Characters"; case .voice: "Voice actors" } }
        var singular: String { switch self { case .cast: "Cast"; case .character: "Character"; case .voice: "Voice actor" } }
    }
    let kind: Kind
    let ref: Int
    let name: String
    let image: String?
    /// "Voice of Frieren", "Acting" and the like.
    let subtitle: String?
    let savedAt: Date
    var id: String { kind.rawValue + ":" + String(ref) }
}

/// Favourite people live on this phone, in its Drive and Files backups, and (with Google Drive or
/// your server's extras switched on) in the extras copy that another iPhone reads.
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
    #if DEBUG
    /// Design screenshots only: three hearted characters, as in the Home design.
    func seedForDesign() {
        let names = ["Kurumi Tokisaki", "Mai Sakurajima", "Sakuta Azusagawa"]
        items = names.enumerated().map { index, name in
            Favourite(kind: .character, ref: 800_001 + index, name: name, image: nil, subtitle: nil, savedAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(index)))
        }
    }
    #endif
    func contains(_ kind: Favourite.Kind, _ ref: Int) -> Bool { items.contains { $0.kind == kind && $0.ref == ref } }
    func items(_ kind: Favourite.Kind) -> [Favourite] { items.filter { $0.kind == kind } }
    func replace(_ restored: [Favourite]) { items = restored; save() }
    func toggle(_ kind: Favourite.Kind, ref: Int, name: String, image: String?, subtitle: String?, store: DiaryStore) {
        if let existing = items.first(where: { $0.kind == kind && $0.ref == ref }) {
            items.removeAll { $0.id == existing.id }
        } else {
            items.insert(Favourite(kind: kind, ref: ref, name: name, image: image, subtitle: subtitle, savedAt: .now), at: 0)
        }
        save()
        if store.phoneOnly { PhoneExtras.shared.touch(.favourites) }
    }
    private func save() { defaults.set(try? JSONEncoder().encode(items), forKey: Self.storageKey) }
    #if DEBUG
    /// Fixture-only gallery coverage; no server writes or persistent favourites.
    func seedGallery() {
        let now = Date()
        items = [
            Favourite(kind: .cast, ref: 525, name: "Kim Yeong-ok", image: nil, subtitle: "Kim Gam-ri", savedAt: now),
            Favourite(kind: .cast, ref: 77, name: "Jeon Bae-soo", image: nil, subtitle: "Woo Gwang-woo", savedAt: now),
            Favourite(kind: .character, ref: 1, name: "Frieren", image: nil, subtitle: "Frieren", savedAt: now),
            Favourite(kind: .character, ref: 2, name: "Fern", image: nil, subtitle: "Frieren", savedAt: now),
            Favourite(kind: .voice, ref: 11, name: "Atsumi Tanezaki", image: nil, subtitle: "Voice of Frieren", savedAt: now),
            Favourite(kind: .voice, ref: 12, name: "Kana Ichinose", image: nil, subtitle: "Voice of Fern", savedAt: now)
        ]
    }
    #endif
    /// UI tests start empty.
    func reset() { items = []; defaults.removeObject(forKey: Self.storageKey) }
}
