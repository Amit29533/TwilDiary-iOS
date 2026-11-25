import SwiftUI

// Settings → Customise (owner's request, 2026-11-19): Home's sections and Explore's rows in your
// order (any can be hidden but the Explore / Canvas shortcuts, the only way into them), the tab
// bar's order (Glance can be hidden), and how big posters are and what shows on them.

/// An order and a hidden set, kept as "a,b,c|x,y" (order|hidden). New sections an update adds
/// join at the end, shown; ones that no longer exist are dropped.
struct SectionOrder: Equatable {
    var order: [String]
    var hidden: Set<String>

    init(_ text: String, all: [String]) {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let saved = (parts.first ?? "").split(separator: ",").map(String.init).filter(all.contains)
        var seen = Set<String>(), order: [String] = []
        for id in saved where seen.insert(id).inserted { order.append(id) }
        order += all.filter { !seen.contains($0) }
        self.order = order
        hidden = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").map(String.init)).intersection(all)
    }
    var text: String { order.joined(separator: ",") + "|" + hidden.sorted().joined(separator: ",") }
    var visible: [String] { order.filter { !hidden.contains($0) } }
}

/// Home's sections, top to bottom by default.
enum HomeSection: String, CaseIterable, Identifiable {
    case shortcuts, week, upNext, saved, recommended, favourites, newEpisodes, recent
    var id: String { rawValue }
    static let key = "customise.home"
    static let continueKey = "customise.home.continue"
    var title: String {
        switch self {
        case .shortcuts: "Explore & Canvas"
        case .week: "This week"
        case .upNext: "Up next"
        case .saved: "Saved filters"
        case .recommended: "Recommended"
        case .favourites: "Favourites"
        case .newEpisodes: "New episodes"
        case .recent: "Recently watched"
        }
    }
    var symbol: String {
        switch self {
        case .shortcuts: "safari"
        case .week: "calendar"
        case .upNext: "bookmark"
        case .saved: "line.3.horizontal.decrease.circle"
        case .recommended: "sparkles"
        case .favourites: "heart"
        case .newEpisodes: "tv"
        case .recent: "clock.arrow.circlepath"
        }
    }
    /// The shortcuts are the only way into Explore and Canvas: they can move, not go.
    var hideable: Bool { self != .shortcuts }
    static func layout(_ text: String) -> SectionOrder {
        var layout = SectionOrder(text, all: allCases.map(\.rawValue))
        layout.hidden.remove(HomeSection.shortcuts.rawValue)
        return layout
    }
}

/// Explore's rows, top to bottom by default.
enum ExploreRow: String, CaseIterable, Identifiable {
    // Ask CineMind first: right under the cover, above Popular movies (owner).
    case askCineMind, popularMovies, popularShows, cineMovies, cineShows, recommended, loved, trending, seasonal, coming, ratedShows, ratedMovies
    var id: String { rawValue }
    static let key = "customise.explore"
    var title: String {
        switch self {
        case .popularMovies: "Popular movies"
        case .popularShows: "Popular shows"
        case .askCineMind: "Ask CineMind"
        case .cineMovies: "Movies by CineMind"
        case .cineShows: "Shows by CineMind"
        case .recommended: "Recommended for you"
        case .loved: "Because you loved"
        case .trending: "Trending from your Planned"
        case .seasonal: "This season's anime"
        case .coming: "Coming soon"
        case .ratedShows: "Highest rated shows"
        case .ratedMovies: "Highest rated movies"
        }
    }
    var symbol: String {
        switch self {
        case .popularMovies, .popularShows: "flame"
        case .askCineMind, .cineMovies, .cineShows: "sparkles"
        case .recommended, .loved: "hand.thumbsup"
        case .trending: "chart.line.uptrend.xyaxis"
        case .seasonal: "sparkles.tv"
        case .coming: "calendar.badge.clock"
        case .ratedShows, .ratedMovies: "star"
        }
    }
    static func layout(_ text: String) -> SectionOrder { SectionOrder(text, all: allCases.map(\.rawValue)) }
}

/// The tab bar: your order; Glance is the one that can be hidden (Home holds Explore and Canvas,
/// Library and Search are where other pages send you, Profile holds Settings).
enum TabLayout {
    static let key = "customise.tabs"
    static func layout(_ text: String) -> SectionOrder {
        var layout = SectionOrder(text, all: AppTab.allCases.map(\.rawValue))
        layout.hidden = layout.hidden.intersection([AppTab.glance.rawValue])
        return layout
    }
    static var visible: [AppTab] {
        layout(UserDefaults.standard.string(forKey: key) ?? "").visible.compactMap(AppTab.init(rawValue:))
    }
    static func hideable(_ tab: AppTab) -> Bool { tab == .glance }
}

/// Poster sizes across the app (owner's request, 25 Nov 2026: one standard size for each kind of
/// poster, each with its own slider on Settings → Posters). Four kinds:
/// - shelf cards, in every sideways row (Home, title pages, Explore, Search's browse rows, Stats);
/// - list rows (the Library list, Search results, AI search, the airing calendar);
/// - small rows (Stats rankings, a person's credits, Your Lists, the Library's compact list);
/// - grids, as posters across (Library, Explore, Search).
/// Not these: a title page's big poster, wide pictures (episodes, backdrops), people's photos, Cines.
enum PosterSizes {
    static let shelfKey = "customise.posters.shelf"
    static let rowKey = "customise.posters.row"
    static let smallKey = "customise.posters.small"
    static let gridKey = "customise.posters.grid"
    static let shelfDefault: Double = 120, rowDefault: Double = 78, smallDefault: Double = 48
    static let gridDefault = 3
    static let shelfRange: ClosedRange<Double> = 85...180
    static let rowRange: ClosedRange<Double> = 55...115
    static let smallRange: ClosedRange<Double> = 34...72
    static let gridRange: ClosedRange<Int> = 2...5
    nonisolated(unsafe) private static var migrated = false
    /// A poster's height for its width (2:3).
    static func height(_ width: CGFloat) -> CGFloat { (width * 1.5).rounded() }

    /// The sizes now (for code outside a view; views use `@PosterSizing`).
    static var current: PosterMetrics {
        migrate()
        let defaults = UserDefaults.standard
        func value(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> CGFloat {
            CGFloat(min(range.upperBound, max(range.lowerBound, defaults.object(forKey: key) as? Double ?? fallback)))
        }
        return PosterMetrics(shelf: value(shelfKey, shelfDefault, shelfRange), row: value(rowKey, rowDefault, rowRange),
                             small: value(smallKey, smallDefault, smallRange),
                             columns: min(gridRange.upperBound, max(gridRange.lowerBound, defaults.object(forKey: gridKey) as? Int ?? gridDefault)))
    }

    /// The old Compact / Regular / Large carries over once: Compact is 4 across with 104 pt cards,
    /// Regular 3 with 120, Large 2 with 150.
    static func migrate() {
        // Once per launch: it ran each time any view that reads poster sizes was built (two settings
        // reads per build, constantly while scrolling).
        guard !migrated else { return }
        migrated = true
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gridKey) == nil, let old = defaults.string(forKey: PosterSize.key).flatMap(PosterSize.init(rawValue:)) else { return }
        defaults.set(old.columns, forKey: gridKey)
        defaults.set(old == .compact ? 104.0 : old == .large ? 150.0 : shelfDefault, forKey: shelfKey)
    }
}

/// The four sizes, read together.
struct PosterMetrics: Equatable, Sendable {
    var shelf: CGFloat
    var row: CGFloat
    var small: CGFloat
    var columns: Int
    /// Home's poster cards (the shelf size), as the old setting called it.
    var homeWidth: CGFloat { shelf }
    /// A screenful of a shelf, for rows that size their cards by the screen: as many as a grid has across.
    var shelfHeight: CGFloat { PosterSizes.height(shelf) }
    var rowHeight: CGFloat { PosterSizes.height(row) }
    var smallHeight: CGFloat { PosterSizes.height(small) }
}

/// A view's poster sizes, kept up to date as the sliders move.
@propertyWrapper struct PosterSizing: DynamicProperty {
    @AppStorage(PosterSizes.shelfKey) private var shelf = PosterSizes.shelfDefault
    @AppStorage(PosterSizes.rowKey) private var row = PosterSizes.rowDefault
    @AppStorage(PosterSizes.smallKey) private var small = PosterSizes.smallDefault
    @AppStorage(PosterSizes.gridKey) private var grid = PosterSizes.gridDefault
    init() { PosterSizes.migrate() }
    var wrappedValue: PosterMetrics {
        PosterMetrics(shelf: CGFloat(min(PosterSizes.shelfRange.upperBound, max(PosterSizes.shelfRange.lowerBound, shelf))),
                      row: CGFloat(min(PosterSizes.rowRange.upperBound, max(PosterSizes.rowRange.lowerBound, row))),
                      small: CGFloat(min(PosterSizes.smallRange.upperBound, max(PosterSizes.smallRange.lowerBound, small))),
                      columns: min(PosterSizes.gridRange.upperBound, max(PosterSizes.gridRange.lowerBound, grid)))
    }
}

/// The old poster size setting (Compact / Regular / Large), read once to carry it over
/// (`PosterSizes.migrate`); its key also names the rating and caption switches.
enum PosterSize: String, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    static let key = "customise.posters.size"
    static let ratingKey = "customise.posters.rating"
    static let captionKey = "customise.posters.caption"
    var title: String { rawValue.capitalized }
    /// Posters across a grid (and a row's screenful): four, three or two.
    var columns: Int { switch self { case .compact: 4; case .regular: 3; case .large: 2 } }
    /// Home's poster cards.
    var homeWidth: CGFloat { switch self { case .compact: 104; case .regular: 128; case .large: 160 } }
}
