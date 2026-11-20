import SwiftUI
import TwilDiaryCore

/// A film or show to open in JellySpace.
struct JellyDetailRoute: Hashable {
    let id: String
    let name: String
}

/// A picture from Jellyfin (its home-network address, which the public artwork loader refuses), kept
/// by JellyfinPosterCache; filled or fitted.
struct JellyImage: View {
    let url: URL?
    var mode: ContentMode = .fill
    @State private var image: UIImage?
    var body: some View {
        if let url, let image = image ?? JellyfinPosterCache.shared.resident(url) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
        } else {
            Color.clear.task(id: url) { if let url { image = await JellyfinPosterCache.shared.image(url) } }
        }
    }
}

/// A film's or show's poster and name in the top bar, faded in once its picture has scrolled under
/// the bar (as a diary title page does).
struct JellyCompactTitle: View {
    let name: String
    let poster: URL?
    let state: CompactHeaderState
    /// The page's width: the title keeps clear of the back and ••• buttons (see CompactTitleNavigation).
    var pageWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let progress = state.progress
        HStack(spacing: 8) {
            JellyImage(url: poster).frame(width: 28, height: 28).background(HomeStyle.card)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
        }
        .frame(height: 28)
        .frame(maxWidth: pageWidth > 0 ? max(120, pageWidth - 160) : nil)
        .opacity(Double(progress))
        .offset(y: reduceMotion ? 0 : (1 - progress) * 6)
        .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityAddTraits(.isHeader)
        .accessibilityHidden(progress < 0.5)
    }
}

/// A film's or show's page, before playing, laid out as Netflix's is: the backdrop fading into the
/// page; "SERIES" and the name on the left; one line of score, years, age rating, length and the
/// file's badges; its place in the Top 10; Play (or Resume, or a show's next episode) and Trailer
/// across the page; the story, the cast and who made it (all of them a tap away); Favourite, Watched,
/// Share and File info; then tabs for the episodes, similar titles and extras. Other players are in •••.
struct JellyDetailPage: View {
    let route: JellyDetailRoute
    @State private var detail: JellyfinClient.Detail?
    @State private var item: JellyfinClient.Item?
    @State private var seasons: [JellyfinClient.Item] = []
    @State private var season: String?
    @State private var episodes: [JellyfinClient.Item] = []
    @State private var nextEpisode: JellyfinClient.Item?
    /// A show you haven't started: its first episode (season 1's, not a special's).
    @State private var firstEpisode: JellyfinClient.Item?
    @State private var similar: [JellyfinClient.Item] = []
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    @State private var played = false
    @State private var favourite = false
    @State private var fullOverview = false
    @State private var user: String?
    /// Trailer files and special features.
    @State private var extras: [JellyfinClient.Item] = []
    /// The version of a film to play (when it's stored in more than one quality).
    @State private var version: String?
    @Environment(\.openURL) private var openURL
    @Environment(AppRouter.self) private var router
    @Environment(DiaryStore.self) private var store
    @AppStorage(JellyPrefs.diaryKey) private var diaryOn = true
    @State private var showFileInfo = false
    /// The poster and name in the top bar once the picture has scrolled under it.
    @State private var headerState = CompactHeaderState()
    @State private var pageWidth: CGFloat = 0

    private var series: Bool { detail?.kind == "Series" }
    private var name: String { detail?.Name ?? route.name }

    /// The tabs under the buttons, as Netflix has them.
    private enum Tab: String, CaseIterable { case episodes = "Episodes", similar = "More like this", extras = "Extras" }
    @State private var tab: Tab?
    @Namespace private var tabSpace
    /// The whole cast and crew, the genres and the age rating (Cast's "more").
    @State private var showCredits = false

    var body: some View {
        EdgeToEdgeScroll(artworkUnderBar: true) {
            VStack(alignment: .leading, spacing: 0) {
                if let client = JellySpace.client {
                    picture(client)
                    VStack(alignment: .leading, spacing: 0) {
                        titleBlock
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                                headerState.update(ScrollLinkedBarTitle.progress(headingBottom: bottom))
                            }
                        if let detail {
                            summary(detail, client: client).padding(.top, 10)
                            tabsSection(client).padding(.top, 24)
                        } else if let failure {
                            RetryNotice(message: failure) { Task { await load() } }.padding(.top, 16)
                        } else {
                            DiaryLoadingPlaceholder(height: 260, label: "Loading").padding(.top, 16)
                        }
                    }.padding(.horizontal, 16)
                }
            }.padding(.bottom, 48)
        }
        .diaryScreenBackground()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .toolbar {
            ToolbarItem(placement: .principal) {
                JellyCompactTitle(name: name, poster: JellySpace.client.flatMap { client in
                    detail?.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Primary", tag: $0, width: 200) }
                }, state: headerState, pageWidth: pageWidth)
            }
            if let detail, let client = JellySpace.client, hasMore(detail, client: client) {
                ToolbarItem(placement: .topBarTrailing) { moreMenu(detail, client: client) }
            }
        }
        .sheet(isPresented: $showFileInfo) {
            if let detail, let source = chosenSource(detail) {
                JellyFileInfo(name: name, source: source).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showCredits) {
            if let detail, let client = JellySpace.client {
                credits(detail, client: client).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .task { await load() }
        .task(id: season) { await loadEpisodes() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load(); await loadEpisodes() } }) { JellyPlayerView(playback: $0) }
    }

    // MARK: The picture and the title

    /// The backdrop across the top, fading into the page at its foot.
    private func picture(_ client: JellyfinClient) -> some View {
        let backdrop = detail?.BackdropImageTags?.first.flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Backdrop", tag: $0, width: 1200) }
        let primary = detail?.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Primary", tag: $0, width: 900) }
        // The picture fills a fixed box laid out at the screen's width; it never sizes the page (a
        // filled picture in a plain stack made the whole page wider than the screen).
        return Color.clear.frame(maxWidth: .infinity).frame(height: 300)
            .overlay { JellyImage(url: backdrop ?? primary) }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
    }
    /// "SERIES" with Jellyfin's mark, then the name, large, on the left.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let kind = kindLabel {
                HStack(spacing: 6) {
                    Image("jellyfin-mark").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(kind).font(.system(size: 12, weight: .semibold)).tracking(3).foregroundStyle(HomeStyle.secondary)
                }.accessibilityHidden(true)
            }
            // Long names: up to three lines, a little smaller before they end in "…" (the whole name
            // is in the top bar once scrolled, and in File info).
            Text(name).font(.system(size: 28, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary)
                .lineLimit(3).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -26)
    }
    private var kindLabel: String? {
        guard let kind = detail?.kind else { return nil }
        switch kind {
        case "Series": return "SERIES"
        case "Movie": return "FILM"
        default: return kind.uppercased()
        }
    }

    // MARK: The details, Play, the story and the buttons

    private func summary(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailsLine(detail)
            if let rank = topRank { topTenLine(rank) }
            if !series, let sources = detail.MediaSources, sources.count > 1 { versionMenu(sources) }
            VStack(spacing: 8) {
                wideButton(playLabel(detail), symbol: "play.fill", primary: true) { play(client) }
                    .accessibilityIdentifier("jellyspace-detail-play")
                if let trailer = trailer(detail, client: client) {
                    wideButton("Trailer", symbol: "film", primary: false, action: trailer).accessibilityIdentifier("jellyspace-detail-trailer")
                }
            }.padding(.top, 4)
            if let overview = detail.Overview.map(JellySpace.plainText), !overview.isEmpty {
                Text(overview).font(.system(size: 15)).foregroundStyle(HomeStyle.primary)
                    .lineLimit(fullOverview ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { fullOverview.toggle() } }
                    .accessibilityAddTraits(.isButton).accessibilityHint(fullOverview ? "Shows less" : "Shows the whole story")
                    .padding(.top, 4)
            }
            creditLines(detail)
            actionRow(detail, client: client).padding(.top, 8)
        }
    }

    /// One line: the score, the years, the age rating (filled), the seasons or length, then the
    /// file's badges (outlined); the least important badges drop off when they don't all fit.
    private func detailsLine(_ detail: JellyfinClient.Detail) -> some View {
        let outlined = badges(detail).filter { $0.text != detail.OfficialRating }
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: outlined.count, through: 0, by: -1)), id: \.self) { count in
                HStack(spacing: 8) {
                    if let score = detail.CommunityRating, score > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color(themed: "#f5c451"))
                            Text(String(format: "%.1f", score)).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        }
                    }
                    if let critics = detail.CriticRating, critics > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(Color(red: 0.98, green: 0.2, blue: 0.04)).frame(width: 9, height: 9)
                            Text("\(Int(critics))%").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        }
                    }
                    if let years = years(detail) { Text(years).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary) }
                    if let rating = detail.OfficialRating, !rating.isEmpty {
                        Text(rating).font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.primary.opacity(0.9))
                            .padding(.horizontal, 5).frame(height: 18).background(Color.primary.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    }
                    if let length = length(detail) { Text(length).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary) }
                    ForEach(outlined.prefix(count), id: \.text) { badge($0.symbol, $0.text) }
                }.fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([years(detail), detail.OfficialRating, length(detail)].compactMap { $0 } + outlined.map(\.text)).joined(separator: ", "))
    }
    /// "2023"; a show's "2021–2024".
    private func years(_ detail: JellyfinClient.Detail) -> String? {
        guard let year = detail.ProductionYear else { return nil }
        let end = detail.EndDate.flatMap { Int($0.prefix(4)) }
        if series, let end, end != year { return "\(year)–\(end)" }
        return String(year)
    }
    /// A film's "1h 52m"; a show's "3 seasons", or with one season its "6 episodes".
    private func length(_ detail: JellyfinClient.Detail) -> String? {
        if series {
            let count = seasons.filter { ($0.IndexNumber ?? 0) >= 1 }.count
            if count > 1 { return "\(count) seasons" }
            if !episodes.isEmpty { return episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes" }
            return count == 1 ? "1 season" : nil
        }
        guard let minutes = detail.RunTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 else { return nil }
        return Self.runtime(minutes)
    }
    /// "#3 in Movies": where it stands in the home's Top 10, when it's there.
    private var topRank: String? {
        guard let shelf = JellyHomeCache.discover?.top, let index = shelf.items.firstIndex(where: { $0.Id == route.id }) else { return nil }
        return "#\(index + 1) in " + (shelf.library?.name ?? "the Top 10")
    }
    private func topTenLine(_ rank: String) -> some View {
        HStack(spacing: 8) {
            VStack(spacing: -2) {
                Text("TOP").font(.system(size: 7, weight: .heavy))
                Text("10").font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(.white).frame(width: 22, height: 24)
            .background(Color(red: 0.86, green: 0.1, blue: 0.12), in: RoundedRectangle(cornerRadius: 3))
            Text(rank).font(.system(size: 15, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(rank + " in the Top 10")
    }
    /// Play (solid, in the page's text colour) or Trailer (grey), across the page.
    private func wideButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(primary ? ThemeStore.current.canvas : HomeStyle.primary)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(primary ? AnyShapeStyle(HomeStyle.primary) : AnyShapeStyle(Color.primary.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.springPress)
    }

    private struct CreditGroup: Identifiable {
        let id: String
        let people: [JellyfinClient.Detail.Person]
    }
    private func creditGroups(_ detail: JellyfinClient.Detail) -> [CreditGroup] {
        let people = detail.People ?? []
        return [CreditGroup(id: "Cast", people: people.filter { $0.kind == "Actor" || $0.kind == "GuestStar" }),
                CreditGroup(id: "Directors", people: people.filter { $0.kind == "Director" }),
                CreditGroup(id: "Writers", people: people.filter { $0.kind == "Writer" }),
                CreditGroup(id: "Producers", people: people.filter { $0.kind == "Producer" })].filter { !$0.people.isEmpty }
    }
    private func genreNames(_ detail: JellyfinClient.Detail) -> [String] {
        let items = detail.GenreItems ?? []
        return items.isEmpty ? (detail.Genres ?? []) : items.compactMap(\.Name)
    }
    /// "Cast: A, B, C … more", "Director: D", "Genres: E, F": a tap shows them all.
    @ViewBuilder private func creditLines(_ detail: JellyfinClient.Detail) -> some View {
        let people = detail.People ?? []
        let cast = people.filter { $0.kind == "Actor" || $0.kind == "GuestStar" }.compactMap(\.Name)
        let directors = people.filter { $0.kind == "Director" }.compactMap(\.Name)
        let writers = people.filter { $0.kind == "Writer" }.compactMap(\.Name)
        let genres = genreNames(detail)
        if !cast.isEmpty || !directors.isEmpty || !writers.isEmpty || !genres.isEmpty {
            Button { showCredits = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if !cast.isEmpty { creditLine("Cast", cast, more: true) }
                    if !directors.isEmpty { creditLine(directors.count == 1 ? "Director" : "Directors", directors, more: false) }
                    else if !writers.isEmpty { creditLine(series ? "Creator" : "Writer", writers, more: false) }
                    if !genres.isEmpty { creditLine("Genres", genres, more: cast.isEmpty) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("Shows the whole cast and crew").accessibilityIdentifier("jellyspace-detail-credits")
        }
    }
    private func creditLine(_ label: String, _ names: [String], more: Bool) -> some View {
        let shown = names.prefix(3).joined(separator: ", ")
        let tail = more ? Text(" … more").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary) : Text("")
        return Text("\(label): \(shown)\(tail)").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
    }

    /// Favourite, Watched, Share and (a film) File info: a symbol with its name under it.
    private func actionRow(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        HStack(alignment: .top, spacing: 0) {
            actionButton(favourite ? "heart.fill" : "heart", title: "Favourite", label: favourite ? "Remove from favourites" : "Add to favourites") {
                guard let user else { return }
                favourite.toggle()
                let now = favourite
                Task { try? await client.setFavourite(route.id, user: user, now) }
            }
            actionButton(played ? "checkmark.circle.fill" : "checkmark.circle", title: "Watched", label: played ? "Mark unwatched" : "Mark watched") {
                guard let user else { return }
                played.toggle()
                let now = played
                Task { try? await client.setPlayed(route.id, user: user, now) }
                // A film marked watched goes in the diary too (as the long-press menu does).
                if now, diaryOn, let film = item, film.kind == "Movie" {
                    Task { _ = await JellyDiary.mark(film, client: client, store: store) }
                }
            }
            ShareLink(item: shareText(detail)) { actionLabel("paperplane", title: "Share") }
                .buttonStyle(.springPress).accessibilityLabel("Share " + name)
            if !series, chosenSource(detail) != nil {
                actionButton("info.circle", title: "File info", label: "File info") { showFileInfo = true }
                    .accessibilityIdentifier("jellyspace-detail-file-info")
            }
        }
    }
    private func actionButton(_ symbol: String, title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(symbol, title: title) }
            .buttonStyle(.springPress).accessibilityLabel(label)
            .sensoryFeedback(.selection, trigger: symbol)
    }
    private func actionLabel(_ symbol: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(HomeStyle.primary)
                .contentTransition(.symbolEffect(.replace)).frame(height: 26)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
    }
    /// "Dune (2021)", and its IMDb page when Jellyfin knows it.
    private func shareText(_ detail: JellyfinClient.Detail) -> String {
        let title = [detail.Name ?? name, detail.ProductionYear.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if let imdb = detail.ProviderIds?["Imdb"], !imdb.isEmpty { return title + "\nhttps://www.imdb.com/title/" + imdb + "/" }
        return title
    }

    // MARK: The file's badges

    private func badge(_ symbol: String?, _ text: String) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.primary.opacity(0.85))
        .padding(.horizontal, 5).frame(height: 18)
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(HomeStyle.primary.opacity(0.4), lineWidth: 1))
    }
    private func badges(_ detail: JellyfinClient.Detail) -> [JellyBadge] {
        var out: [JellyBadge] = []
        if let rating = detail.OfficialRating, !rating.isEmpty { out.append(JellyBadge(symbol: nil, text: rating)) }
        guard !series, let source = chosenSource(detail) else { return out }
        let streams = source.MediaStreams ?? []
        if let video = streams.first(where: { $0.kind == "Video" }) {
            if let size = JellyFileInfo.resolution(video) { out.append(JellyBadge(symbol: nil, text: size)) }
            if let range = video.VideoRangeType, !range.isEmpty, range != "SDR" { out.append(JellyBadge(symbol: nil, text: JellyFileInfo.rangeName(range))) }
        }
        if let audio = streams.first(where: { $0.kind == "Audio" && $0.IsDefault == true }) ?? streams.first(where: { $0.kind == "Audio" }) {
            if let layout = JellyFileInfo.channels(audio) { out.append(JellyBadge(symbol: nil, text: layout)) }
        }
        if streams.contains(where: { $0.kind == "Subtitle" }) { out.append(JellyBadge(symbol: "captions.bubble", text: "CC")) }
        // The same text twice (an age rating that reads like a codec) would clash as an id.
        var seen = Set<String>()
        return out.filter { seen.insert($0.text).inserted }
    }
    private func chosenSource(_ detail: JellyfinClient.Detail) -> JellyfinClient.Detail.Source? {
        detail.MediaSources?.first { $0.Id == version } ?? detail.MediaSources?.first
    }
    /// "52m", "1h 52m".
    private static func runtime(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m")
    }

    // MARK: Trailer, the ••• menu, versions, Play

    /// The trailer: a trailer file on the server plays here; else the online one opens.
    private func trailer(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> (() -> Void)? {
        if let file = extras.first(where: { $0.kind == "Trailer" }) {
            return { playing = JellySpace.playback(file, client: client) }
        }
        if let url = detail.RemoteTrailers?.compactMap({ $0.Url.flatMap(URL.init(string:)) }).first {
            return { openURL(url) }
        }
        return nil
    }
    /// Whether ••• has anything in it (a show without an online trailer has nothing).
    private func hasMore(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> Bool {
        detail.RemoteTrailers?.contains { $0.Url.flatMap(URL.init(string:)) != nil } == true
            || (!series && (client.streamURL(route.id, source: version) != nil || chosenSource(detail) != nil))
    }
    /// The top bar's •••: File info, the trailer online, and handing the film to another player.
    @ViewBuilder private func moreMenu(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        let online = detail.RemoteTrailers?.compactMap { $0.Url.flatMap(URL.init(string:)) }.first
        let stream = series ? nil : client.streamURL(route.id, source: version)
        let info = !series && chosenSource(detail) != nil
        if online != nil || stream != nil || info {
            Menu {
                if info { Button("File info", systemImage: "info.circle") { showFileInfo = true } }
                if let online { Button("Watch trailer online", systemImage: "play.rectangle") { openURL(online) } }
                if let stream {
                    Divider()
                    ForEach(JellySpace.otherPlayers, id: \.self) { app in
                        Button("Open in " + app, systemImage: "arrow.up.forward.app") { JellySpace.open(stream, in: app) }
                    }
                }
            } label: { TitleMoreButtonLabel() }
            .accessibilityLabel("More options for " + name).accessibilityIdentifier("jellyspace-detail-more")
        }
    }
    /// "Version: 4K" when a film is stored in more than one quality.
    private func versionMenu(_ sources: [JellyfinClient.Detail.Source]) -> some View {
        let chosen = sources.first { $0.Id == version } ?? sources[0]
        return Menu {
            Picker("Version", selection: Binding(get: { chosen.Id ?? "" }, set: { version = $0 })) {
                ForEach(sources.indices, id: \.self) { index in Text(sources[index].Name ?? "Version \(index + 1)").tag(sources[index].Id ?? "") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack")
                Text("Version: " + (chosen.Name ?? "")).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            .padding(.horizontal, 12).frame(height: 32).background(Color.primary.opacity(0.09), in: Capsule())
        }.accessibilityIdentifier("jellyspace-version")
    }
    /// "Play", "Resume · 23m left", or a show's "Play S1 E4".
    private func playLabel(_ detail: JellyfinClient.Detail) -> String {
        if series {
            guard let next = nextEpisode ?? firstEpisode else { return "Play" }
            let place = [next.ParentIndexNumber.map { "S\($0)" }, next.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
            return (next.UserData?.PlayedPercentage ?? 0) > 0 ? "Resume \(place)" : "Play \(place)"
        }
        let total = detail.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        if let at = detail.UserData?.PlaybackPositionTicks.map({ Double($0) / 10_000_000 }), at > 30, total > at {
            return "Resume · \(Self.runtime(max(1, Int((total - at) / 60)))) left"
        }
        return "Play"
    }
    private func play(_ client: JellyfinClient) {
        if series {
            if let next = nextEpisode ?? firstEpisode ?? episodes.first { playing = JellySpace.playback(next, client: client) }
        } else if let item {
            playing = JellySpace.playback(item, client: client, source: version)
        }
    }

    // MARK: The tabs: Episodes, More like this, Extras

    private var tabs: [Tab] {
        (series ? [.episodes] : []) + (similar.isEmpty ? [] : [.similar]) + (extras.isEmpty ? [] : [.extras])
    }
    @ViewBuilder private func tabsSection(_ client: JellyfinClient) -> some View {
        let available = tabs
        if let current = tab.flatMap({ available.contains($0) ? $0 : nil }) ?? available.first {
            VStack(alignment: .leading, spacing: 16) {
                // The names, the chosen one under a red bar on the line across the page.
                HStack(alignment: .top, spacing: 22) {
                    ForEach(available, id: \.self) { item in
                        Button { withAnimation(.snappy(duration: 0.25)) { tab = item } } label: {
                            Text(item.rawValue).font(.system(size: 16, weight: .bold))
                                .foregroundStyle(item == current ? HomeStyle.primary : HomeStyle.secondary)
                                .fixedSize().padding(.top, 12)
                                .overlay(alignment: .top) {
                                    if item == current {
                                        Rectangle().fill(Color(red: 0.86, green: 0.1, blue: 0.12)).frame(height: 4)
                                            .matchedGeometryEffect(id: "bar", in: tabSpace)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item == current ? .isSelected : [])
                        .accessibilityIdentifier("jellyspace-detail-tab-" + String(describing: item))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) { Rectangle().fill(HomeStyle.primary.opacity(0.12)).frame(height: 1) }
                switch current {
                case .episodes: episodesTab(client)
                case .similar: JellyGrid(items: similar, client: client, playing: $playing)
                case .extras:
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(extras, id: \.Id) { JellyWideCard(item: $0, client: client, playing: $playing, large: true) }
                    }
                }
            }
        }
    }
    /// Seasons in order, with the specials last.
    private var orderedSeasons: [JellyfinClient.Item] {
        seasons.sorted { lhs, rhs in
            let left = lhs.IndexNumber.map { $0 == 0 ? Int.max : $0 } ?? Int.max - 1
            let right = rhs.IndexNumber.map { $0 == 0 ? Int.max : $0 } ?? Int.max - 1
            return left < right
        }
    }
    /// The season (a menu when there are more), how many are left, then its episodes (the next one
    /// to watch on a card).
    private func episodesTab(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                let title = seasons.first { $0.Id == season }?.Name ?? "Season"
                if seasons.count > 1 {
                    Menu {
                        Picker("Season", selection: Binding(get: { season ?? "" }, set: { season = $0 })) {
                            ForEach(orderedSeasons, id: \.Id) { Text($0.Name ?? "Season").tag($0.Id) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(title).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                        }.font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    }.accessibilityLabel("Season: " + title).accessibilityIdentifier("jellyspace-season-menu")
                } else {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                }
                Spacer(minLength: 8)
                if !episodes.isEmpty {
                    let left = episodes.filter { $0.UserData?.Played != true }.count
                    Text(left == 0 ? "All watched" : left == episodes.count ? "\(episodes.count) episodes" : "\(episodes.count) · \(left) left")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(HomeStyle.secondary)
                }
            }
            LazyVStack(spacing: 2) {
                ForEach(episodes, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing, upNext: $0.Id == nextEpisode?.Id) }
            }
        }
    }

    // MARK: Cast and crew (Cast's "more")

    private func credits(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        let genres = detail.GenreItems ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(name).font(.system(size: 22, weight: .bold)).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                ForEach(creditGroups(detail)) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        creditsHeading(group.id)
                        ForEach(Array(group.people.enumerated()), id: \.offset) { _, person in
                            Button { open(JellyListRoute(kind: .person, id: person.Id, name: person.Name ?? "")) } label: { personRow(person, client: client) }
                                .buttonStyle(.springPress)
                        }
                    }
                }
                if !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        creditsHeading("Genres")
                        ForEach(genres, id: \.Id) { genre in
                            Button { open(JellyListRoute(kind: .genre, id: genre.Id, name: genre.Name ?? "Genre")) } label: {
                                HStack {
                                    Text(genre.Name ?? "Genre").font(.system(size: 15, weight: .medium)).foregroundStyle(HomeStyle.primary)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                                }.frame(minHeight: 40).contentShape(Rectangle())
                            }.buttonStyle(.springPress)
                        }
                    }
                }
                if let rating = detail.OfficialRating, !rating.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        creditsHeading("Age rating")
                        Text(rating).font(.system(size: 15, weight: .medium)).foregroundStyle(HomeStyle.primary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20).padding(.top, 8)
        }
        .diaryScreenBackground()
    }
    private func creditsHeading(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary).accessibilityAddTraits(.isHeader)
    }
    private func personRow(_ person: JellyfinClient.Detail.Person, client: JellyfinClient) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(HomeStyle.card)
                Image(systemName: "person.fill").font(.system(size: 18)).foregroundStyle(HomeStyle.secondary)
                JellyImage(url: person.PrimaryImageTag.flatMap { JellyfinClient.imageURL(base: client.base, item: person.Id, type: "Primary", tag: $0, width: 160) })
            }.frame(width: 44, height: 44).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(person.Name ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                if let role = person.Role, !role.isEmpty { Text(role).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
    /// Closes the sheet and opens a person's or genre's list on this tab.
    private func open(_ route: JellyListRoute) {
        showCredits = false
        router.paths[router.selectedTab, default: NavigationPath()].append(route)
    }

    // MARK: Loading

    private func load() async {
        guard let client = JellySpace.client else { return }
        failure = nil
        let user = await JellyfinUser.id(client)
        self.user = user
        do {
            let found = try await client.detail(route.id, user: user)
            detail = found
            played = found.UserData?.Played == true
            favourite = found.UserData?.IsFavorite == true
            if found.kind == "Series", let left = found.UserData?.UnplayedItemCount { JellyNewEpisodes.seen(route.id, unwatched: left) }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
            return
        }
        if series {
            seasons = (try? await client.seasons(of: route.id, user: user)) ?? []
            if let user { nextEpisode = try? await client.nextUp(series: route.id, user: user) }
            // Specials (season 0) come first in Jellyfin's list: the show starts at its first real season.
            let opening = seasons.first { ($0.IndexNumber ?? 0) >= 1 } ?? seasons.first
            if nextEpisode == nil, let opening {
                firstEpisode = (try? await client.episodes(of: route.id, season: opening.Id, user: user))?.first
            }
            if season == nil { season = nextEpisode?.SeasonId ?? opening?.Id }
        } else {
            item = try? await client.item(route.id)
        }
        similar = (try? await client.similar(route.id, user: user)) ?? []
        extras = await client.extras(route.id, user: user)
    }
    private func loadEpisodes() async {
        guard let client = JellySpace.client, let season else { return }
        episodes = (try? await client.episodes(of: route.id, season: season, user: user)) ?? []
    }
}

/// One outlined badge under a film's title ("1080p", "HEVC", "5.1").
struct JellyBadge {
    let symbol: String?
    let text: String
}

/// File info (from a film page's •••): the file, its picture, every audio track and every subtitle.
struct JellyFileInfo: View {
    let name: String
    let source: JellyfinClient.Detail.Source
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let streams = source.MediaStreams ?? []
        let video = streams.first { $0.kind == "Video" }
        let audio = streams.filter { $0.kind == "Audio" }
        let subtitles = streams.filter { $0.kind == "Subtitle" }
        NavigationStack {
            List {
                Section("File") {
                    if let file = source.Name, !file.isEmpty { row("Name", file) }
                    if let container = source.Container { row("Container", container.uppercased()) }
                    if let size = source.Size, size > 0 { row("Size", String(format: "%.2f GB", Double(size) / 1_073_741_824)) }
                    if let rate = source.Bitrate, rate > 0 { row("Bitrate", String(format: "%.2f Mbps", Double(rate) / 1_000_000)) }
                }
                if let video {
                    Section("Video") {
                        if let width = video.Width, let height = video.Height {
                            row("Resolution", "\(width)x\(height)" + (Self.resolution(video).map { " (\($0))" } ?? ""))
                        }
                        if let codec = video.Codec { row("Codec", Self.videoCodec(codec)) }
                        if let range = video.VideoRangeType, !range.isEmpty { row("Range", Self.rangeName(range)) }
                        if let fps = video.RealFrameRate, fps > 0 { row("Frame rate", fps.formatted(.number.precision(.fractionLength(0...3))) + " fps") }
                    }
                }
                if !audio.isEmpty {
                    Section("Audio") { ForEach(audio.indices, id: \.self) { trackRow(audio[$0], audio: true) } }
                }
                if !subtitles.isEmpty {
                    Section("Subtitles") { ForEach(subtitles.indices, id: \.self) { trackRow(subtitles[$0], audio: false) } }
                }
            }
            .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }
    /// "English · Dolby Digital 5.1 · Default".
    private func trackRow(_ stream: JellyfinClient.Detail.Stream, audio: Bool) -> some View {
        let language = stream.Language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        var parts = [language ?? stream.DisplayTitle ?? "Unknown"]
        if audio {
            let sound = [stream.Codec.map(Self.audioCodec), Self.channels(stream)].compactMap { $0 }.joined(separator: " ")
            if !sound.isEmpty { parts.append(sound) }
        } else if let codec = stream.Codec {
            parts.append(Self.subtitleFormat(codec))
        }
        if stream.IsDefault == true { parts.append("Default") }
        if stream.IsForced == true { parts.append("Forced") }
        return VStack(alignment: .leading, spacing: 2) {
            Text(parts.joined(separator: " · ")).font(.subheadline)
            if let title = stream.Title, !title.isEmpty, title != language { Text(title).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// "4K", "1080p", "720p", "SD".
    static func resolution(_ video: JellyfinClient.Detail.Stream) -> String? {
        let width = video.Width ?? 0, height = video.Height ?? 0
        guard width > 0 || height > 0 else { return nil }
        return width >= 3800 || height >= 2100 ? "4K" : width >= 1900 || height >= 1000 ? "1080p" : width >= 1260 || height >= 700 ? "720p" : "SD"
    }
    static func videoCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "mpeg2video": "MPEG-2"
        default: codec.uppercased()
        }
    }
    /// Jellyfin's range names as they're known: "Dolby Vision", "HDR10+", "HDR10", "HLG".
    static func rangeName(_ range: String) -> String {
        let lower = range.lowercased()
        if lower.hasPrefix("dovi") { return "Dolby Vision" }
        if lower == "hdr10plus" { return "HDR10+" }
        if lower == "hdr10" { return "HDR10" }
        if lower == "hlg" { return "HLG" }
        return range.uppercased()
    }
    static func audioCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "ac3": "Dolby Digital"
        case "eac3": "Dolby Digital+"
        case "truehd": "Dolby TrueHD"
        case "dts": "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        case "vorbis": "Vorbis"
        case let other where other.hasPrefix("pcm"): "PCM"
        default: codec.uppercased()
        }
    }
    /// "7.1", "5.1", "Stereo", "Mono".
    static func channels(_ stream: JellyfinClient.Detail.Stream) -> String? {
        let layout = (stream.ChannelLayout ?? "").lowercased()
        if layout.hasPrefix("7.1") { return "7.1" }
        if layout.hasPrefix("5.1") { return "5.1" }
        if layout == "stereo" { return "Stereo" }
        if layout == "mono" { return "Mono" }
        switch stream.Channels ?? 0 {
        case 8: return "7.1"
        case 6: return "5.1"
        case 2: return "Stereo"
        case 1: return "Mono"
        case let count where count > 0: return "\(count) ch"
        default: return nil
        }
    }
    static func subtitleFormat(_ codec: String) -> String {
        switch codec.lowercased() {
        case "ass", "ssa": "ASS"
        case "subrip", "srt": "SRT"
        case "webvtt", "vtt": "WebVTT"
        case "pgssub", "pgs": "PGS"
        case "dvdsub", "dvd_subtitle": "DVD"
        default: codec.uppercased()
        }
    }
}
