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
            Text(title).font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
            if let count {
                // Design: 13 pt semibold #d8d4e6 on #17171d, 28 pt tall, #26262e hairline.
                Text(count.formatted()).font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                    .padding(.horizontal, 10).frame(height: 28).pillSurface(border: nil)
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

/// The Parental Guide: the age rating (its country when not the US) and the age it suits, then
/// IMDb's parents guide as five bars per category (sex and nudity, violence, profanity, alcohol
/// and drugs, frightening scenes).
struct ParentalGuideSection: View {
    let extras: TitleExtras?
    @Environment(DiaryStore.self) private var store
    @State private var guide: ParentsGuide?

    private struct Style { let name: String; let symbol: String; let color: String }
    private static let styles: [String: Style] = [
        "NUDITY": Style(name: "Sex & Nudity", symbol: "heart", color: "#e2629f"),
        "VIOLENCE": Style(name: "Violence & Gore", symbol: "figure.fencing", color: "#e2544f"),
        "PROFANITY": Style(name: "Profanity", symbol: "exclamationmark.bubble", color: "#eba23b"),
        "ALCOHOL": Style(name: "Alcohol & Drugs", symbol: "wineglass", color: "#8b6fdc"),
        "FRIGHTENING": Style(name: "Frightening Scenes", symbol: "eye.trianglebadge.exclamationmark", color: "#4cb3c8")
    ]

    var body: some View {
        let tmdbRating = extras?.certification.flatMap { TitleExtras.isAgeRating($0) ? $0 : nil }
        let rating = tmdbRating ?? guide?.certificate.flatMap { TitleExtras.isAgeRating($0) ? $0 : nil }
        let categories = guide?.categories ?? []
        Group {
            if rating != nil || !categories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ShowSectionHeading(title: "Parental Guide").accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 10) {
                        if let rating {
                            HStack(spacing: 12) {
                                Text(rating).font(.app(size: 15, weight: .heavy)).foregroundStyle(.black)
                                    .padding(.horizontal, 12).frame(height: 32).background(.white, in: RoundedRectangle(cornerRadius: 9))
                                if let age = ParentsGuide.age(for: rating) {
                                    Label(age, systemImage: "face.smiling").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                }
                                if tmdbRating != nil, let country = extras?.certificationCountry, country != "US" {
                                    Text(Locale.current.localizedString(forRegionCode: country) ?? country).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.accessibilityElement(children: .combine)
                                .accessibilityLabel("Age rating " + rating + (ParentsGuide.age(for: rating).map { ", suits " + $0 } ?? ""))
                        }
                        ForEach(categories) { category in row(category) }
                        if categories.isEmpty, let advisories = extras?.contentAdvisories, !advisories.isEmpty {
                            Text(advisories.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                }
                .accessibilityIdentifier("title-parental-guide")
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }
        .task(id: extras?.imdbId) {
            guard !store.isPreview, let id = extras?.imdbId else { return }
            guide = await IMDbParentsGuide.shared.guide(imdbID: id)
        }
    }

    private func row(_ category: ParentsGuide.Category) -> some View {
        let style = Self.styles[category.id] ?? Style(name: category.id.capitalized, symbol: "circle", color: "#9a96a8")
        // Studio: the colour says how strong it is (the same in every row), not which category it is.
        let severity = Studio.on(.parentalSeverity)
        let color = severity ? Self.severityColor(category.level) : Color(themed: style.color)
        return HStack(spacing: 10) {
            Image(systemName: style.symbol).font(.app(size: 14, weight: .medium)).foregroundStyle(severity ? HomeStyle.secondary : color).frame(width: 20)
            Text(style.name).font(.app(size: 14)).foregroundStyle(HomeStyle.primary).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule().fill(index < category.bars ? color : color.opacity(0.16)).frame(width: 14, height: 6)
                }
            }
            Text(category.levelName).font(.app(size: 13, weight: .medium)).foregroundStyle(category.level == 0 ? HomeStyle.secondary : color)
                .lineLimit(1).frame(width: 60, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(style.name + ": " + category.levelName)
    }
    /// Studio's severity colours: grey for none, yellow mild, orange moderate, red severe.
    private static func severityColor(_ level: Int) -> Color {
        switch level {
        case ...0: Color(uiColor: .systemGray)
        case 1: Color(uiColor: .systemYellow)
        case 2: Color(uiColor: .systemOrange)
        default: Color(uiColor: .systemRed)
        }
    }
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

/// A small rounded label: genres, status, network.
struct MetaChip: View {
    let text: String
    /// Each kind of chip in its own colour (see `ChipTint`): text in it, a soft fill and edge.
    var tint: Color = HomeStyle.soft
    /// Status and network: bolder than genres (design).
    var fact = false
    var body: some View {
        let radius: CGFloat = fact ? 8 : 9
        Text(text).font(.app(size: 11, weight: fact ? .bold : .semibold)).lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 9).frame(height: 24)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.32), lineWidth: HomeStyle.hairline))
    }
}

/// The fact chips' colours: a status by what it means (green still going, blue coming, grey ended,
/// red cancelled); a network in teal. Genres are one quiet grey.
enum ChipTint {
    /// Native: the same meaning in the system colour of the hue, readable in light and dark mode.
    private static func tint(_ hex: String) -> Color { ThemeStore.current.native ? ThemePalette.native(hex: hex) : Color(webHex: hex) }
    // These colours carry meaning (what a status means), so they stay as they are in every theme.
    static func status(_ raw: String?) -> Color {
        switch raw {
        case "Returning Series": tint("#6ee7a8")
        case "In Production", "Post Production", "Planned", "Pilot", "Rumored": tint("#7aa2ff")
        case "Canceled", "Cancelled": tint("#ff5a36")
        default: tint("#b4b0c2")
        }
    }
    static var network: Color { Color(themed: "#5ad1c4") }
}

/// Genres on one line, then status and network, all trimmed to fit (never wrapping). Each opens its
/// titles: the genre's (of this kind, anime kept anime), the status's (shows), and the network's.
/// The age rating is on the year line above.
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
                    // Genres in one quiet grey (their colours meant nothing).
                    MetaChip(text: genre, tint: HomeStyle.secondary)
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
        // The age rating sits on the year line (TitleHero), not alone on a row of its own.
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
            // The scores share one card, divided by thin lines (four boxes read as four things to tap).
            HStack(spacing: 0) {
                ForEach(Array(boxes.enumerated()), id: \.element.id) { index, box in
                    if index > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(width: 1 / 3, height: 24) }
                    HStack(spacing: 6) {
                        if let service = BrandLogo.service(forRatingSource: box.id) {
                            BrandLogo(service: service, size: 20)
                        } else {
                            Text(box.label).font(.app(size: 9, weight: .bold)).foregroundStyle(box.color)
                        }
                        Text(box.text).font(.app(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(HomeStyle.primary)
                    }.frame(maxWidth: .infinity).frame(height: 46)
                        .accessibilityElement(children: .ignore).accessibilityLabel(RatingsStrip<EmptyView>.name(box.id) + " " + box.text)
                }
            }.cardSurface(14).accessibilityIdentifier("title-rating-boxes")
        }
    }
    static func label(_ key: String) -> String {
        switch key { case "myanimelist": "MAL"; case "metacritic": "META"; case "tomatoes": "RT"; case "popcorn": "AUDIENCE"; case "letterboxd": "LB"; case "rogerebert": "EBERT"; default: key.uppercased() }
    }
    static func color(_ key: String) -> Color {
        switch key {
        case "tmdb": Color(themed: "#01b4e4"); case "myanimelist": Color(themed: "#6c9bff"); case "imdb": Color(themed: "#f5c518")
        case "trakt": Color(themed: "#ff4d5e"); case "metacritic": Color(themed: "#ffcc34"); case "letterboxd": Color(themed: "#00e054")
        default: Color(themed: "#c5c0cf")
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
        switch RatingTone(score: score) { case .low: Color(themed: "#ef5350"); case .mid: Color(themed: "#ffa726"); case .high: Color(themed: "#43c66b") }
    }
    /// "You" and "Community" under the circles, so it's clear whose score each is.
    private func captioned<Content: View>(_ caption: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
            Text(caption).font(.app(size: 11)).foregroundStyle(HomeStyle.secondary).lineLimit(1).fixedSize().accessibilityHidden(true)
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsMine {
            captioned("You") {
            Button(action: onRate) {
                ZStack {
                    Circle().fill(mine.map { Self.color($0).opacity(0.22) } ?? Color.primary.opacity(0.07))
                    Circle().strokeBorder(mine.map { Self.color($0).opacity(0.55) } ?? Color.primary.opacity(0.18), lineWidth: 1.5)
                    if let mine { Text(mine.formatted(.number.precision(.fractionLength(0...1)))).font(.app(size: 17, weight: .bold)).foregroundStyle(Self.color(mine)) }
                    else { Image(systemName: "star").font(.app(size: 17, weight: .semibold)).foregroundStyle(.secondary) }
                }.frame(width: 50, height: 50)
            }.buttonStyle(.springPress).accessibilityLabel("Your rating").accessibilityValue(mine.map { $0.formatted() } ?? "Not rated")
                .accessibilityHint("Tap to rate").accessibilityIdentifier("title-personal-rating")
            }
            }
            // The community average is always shown beside your rating ("–" until a score is known),
            // so the row never changes shape.
            captioned("Community") {
            Button { onCommunity?() } label: {
                ZStack {
                    Circle().stroke(HomeStyle.outline(0.1), lineWidth: 4)
                    if let community {
                        Circle().trim(from: 0, to: min(1, max(0, community / 10))).stroke(Self.color(community), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(community.formatted(.number.precision(.fractionLength(0...1)))).font(.app(size: 15, weight: .bold)).foregroundStyle(Self.color(community))
                    } else {
                        Text("–").font(.app(size: 15, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                    }
                }.frame(width: 46, height: 46).padding(2)
            }.buttonStyle(.springPress).disabled(onCommunity == nil)
                .accessibilityLabel("Average rating").accessibilityValue(community.map { $0.formatted(.number.precision(.fractionLength(1))) + " out of 10" } ?? "Not known yet")
                .accessibilityIdentifier("title-community-rating")
            }
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
                Text(TagEmoji.symbol(for: keyword.name)).font(.app(size: 17))
                Text(keyword.name.capitalizedTag).font(.app(size: 14, weight: .medium)).foregroundStyle(HomeStyle.primary).lineLimit(1)
            }.padding(.horizontal, 14).frame(height: 44).fixedSize()
                .pillSurface(border: Color(themed: "#2a2a33"))
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

// MARK: Companies

/// A company's own logo on a light tile; its initials on a grey disc when TMDB has no logo.
struct CompanyLogo: View {
    let company: TitleCompany
    var body: some View {
        Group {
            if let logo = CatalogTools.image(company.logoPath, size: "w185") {
                // The company's own logo, unchanged; many are black, so they sit on a light tile.
                Artwork(path: logo, title: company.name, contentMode: .fit).padding(.horizontal, 18).padding(.vertical, 16)
                    .background(Color(themed: "#f2f1f5"), in: RoundedRectangle(cornerRadius: 16))
            } else {
                // The initials on a grey disc (the full name in colour read as a link, and the name is
                // written under the tile anyway).
                Monogram(name: company.name)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(themed: "#16151b"), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.outline(0.08)))
    }
    /// "Bill/Phillips Productions" → "BP": the first letter of up to two words (generic words skipped).
    static func initials(_ name: String) -> String {
        let skip: Set<String> = ["productions", "production", "pictures", "films", "film", "studios", "studio", "entertainment", "the", "and", "&", "company", "inc", "inc.", "ltd", "llc"]
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "&")))
            .filter { !$0.isEmpty }
        let kept = words.filter { !skip.contains($0.lowercased()) }
        let letters = (kept.isEmpty ? words : kept).prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}

/// A name's initials on a grey disc, for a company, network or service that has no logo.
struct Monogram: View {
    let name: String
    var size: CGFloat = 48
    var body: some View {
        Text(CompanyLogo.initials(name)).font(.app(size: size * 0.36, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(width: size, height: size).background(Color(uiColor: .tertiarySystemFill), in: Circle())
            .accessibilityHidden(true)
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
                                    Text(company.name).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.ink).lineLimit(1)
                                    Text(CompanyRoutes.label(company, animated: animated)).font(.app(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
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
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(themed: "#3b2f5c"), Color(themed: "#1b1824")], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                // Three shadowed posters flattened into one picture (drawn again only when one changes),
                // not three shadows worked out on every frame of a scroll.
                .drawingGroup()
            // Two lines' room whatever the name, so every card (and the stand-in while loading) is one height.
            Text(list.name).font(.app(size: 15.5, weight: .semibold)).foregroundStyle(HomeStyle.ink).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            Text(list.itemCount.counted("item", "items")).font(.app(size: 13)).foregroundStyle(.secondary)
        }.padding(14).frame(width: width, alignment: .topLeading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.outline(0.08)))
    }
}

struct InListsSection: View {
    let route: CatalogRoute
    let title: String
    @Environment(DiaryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// nil while loading.
    @State private var lists: [CanvasList]?
    var body: some View {
        Group {
            if lists?.isEmpty != true {
                VStack(alignment: .leading, spacing: 12) {
                    ShowSectionHeading(title: "In lists", value: ShowPageRoute.lists(route, title: title), identifier: "title-lists-all")
                        .allowsHitTesting(lists != nil)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            if let lists {
                                ForEach(lists.prefix(6)) { list in
                                    NavigationLink(value: CanvasListRoute(id: list.id, name: list.name, user: list.user)) { ListCollageCard(list: list) }
                                        .buttonStyle(.springPress).accessibilityIdentifier("title-list-\(list.id)")
                                }
                            } else {
                                // While the lists load: cards of the same size where they'll land. The section took no
                                // room until they came, then appeared at full height and pushed the page down mid-scroll.
                                ForEach(0..<2, id: \.self) { _ in ListCollageCardPlaceholder() }
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled().scrollDisabled(lists == nil)
                }
            } else {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        // In no list: the room it held closes smoothly rather than at once.
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: lists?.isEmpty)
        .task(id: route) { lists = (try? await TitleListsCache.load(store: store, route: route, sort: "popular")) ?? [] }
    }
}

/// ListCollageCard's stand-in while lists load: its exact size, in grey.
struct ListCollageCardPlaceholder: View {
    var width: CGFloat = 170
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: width - 28, height: (width - 28) * 0.62 * 1.5)
            Text("A list's name").font(.app(size: 15.5, weight: .semibold)).lineLimit(2, reservesSpace: true)
            Text("10 items").font(.app(size: 13))
        }
        .redacted(reason: .placeholder)
        .padding(14).frame(width: width, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(true)
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
        [Color(themed: "#f0805a"), Color(themed: "#3fb3b0"), Color(themed: "#8e7cf0"), Color(themed: "#e0607e"), Color(themed: "#5d8ff0"), Color(themed: "#d9a441")][index % 6]
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
                Text(collection.name).font(.app(size: showCount ? 24 : 19, weight: .bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                if showCount, let subtitle { Text(subtitle).font(.app(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if !model.items.isEmpty || !model.loaded {
                VStack(alignment: .leading, spacing: 12) {
                    ShowSectionHeading(title: "Related collections", value: ShowPageRoute.collections(route, title: title, anime: anime), identifier: "title-collections-all")
                        .allowsHitTesting(!model.items.isEmpty)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, collection in
                                RelatedCollectionLink(collection: collection, route: route, anime: anime) {
                                    RelatedCollectionCard(collection: collection, index: index).frame(width: 180, height: 116)
                                }.accessibilityIdentifier("title-collection-\(index)")
                            }
                            // While they load: grey cards of the same size where they'll land (the row took no room
                            // until the first came, then pushed the page down mid-scroll).
                            if !model.loaded {
                                ForEach(0..<max(0, 2 - model.items.count), id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .tertiarySystemFill)).frame(width: 180, height: 116)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            } else {
                // A real view keeps the task alive; on an empty Group it never ran.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        // None at all: the room it held closes smoothly rather than at once.
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.loaded && model.items.isEmpty)
        .task(id: route) { await model.load(store: store, route: route, anime: anime, genres: genres) }
    }
}
