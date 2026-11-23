import SwiftUI
import TwilDiaryCore

/// The settings every poster and card reads (the theme, names under posters, the score badge and its
/// source, and JellySpace's counts, ticks and names), kept once for all of them. As @AppStorage on each cell they
/// were settings observers made and dropped with every poster as rows scrolled in: the stutter at the
/// start of a fast scroll. Read from here, a cell's setting is a plain property and it still redraws
/// when the setting changes.
@MainActor @Observable final class TilePrefs {
    static let shared = TilePrefs()
    private(set) var theme = DiaryTheme.twilight
    private(set) var posterCaptions = true
    private(set) var posterRatings = true
    private(set) var jellyCounts = true
    private(set) var jellyTicks = true
    private(set) var jellyCaptions = true
    private(set) var ratingSource = PublicRatingSource.tmdb
    @ObservationIgnored private var watcher: (any NSObjectProtocol)?

    private init() {
        refresh()
        watcher = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TilePrefs.shared.refresh() }
        }
    }

    /// Only what changed is set, so a write to any other setting redraws nothing.
    private func refresh() {
        let defaults = UserDefaults.standard
        func read(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        let theme = DiaryTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .twilight
        if self.theme != theme { self.theme = theme }
        let captions = read(PosterSize.captionKey), ratings = read(PosterSize.ratingKey)
        if posterCaptions != captions { posterCaptions = captions }
        if posterRatings != ratings { posterRatings = ratings }
        let counts = read(JellyPrefs.countsKey), ticks = read(JellyPrefs.ticksKey), names = read(JellyPrefs.captionsKey)
        if jellyCounts != counts { jellyCounts = counts }
        if jellyTicks != ticks { jellyTicks = ticks }
        if jellyCaptions != names { jellyCaptions = names }
        let source = PublicRatingSource(rawValue: defaults.string(forKey: "publicRatingSource") ?? "") ?? .tmdb
        if ratingSource != source { ratingSource = source }
    }
}
