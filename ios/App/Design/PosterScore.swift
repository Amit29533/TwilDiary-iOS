import SwiftUI
import TwilDiaryCore

/// TMDB's score for posters whose row didn't bring one (CineMind's picks, Recommended for you,
/// More like this), read once per title in the background and kept on this iPhone. One request
/// at a time, so a flaky connection isn't flooded; a failed title is asked again after an hour.
@MainActor @Observable final class PosterScores {
    static let shared = PosterScores()
    private static let storageKey = "posterScores.v1"
    private(set) var values: [String: Double]
    @ObservationIgnored private var wanted: [String] = []
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private var running = false

    init() {
        values = (UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Double]) ?? [:]
    }

    func score(_ key: String) -> Double? { values[key] }

    /// Asks for a title's score ("tv:1399") when it isn't known yet.
    func want(_ key: String, store: DiaryStore) {
        guard values[key] == nil, !wanted.contains(key), !store.isPreview,
              failed[key].map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true else { return }
        let parts = key.split(separator: ":")
        guard parts.count == 2, parts[0] == "movie" || parts[0] == "tv", Int(parts[1]) != nil else { return }
        wanted.append(key)
        guard !running else { return }
        Task { await drain(store: store) }
    }

    private func drain(store: DiaryStore) async {
        guard let token = TMDBDirect.token(store) else { wanted = []; return }
        running = true
        defer { running = false }
        var read = 0
        while let key = wanted.first {
            wanted.removeFirst()
            let parts = key.split(separator: ":")
            guard parts.count == 2 else { continue }
            let reply = try? await TMDBDirect.object("\(parts[0])/\(parts[1])", query: ["language": "en-US"], token: token)
            let value = reply?["vote_average"] as? Double, votes = reply?["vote_count"] as? Int ?? 0
            if let value, value > 0, votes > 0 { values[key] = (value * 10).rounded() / 10 } else { failed[key] = .now }
            read += 1
            // Kept every few, so leaving the app mid-way loses little.
            if read % 6 == 0 { save() }
        }
        save()
    }
    private func save() { UserDefaults.standard.set(values, forKey: Self.storageKey) }

    /// A poster's score: the row's own, else your library's, else the one kept here.
    static func score(for item: CatalogItem, store: DiaryStore) -> Double? {
        if let rating = item.rating, rating > 0 { return rating }
        if let library = store.libraryIdentity(item).flatMap({ store.title($0)?.communityScore }), library > 0 { return library }
        return shared.score(item.key)
    }
}

/// The star and score on a poster's corner, as every poster row shows it.
struct PosterScoreBadge: View {
    let score: Double
    private var showsRating: Bool { TilePrefs.shared.posterRatings }
    var body: some View {
        if showsRating { badge }
    }
    private var badge: some View {
        HStack(spacing: 5) { Image(systemName: "star.fill").font(.app(size: 13)); Text(String(format: "%.1f", score)).frame(height: 18) }
            .font(.app(size: 12)).foregroundStyle(Color(themed: "#e7ca90"))
            .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6)).padding(6)
            .accessibilityElement(children: .combine).accessibilityLabel("Rated " + String(format: "%.1f", score))
    }
}

extension View {
    /// Asks for the poster's score when its row didn't bring one.
    func wantsPosterScore(_ item: CatalogItem, known: Double?, store: DiaryStore) -> some View {
        task(id: item.key) { if known == nil { PosterScores.shared.want(item.key, store: store) } }
    }
}
