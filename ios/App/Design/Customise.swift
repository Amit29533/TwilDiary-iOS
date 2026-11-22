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

/// How big posters are in rows and grids, and what shows on them.
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
