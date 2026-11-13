import SwiftUI
import Charts
import TwilDiaryCore

// MARK: Shared pieces

/// A section title with an optional count badge and a "see all" chevron.
struct ShowSectionHeading<Value: Hashable>: View {
    let title: String
    var count: Int? = nil
    var value: Value? = nil
    var identifier = ""
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
            if let count {
                // Design: 13 pt semibold #d8d4e6 on #17171d, 28 pt tall, #26262e hairline.
                Text(count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                    .padding(.horizontal, 10).frame(height: 28).background(HomeStyle.round, in: Capsule())
                    .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
            }
            Spacer(minLength: 0)
            if let value {
                NavigationLink(value: value) { RoundChevron() }.buttonStyle(.plain)
                    .accessibilityLabel("See all " + title).accessibilityIdentifier(identifier)
            }
        }
    }
}
extension ShowSectionHeading where Value == String {
    init(title: String, count: Int? = nil) { self.title = title; self.count = count; self.value = nil }
}

/// "See all ›" as text, as the Characters and Cast headings show it.
struct SeeAllLink<Value: Hashable>: View {
    let value: Value
    let identifier: String
    var body: some View {
        NavigationLink(value: value) { RoundChevron() }
            .buttonStyle(.springPress).accessibilityLabel("See all").accessibilityIdentifier(identifier)
    }
}

/// A small rounded label: genres, age rating, status, network.
struct MetaChip: View {
    let text: String
    /// Each kind of chip in its own colour (see `ChipTint`): text in it, a soft fill and edge.
    var tint: Color = HomeStyle.soft
    /// Age rating, status and network: bolder than genres (design).
    var fact = false
    var body: some View {
        let radius: CGFloat = fact ? 8 : 9
        Text(text).font(.system(size: 11, weight: fact ? .bold : .semibold)).lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 9).frame(height: 24)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.32), lineWidth: HomeStyle.hairline))
    }
}

/// The chips' colours: a genre its own hue; an age rating by how grown-up it is (green for
/// everyone, yellow, orange, red for adults); a status by what it means (green still going, blue
/// coming, grey ended, red cancelled); a network in teal.
enum ChipTint {
    static func genre(_ name: String) -> Color {
        let hues: [String: String] = [
            "action": "#ff8a65", "adventure": "#ffb454", "action & adventure": "#ff9a5c", "animation": "#ff7ad9",
            "comedy": "#ffd166", "crime": "#ff6b81", "documentary": "#8bd3dd", "drama": "#8fb0ff", "family": "#9be89b",
            "fantasy": "#c39bff", "history": "#d8b38a", "horror": "#ff5c5c", "kids": "#7ee8b8", "music": "#ff9ff3",
            "mystery": "#a99bff", "news": "#9ec5ff", "reality": "#ffc6a8", "romance": "#ff8fab", "science fiction": "#5ad1ff",
            "sci-fi & fantasy": "#7cc8ff", "soap": "#f7a8d0", "talk": "#a0e7e5", "thriller": "#ff9a4d", "tv movie": "#c0bccc",
            "war": "#c9b98f", "war & politics": "#c2b280", "western": "#e0a96d", "anime": "#b9a6ff"
        ]
        if let hex = hues[name.lowercased()] { return Color(webHex: hex) }
        let fallback = ["#8fb0ff", "#ff8fab", "#9be89b", "#ffd166", "#c39bff", "#5ad1ff", "#ffb454"]
        return Color(webHex: fallback[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % fallback.count])
    }
    static func rating(_ value: String) -> Color {
        let rating = value.uppercased()
        if ["G", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "U", "ALL", "0", "6"].contains(rating) { return Color(webHex: "#6ee7a8") }
        if ["PG", "TV-PG", "12", "12A", "PG-12", "7", "10"].contains(rating) { return Color(webHex: "#ffd166") }
        if ["PG-13", "TV-14", "13", "14", "15", "16", "M", "R15+"].contains(rating) { return Color(webHex: "#ffa94d") }
        if ["R", "NC-17", "TV-MA", "18", "R18+", "MA15+", "X"].contains(rating) { return Color(webHex: "#ff6b6b") }
        return Color(webHex: "#c0bccc")
    }
    static func status(_ raw: String?) -> Color {
        switch raw {
        case "Returning Series": Color(webHex: "#6ee7a8")
        case "In Production", "Post Production", "Planned", "Pilot", "Rumored": Color(webHex: "#7aa2ff")
        case "Canceled", "Cancelled": Color(webHex: "#ff5a36")
        default: Color(webHex: "#b4b0c2")
        }
    }
    static let network = Color(webHex: "#5ad1c4")
}

/// Genres on one line, then age rating, status and network, all trimmed to fit (never wrapping).
/// Each opens its titles: the genre's (of this kind, anime kept anime), the age rating's, the
/// status's (shows), and the network's.
struct TitleMetaChips: View {
    let genres: [String]
    let extras: TitleExtras?
    var series = true
    var anime = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !genres.isEmpty {
                ViewThatFits(in: .horizontal) {
                    chips(Array(genres.prefix(3)))
                    chips(Array(genres.prefix(2)))
                    chips(Array(genres.prefix(1)))
                }.accessibilityIdentifier("title-hero-genres")
            }
            if let extras {
                let facts = facts(extras)
                if !facts.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        factRow(facts)
                        factRow(Array(facts.prefix(2)))
                        factRow(Array(facts.prefix(1)))
                    }.accessibilityIdentifier("title-hero-facts")
                }
            }
        }
    }
    private var kind: String { series ? "tv" : "movie" }
    private func chips(_ values: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { genre in
                NavigationLink(value: SearchLabResultsRoute(filters: genreFilters(genre))) {
                    MetaChip(text: genre, tint: ChipTint.genre(genre))
                }.buttonStyle(.springPress).accessibilityHint("Shows more \(genre) titles")
            }
        }.fixedSize()
    }
    private struct Fact: Identifiable {
        let id: String
        let text: String
        let tint: Color
        var search: SearchLabResultsRoute? = nil
        var explore: ExploreSectionRoute? = nil
    }
    private func facts(_ extras: TitleExtras) -> [Fact] {
        var result: [Fact] = []
        if let rating = extras.certification {
            // TMDB filters by US ratings only: another country's rating is shown, not linked.
            let us = ["G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA"].contains(rating.uppercased())
            var filters = DiscoveryFilters(section: .genres)
            filters.type = kind; filters.certification = rating; filters.label = rating
            if anime { filters.language = "ja" }
            result.append(Fact(id: "rating", text: rating, tint: ChipTint.rating(rating), search: us ? SearchLabResultsRoute(filters: filters) : nil))
        }
        if let label = extras.statusLabel {
            // Statuses are a shows' filter; a film's "Released" just says so.
            var route: SearchLabResultsRoute?
            if series, let status = Self.statusFilter(extras.status) {
                var filters = DiscoveryFilters(section: .genres)
                filters.type = "tv"; filters.showStatus = status; filters.label = label + (anime ? " anime" : " shows")
                if anime { filters.language = "ja" }
                route = SearchLabResultsRoute(filters: filters)
            }
            result.append(Fact(id: "status", text: label, tint: ChipTint.status(extras.status), search: route))
        }
        if let network = extras.networks.first {
            result.append(Fact(id: "network", text: network.name, tint: ChipTint.network,
                               explore: CompanyRoutes.explore(network, kind: series ? .tv : .movie)))
        }
        return result
    }
    /// TMDB's status as Search Lab's filter.
    static func statusFilter(_ status: String?) -> String? {
        switch status {
        case "Returning Series": "returning"
        case "Ended": "ended"
        case "Canceled", "Cancelled": "canceled"
        case "In Production", "Post Production", "Planned", "Pilot": "production"
        default: nil
        }
    }
    private func factRow(_ values: [Fact]) -> some View {
        HStack(spacing: 6) {
            ForEach(values) { fact in
                if let route = fact.search {
                    NavigationLink(value: route) { MetaChip(text: fact.text, tint: fact.tint, fact: true) }
                        .buttonStyle(.springPress).accessibilityHint("Shows more titles like this")
                } else if let route = fact.explore {
                    NavigationLink(value: route) { MetaChip(text: fact.text, tint: fact.tint, fact: true) }
                        .buttonStyle(.springPress).accessibilityHint("Shows this network's titles")
                } else {
                    MetaChip(text: fact.text, tint: fact.tint, fact: true)
                }
            }
        }.fixedSize()
    }
    private func genreFilters(_ genre: String) -> DiscoveryFilters {
        var value = DiscoveryFilters(section: .genres)
        value.type = kind
        value.genres = [genre]; value.label = genre
        if anime { value.language = "ja" }
        return value
    }
}

/// Four public scores in equal boxes (TMDB, MAL, IMDb, Trakt first), each out of 10 except
/// Metacritic's 100. Without MDBList only TMDB's own score shows.
struct RatingBoxes: View {
    let scores: [MDBListSyncEngine.SourceScore]
    var tmdbFallback: Double?
    private struct Box: Identifiable { let id: String; let label: String; let color: Color; let text: String }
    private var boxes: [Box] {
        var seen = Set<String>(), result: [Box] = []
        for score in scores {
            let key = RatingsStrip<EmptyView>.canonical(score.source)
            guard !seen.contains(key), let text = Self.text(source: key, value: score.value, score: score.score) else { continue }
            seen.insert(key); result.append(Box(id: key, label: Self.label(key), color: Self.color(key), text: text))
        }
        if !seen.contains("tmdb"), let tmdbFallback, tmdbFallback > 0 {
            result.append(Box(id: "tmdb", label: "TMDB", color: Self.color("tmdb"), text: tmdbFallback.formatted(.number.precision(.fractionLength(1)))))
        }
        return Array(result.sorted { RatingsStrip<EmptyView>.order($0.id) < RatingsStrip<EmptyView>.order($1.id) }.prefix(4))
    }
    var body: some View {
        let boxes = boxes
        if !boxes.isEmpty {
            HStack(spacing: 8) {
                ForEach(boxes) { box in
                    // The source's own logo above its score; a source without one keeps its name.
                    HStack(spacing: 6) {
                        if let service = BrandLogo.service(forRatingSource: box.id) {
                            BrandLogo(service: service, size: 20)
                        } else {
                            Text(box.label).font(.system(size: 9, weight: .bold)).foregroundStyle(box.color)
                        }
                        Text(box.text).font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(HomeStyle.primary)
                    }.frame(maxWidth: .infinity).frame(height: 46)
                        .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                        .accessibilityElement(children: .ignore).accessibilityLabel(RatingsStrip<EmptyView>.name(box.id) + " " + box.text)
                }
            }.accessibilityIdentifier("title-rating-boxes")
        }
    }
    static func label(_ key: String) -> String {
        switch key { case "myanimelist": "MAL"; case "metacritic": "META"; case "tomatoes": "RT"; case "popcorn": "AUDIENCE"; case "letterboxd": "LB"; case "rogerebert": "EBERT"; default: key.uppercased() }
    }
    static func color(_ key: String) -> Color {
        switch key {
        case "tmdb": Color(webHex: "#01b4e4"); case "myanimelist": Color(webHex: "#6c9bff"); case "imdb": Color(webHex: "#f5c518")
        case "trakt": Color(webHex: "#ff4d5e"); case "metacritic": Color(webHex: "#ffcc34"); case "letterboxd": Color(webHex: "#00e054")
        default: Color(webHex: "#c5c0cf")
        }
    }
    /// Everything out of 10 (Trakt's 77% reads 7.7), except Metacritic and Rotten Tomatoes.
    static func text(source: String, value: Double?, score: Double?) -> String? {
        func one(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(1))) }
        switch source {
        case "metacritic", "tomatoes", "popcorn":
            guard let number = value ?? score, number > 0 else { return nil }
            return source == "metacritic" ? "\(Int(number.rounded()))" : "\(Int(number.rounded()))%"
        case "trakt":
            guard let number = value ?? score, number > 0 else { return nil }
            return one(number > 10 ? number / 10 : number)
        case "letterboxd", "rogerebert":
            if let value, value > 0 { return one(value * 2) }
            guard let score, score > 0 else { return nil }
            return one(score / 10)
        default:
            if let value, value > 0 { return one(value > 10 ? value / 10 : value) }
            guard let score, score > 0 else { return nil }
            return one(score / 10)
        }
    }
}

/// Your rating (a filled circle) and the community average (a ring), coloured low red,
/// mid orange, high green.
struct RatingCircles: View {
    let mine: Double?
    let community: Double?
    let onRate: () -> Void
    var onCommunity: (() -> Void)? = nil
    /// False on a preview page: the title isn't in your diary, so there is no rating of yours.
    var showsMine = true
    static func color(_ score: Double) -> Color {
        switch RatingTone(score: score) { case .low: Color(webHex: "#ef5350"); case .mid: Color(webHex: "#ffa726"); case .high: Color(webHex: "#43c66b") }
    }
    var body: some View {
        HStack(spacing: 10) {
            if showsMine {
            Button(action: onRate) {
                ZStack {
                    Circle().fill(mine.map { Self.color($0).opacity(0.22) } ?? Color.white.opacity(0.07))
                    Circle().strokeBorder(mine.map { Self.color($0).opacity(0.55) } ?? Color.white.opacity(0.18), lineWidth: 1.5)
                    if let mine { Text(mine.formatted(.number.precision(.fractionLength(0...1)))).font(.system(size: 17, weight: .bold)).foregroundStyle(Self.color(mine)) }
                    else { Image(systemName: "star").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary) }
                }.frame(width: 50, height: 50)
            }.buttonStyle(.springPress).accessibilityLabel("Your rating").accessibilityValue(mine.map { $0.formatted() } ?? "Not rated")
                .accessibilityHint("Tap to rate").accessibilityIdentifier("title-personal-rating")
            }
            // The community average is always shown beside your rating ("–" until a score is known),
            // so the row never changes shape.
            Button { onCommunity?() } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 4)
                    if let community {
                        Circle().trim(from: 0, to: min(1, max(0, community / 10))).stroke(Self.color(community), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(community.formatted(.number.precision(.fractionLength(0...1)))).font(.system(size: 15, weight: .bold)).foregroundStyle(Self.color(community))
                    } else {
                        Text("–").font(.system(size: 15, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                    }
                }.frame(width: 46, height: 46).padding(2)
            }.buttonStyle(.springPress).disabled(onCommunity == nil)
                .accessibilityLabel("Average rating").accessibilityValue(community.map { $0.formatted(.number.precision(.fractionLength(1))) + " out of 10" } ?? "Not known yet")
                .accessibilityIdentifier("title-community-rating")
        }
    }
}

// MARK: Tags

/// TMDB keywords as tags in three scrolling rows; each opens titles with the same tag.
struct TitleTagsSection: View {
    let keywords: [TitleKeyword]
    let kind: MediaKind
    var body: some View {
        if !keywords.isEmpty {
            // Design: three rows of 52 pt pills (#17171d, #2a2a33 hairline) scrolling sideways together,
            // a 20 pt emoji and a 16 pt medium label, 8 pt apart.
            // Each row scrolls on its own and its pills sit 8 pt apart (no grid columns, so no gaps).
            // Rows follow the count: up to 6 tags one row, more two (never three); every tag is shown.
            VStack(alignment: .leading, spacing: 16) {
                ShowSectionHeading(title: "Tags", count: keywords.count)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(TagRows.split(keywords).enumerated()), id: \.offset) { _, row in
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) { ForEach(row) { keyword in pill(keyword) } }.padding(.vertical, 1)
                        }.scrollIndicators(.hidden).scrollClipDisabled()
                    }
                }
            }
        }
    }
    private func pill(_ keyword: TitleKeyword) -> some View {
        NavigationLink(value: route(keyword)) {
            HStack(spacing: 8) {
                Text(TagEmoji.symbol(for: keyword.name)).font(.system(size: 17))
                Text(keyword.name.capitalizedTag).font(.system(size: 14, weight: .medium)).foregroundStyle(HomeStyle.primary).lineLimit(1)
            }.padding(.horizontal, 14).frame(height: 44).fixedSize()
                .background(HomeStyle.round, in: Capsule()).overlay(Capsule().strokeBorder(Color(webHex: "#2a2a33"), lineWidth: HomeStyle.hairline))
        }.buttonStyle(.springPress).accessibilityIdentifier("title-tag-\(keyword.id)")
    }
    private func route(_ keyword: TitleKeyword) -> ExploreSectionRoute {
        var filters = DiscoveryFilters(section: .genres)
        filters.type = kind == .movie ? "movie" : "tv"
        filters.keyword = keyword.id
        filters.label = keyword.name.capitalizedTag
        return ExploreSectionRoute(section: .genres, filters: filters)
    }
}
extension String {
    /// TMDB keywords are lower case ("coming of age"); a tag reads "Coming Of Age" → "Coming of Age".
    var capitalizedTag: String {
        let small: Set<String> = ["of", "the", "a", "an", "and", "in", "on", "to", "for", "with"]
        return split(separator: " ").enumerated().map { index, word in
            let value = String(word)
            if value.uppercased() == value && value.count > 1 { return value }
            return index > 0 && small.contains(value.lowercased()) ? value.lowercased() : value.prefix(1).uppercased() + value.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: Rating trend

/// Each episode's average rating across the season, from Trakt and TMDB (whichever have
/// ratings), with the season average and the best and lowest episode.
struct RatingTrendCard: View {
    let show: Int
    let season: Int
    let tmdb: [EpisodeRatingPoint]
    let current: Int?
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var trakt: [EpisodeRatingPoint] = []
    @State private var source = "Trakt"
    private struct Source { let name: String; let logo: BrandLogo.Service; let points: [EpisodeRatingPoint] }
    private var sources: [Source] {
        [Source(name: "Trakt", logo: .trakt, points: trakt), Source(name: "TMDB", logo: .tmdb, points: tmdb)].filter { EpisodeRatingSummary($0.points) != nil }
    }
    var body: some View {
        let sources = sources
        let chosen = sources.first { $0.name == source } ?? sources.first
        Group {
            if let chosen, let summary = EpisodeRatingSummary(chosen.points), summary.points.count >= 2 {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("Rating trend").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                        Spacer(minLength: 8)
                        // Whose ratings: the service's own logo; with both, tap one to switch.
                        ForEach(sources, id: \.name) { item in
                            let on = item.name == chosen.name
                            Button { source = item.name } label: {
                                BrandLogo(service: item.logo, size: 22)
                                    .opacity(on ? 1 : 0.45)
                                    .frame(width: 44, height: 40)
                                    .background(on ? theme.accent.opacity(0.22) : Color.white.opacity(0.05), in: Capsule())
                                    .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.6) : .white.opacity(0.08), lineWidth: 1))
                            }.buttonStyle(.plain).disabled(sources.count < 2)
                                .accessibilityLabel(item.name).accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    chart(summary).frame(height: 170)
                    HStack(spacing: 10) {
                        if summary.best.score == summary.lowest.score {
                            // One score throughout: no "Best: Episode 1 / Lowest: Episode 1".
                            stat("Average", summary.average, "the same for every episode")
                        } else {
                            stat("Average", summary.average, "all episodes")
                            stat("Best", summary.best.score, "Episode \(summary.best.episode)")
                            stat("Lowest", summary.lowest.score, "Episode \(summary.lowest.episode)")
                        }
                    }
                }.padding(18).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08)))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("title-rating-trend")
            } else {
                // A real view keeps the task alive; on an empty Group it never ran.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }.task(id: "\(show):\(season)") {
            trakt = []
            if let points = try? await TraktTitleReads.episodeRatings(store: store, show: show, season: season) { trakt = points }
        }
    }
    private func chart(_ summary: EpisodeRatingSummary) -> some View {
        let last = summary.points.last?.episode ?? 1
        let ticks = Array(Set([1, max(1, last / 4), max(1, last / 2), max(1, last * 3 / 4), last])).sorted()
        return Chart {
            ForEach(summary.points, id: \.episode) { point in
                LineMark(x: .value("Episode", point.episode), y: .value("Rating", point.score))
                    .interpolationMethod(.catmullRom).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(LinearGradient(colors: [Color(webHex: "#4fd1c5"), Color(webHex: "#43c66b"), Color(webHex: "#f5c518")], startPoint: .leading, endPoint: .trailing))
            }
            RuleMark(y: .value("Average", summary.average)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(theme.accent.opacity(0.8))
            if let current, let point = summary.points.first(where: { $0.episode == current }) {
                PointMark(x: .value("Episode", point.episode), y: .value("Rating", point.score)).symbolSize(90).foregroundStyle(theme.accent)
            }
        }
        .chartYScale(domain: summary.range)
        .chartXScale(domain: (summary.points.first?.episode ?? 1)...max(last, (summary.points.first?.episode ?? 1) + 1))
        .chartXAxis { AxisMarks(values: ticks) { value in AxisValueLabel { Text("E\(value.as(Int.self) ?? 0)").font(.system(size: 11)).foregroundStyle(value.as(Int.self) == current ? theme.accent : .secondary) } } }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.07)); AxisValueLabel().foregroundStyle(.secondary) } }
        .accessibilityLabel("Episode ratings from episode \(summary.points.first?.episode ?? 1) to \(last)")
    }
    private func stat(_ label: String, _ value: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 20, weight: .bold)).foregroundStyle(RatingCircles.color(value))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }
}

// MARK: Companies

/// A company's own logo on a dark tile; its name in colour when TMDB has no logo.
struct CompanyLogo: View {
    let company: TitleCompany
    var body: some View {
        Group {
            if let logo = CatalogTools.image(company.logoPath, size: "w185") {
                // The company's own logo, unchanged; many are black, so they sit on a light tile.
                Artwork(path: logo, title: company.name, contentMode: .fit).padding(.horizontal, 18).padding(.vertical, 16)
                    .background(Color(webHex: "#f2f1f5"), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Text(company.name).font(.system(size: 18, weight: .heavy)).foregroundStyle(Self.tint(company.name))
                    .lineLimit(2).minimumScaleFactor(0.6).multilineTextAlignment(.center).padding(10)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(webHex: "#16151b"), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
    static func tint(_ name: String) -> Color {
        let values = ["#6ee07a", "#ff9b4a", "#ff6b7d", "#5cc8ff", "#ffd54a", "#b48cff"]
        return Color(webHex: values[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % values.count])
    }
}

enum CompanyRoutes {
    static func label(_ company: TitleCompany, animated: Bool) -> String {
        company.isNetwork ? "Network" : animated ? "Animation studio" : "Production company"
    }
    static func explore(_ company: TitleCompany, kind: MediaKind) -> ExploreSectionRoute {
        var filters = DiscoveryFilters(section: .genres)
        filters.label = company.name
        if company.isNetwork { filters.network = company.id; filters.type = "tv" }
        else { filters.company = company.id; filters.type = kind == .movie ? "movie" : "tv" }
        return ExploreSectionRoute(section: .genres, filters: filters)
    }
}

struct CompaniesSection: View {
    let route: CatalogRoute
    let title: String
    let extras: TitleExtras
    let animated: Bool
    var body: some View {
        let companies = extras.companies
        if !companies.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShowSectionHeading(title: "Companies", value: ShowPageRoute.companies(route, title: title), identifier: "title-companies-all")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(companies.prefix(8), id: \.key) { company in
                            NavigationLink(value: CompanyRoutes.explore(company, kind: route.kind)) {
                                VStack(spacing: 6) {
                                    CompanyLogo(company: company).frame(width: 170, height: 96)
                                    Text(company.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(CompanyRoutes.label(company, animated: animated)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(width: 170)
                            }.buttonStyle(.springPress).accessibilityIdentifier("title-company-\(company.key)")
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
            }
        }
    }
}

// MARK: In lists

/// A Trakt list as a card: its first posters fanned out, its name and size.
struct ListCollageCard: View {
    let list: CanvasList
    var width: CGFloat = 170
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                if list.posters.isEmpty {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(webHex: "#3b2f5c"), Color(webHex: "#1b1824")], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay { DiaryIcon(name: "list-video", size: 28).foregroundStyle(.white.opacity(0.6)) }
                } else {
                    ForEach(Array(list.posters.prefix(3).enumerated().reversed()), id: \.offset) { index, poster in
                        Artwork(path: CatalogTools.image(poster, size: "w185"), title: list.name, initialsOnly: false)
                            .frame(width: (width - 28) * 0.62, height: (width - 28) * 0.62 * 1.5).clipShape(RoundedRectangle(cornerRadius: 9))
                            .shadow(color: .black.opacity(0.5), radius: 6, x: 3)
                            .offset(x: CGFloat(index) * (width - 28) * 0.19)
                    }
                }
            }.frame(width: width - 28, height: (width - 28) * 0.62 * 1.5, alignment: .leading).clipped()
            Text(list.name).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
            Text(list.itemCount.counted("item", "items")).font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(14).frame(width: width, alignment: .topLeading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
    }
}

struct InListsSection: View {
    let route: CatalogRoute
    let title: String
    @Environment(DiaryStore.self) private var store
    @State private var lists: [CanvasList] = []
    var body: some View {
        Group {
            if !lists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShowSectionHeading(title: "In lists", value: ShowPageRoute.lists(route, title: title), identifier: "title-lists-all")
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(lists.prefix(6)) { list in
                                NavigationLink(value: CanvasListRoute(id: list.id, name: list.name, user: list.user)) { ListCollageCard(list: list) }
                                    .buttonStyle(.springPress).accessibilityIdentifier("title-list-\(list.id)")
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            } else {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }.task(id: route) { lists = (try? await TitleListsCache.load(store: store, route: route, sort: "popular")) ?? [] }
    }
}

// MARK: Related collections

/// Related collections come from TMDb, never your library: the movie's own TMDb collection (a film
/// series), then TMDb's catalogue for each of the title's genres with TMDb's count of titles.
struct RelatedCollection: Identifiable, Hashable {
    enum Kind: Hashable { case series(Int), genre(String) }
    let kind: Kind
    let name: String
    var count: Int?
    var posters: [String]
    var id: String { switch kind { case .series(let id): "series:\(id)"; case .genre(let name): "genre:" + name } }
    static func tint(_ index: Int) -> Color {
        [Color(webHex: "#f0805a"), Color(webHex: "#3fb3b0"), Color(webHex: "#8e7cf0"), Color(webHex: "#e0607e"), Color(webHex: "#5d8ff0"), Color(webHex: "#d9a441")][index % 6]
    }
    /// The TMDb catalogue a genre card opens: same media type, anime limited to Japanese titles.
    static func filters(genre: String, route: CatalogRoute, anime: Bool) -> DiscoveryFilters {
        var value = DiscoveryFilters(section: .genres)
        value.type = route.kind == .movie ? "movie" : "tv"
        value.genres = [genre]; value.label = genre
        if anime { value.language = "ja" }
        return value
    }
}

/// Loads the cards: TMDb extras for the collection and genres, then one discover page per genre
/// for its count and artwork. Kept per title so the section and its page agree.
@MainActor @Observable final class RelatedCollectionsModel {
    private(set) var items: [RelatedCollection] = []
    private(set) var loaded = false
    private static var cache: [String: [RelatedCollection]] = [:]
    /// True when there was no TMDB key on the phone and the diary server had nothing either.
    private(set) var needsKey = false
    func load(store: DiaryStore, route: CatalogRoute, anime: Bool, genres fallback: [String] = []) async {
        let key = "\(route.kind.rawValue):\(route.id)"
        if let saved = Self.cache[key] { items = saved; loaded = true; return }
        var result: [RelatedCollection] = []
        func collectionCard(_ series: TitleCollectionRef) -> RelatedCollection {
            RelatedCollection(kind: .series(series.id), name: series.name, count: nil,
                              posters: [series.backdropPath, series.posterPath].compactMap { CatalogTools.image($0, size: "w780") })
        }
        // Animation says nothing for an anime; its other genres are the interesting ones.
        func wanted(_ name: String) -> Bool { !(anime && name == "Animation") }
        if let token = TMDBDirect.token(store), let overview = try? await TMDBDirect.overview(route, token: token), !overview.genres.isEmpty || overview.collection != nil {
            // The phone reads TMDB itself with your key; the diary server is only a backup.
            if let series = overview.collection { result.append(collectionCard(series)) }
            items = result
            for genre in overview.genres.filter({ wanted($0.name) }).prefix(6) {
                guard let page = try? await TMDBDirect.genre(genre.id, kind: route.kind, anime: anime, token: token), (page.total ?? 0) > 0 else { continue }
                result.append(RelatedCollection(kind: .genre(genre.name), name: genre.name, count: page.total, posters: page.artwork))
                items = result
            }
        }
        if result.isEmpty {
            let extras = try? await TitleExtrasCache.load(store: store, route: route)
            if let series = extras?.collection { result.append(collectionCard(series)) }
            items = result
            let names = (extras?.genres.map(\.name)).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            for genre in names.filter(wanted).prefix(6) {
                let query = RelatedCollection.filters(genre: genre, route: route, anime: anime).query(section: .genres, page: 1)
                guard let page = try? await LiveDiscoveryService(store: store).page(query), !page.items.isEmpty else { continue }
                let art = page.items.compactMap { CatalogTools.image($0.backdropPath, size: "w780") ?? $0.artwork }.prefix(2)
                result.append(RelatedCollection(kind: .genre(genre), name: genre, count: page.totalResults, posters: Array(art)))
                items = result
            }
        }
        needsKey = result.isEmpty && TMDBDirect.token(store) == nil
        if !result.isEmpty { Self.cache[key] = result }
        loaded = true
    }

}

struct RelatedCollectionCard: View {
    let collection: RelatedCollection
    let index: Int
    var showCount = false
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(collection.posters, id: \.self) { path in Artwork(path: path, title: collection.name, initialsOnly: false) }
            }
            RelatedCollection.tint(index).opacity(0.72)
            VStack(spacing: 3) {
                Text(collection.name).font(.system(size: showCount ? 24 : 19, weight: .bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                if showCount, let subtitle { Text(subtitle).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
            }.shadow(color: .black.opacity(0.35), radius: 4).padding(.horizontal, 10)
        }.clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityElement(children: .ignore).accessibilityLabel(collection.name + (subtitle.map { ", " + $0 } ?? ""))
    }
    private var subtitle: String? {
        if case .series = collection.kind { return "TMDb collection" }
        return collection.count.map { $0.counted("title", "titles") }
    }
}

/// Opens a card: a film series' own page, or TMDb's catalogue for a genre.
struct RelatedCollectionLink<Label: View>: View {
    let collection: RelatedCollection
    let route: CatalogRoute
    let anime: Bool
    @ViewBuilder let label: Label
    var body: some View {
        switch collection.kind {
        case .series(let id):
            NavigationLink(value: ShowPageRoute.tmdbCollection(id: id, name: collection.name)) { label }.buttonStyle(.springPress)
        case .genre(let genre):
            NavigationLink(value: SearchLabResultsRoute(filters: RelatedCollection.filters(genre: genre, route: route, anime: anime))) { label }.buttonStyle(.springPress)
        }
    }
}

struct RelatedCollectionsSection: View {
    let route: CatalogRoute
    let title: String
    let anime: Bool
    /// The page's own genres, used when TMDB's aren't available.
    var genres: [String] = []
    @Environment(DiaryStore.self) private var store
    @State private var model = RelatedCollectionsModel()
    var body: some View {
        Group {
            if !model.items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ShowSectionHeading(title: "Related collections", value: ShowPageRoute.collections(route, title: title, anime: anime), identifier: "title-collections-all")
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, collection in
                                RelatedCollectionLink(collection: collection, route: route, anime: anime) {
                                    RelatedCollectionCard(collection: collection, index: index).frame(width: 180, height: 116)
                                }.accessibilityIdentifier("title-collection-\(index)")
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            } else {
                // A real view keeps the task alive; on an empty Group it never ran.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }.task(id: route) { await model.load(store: store, route: route, anime: anime, genres: genres) }
    }
}
