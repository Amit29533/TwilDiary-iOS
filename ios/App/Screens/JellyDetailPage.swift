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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let progress = state.progress
        HStack(spacing: 8) {
            JellyImage(url: poster).frame(width: 28, height: 28).background(HomeStyle.card)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
        }
        .frame(height: 28)
        .opacity(Double(progress))
        .offset(y: reduceMotion ? 0 : (1 - progress) * 6)
        .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityAddTraits(.isHeader)
        .accessibilityHidden(progress < 0.5)
    }
}

/// A film's or show's page, before playing: the backdrop fading into the page with the logo on it;
/// centred under it the years, genres, ratings and the file's badges; Play (or Resume, or a show's
/// next episode) with Watched, Favourite, Trailer and File info; then the overview, a show's
/// episodes, extras, cast and crew, and similar titles. File info and other players are in •••.
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
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    /// Trailer files and special features.
    @State private var extras: [JellyfinClient.Item] = []
    /// The version of a film to play (when it's stored in more than one quality).
    @State private var version: String?
    @Environment(\.openURL) private var openURL
    @Environment(AppRouter.self) private var router
    @State private var showFileInfo = false
    /// The poster and name in the top bar once the picture has scrolled under it.
    @State private var headerState = CompactHeaderState()

    private var series: Bool { detail?.kind == "Series" }
    private var name: String { detail?.Name ?? route.name }

    var body: some View {
        EdgeToEdgeScroll(artworkUnderBar: true) {
            VStack(spacing: 0) {
                if let client = JellySpace.client {
                    header(client)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                            headerState.update(ScrollLinkedBarTitle.progress(headingBottom: bottom))
                        }
                    if let detail {
                        summary(detail, client: client).padding(.horizontal, 20)
                        VStack(alignment: .leading, spacing: 28) {
                            if let overview = detail.Overview.map(JellySpace.plainText), !overview.isEmpty { overviewSection(overview) }
                            if series { seasonsSection(client) }
                            if !extras.isEmpty { extrasRow(client) }
                            if let people = detail.People?.prefix(20), !people.isEmpty { castRow(Array(people), client: client) }
                            if !similar.isEmpty { similarRow(client) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 26)
                    } else if let failure {
                        RetryNotice(message: failure) { Task { await load() } }.padding(.horizontal, 16)
                    } else {
                        DiaryLoadingPlaceholder(height: 260, label: "Loading").padding(.horizontal, 16)
                    }
                }
            }.padding(.bottom, 48)
        }
        .diaryScreenBackground()
        .toolbar {
            ToolbarItem(placement: .principal) {
                JellyCompactTitle(name: name, poster: JellySpace.client.flatMap { client in
                    detail?.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Primary", tag: $0, width: 200) }
                }, state: headerState)
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
        .task { await load() }
        .task(id: season) { await loadEpisodes() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load(); await loadEpisodes() } }) { JellyPlayerView(playback: $0) }
    }

    // MARK: The picture and the title

    /// The backdrop, fading into the page (whatever the theme's background is) instead of ending at
    /// an edge, with the logo (or, without one, the name) on the fade.
    private func header(_ client: JellyfinClient) -> some View {
        let backdrop = detail?.BackdropImageTags?.first.flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Backdrop", tag: $0, width: 1200) }
        let primary = detail?.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Primary", tag: $0, width: 900) }
        let logo = detail?.ImageTags?["Logo"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Logo", tag: $0, width: 800) }
        // The picture fills a fixed box laid out at the screen's width; it never sizes the page (a
        // filled picture in a plain stack made the whole page wider than the screen).
        return Color.clear.frame(maxWidth: .infinity).frame(height: 380)
            .overlay { JellyImage(url: backdrop ?? primary) }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                       .init(color: .black.opacity(0.6), location: 0.72), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) { titleMark(logo).padding(.horizontal, 28).padding(.bottom, 6) }
    }
    @ViewBuilder private func titleMark(_ logo: URL?) -> some View {
        if let logo {
            JellyImage(url: logo, mode: .fit).frame(maxWidth: 280, maxHeight: 110)
                .shadow(color: .black.opacity(0.45), radius: 10)
                .accessibilityElement().accessibilityLabel(name).accessibilityAddTraits(.isHeader)
        } else {
            // Long names: up to three lines, a little smaller before they end in "…" (the whole name
            // is in the top bar once scrolled, and in File info).
            Text(name).font(.system(size: 28, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary)
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.75)
                .shadow(color: .black.opacity(0.3), radius: 8).accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: The details under the title

    /// Centred: the years and length, the genres, the ratings, the file's badges, then Play.
    private func summary(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                let line = yearLine(detail)
                if !line.isEmpty { Text(line).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                genreLine(detail)
            }
            ratingsRow(detail)
            badgesRow(detail)
            if !series, let sources = detail.MediaSources, sources.count > 1 { versionMenu(sources) }
            actions(detail, client: client).padding(.top, 4)
        }.frame(maxWidth: .infinity)
    }
    /// "2023 · 1h 14m"; a show's "2021–2024 · 3 seasons · 12 unwatched".
    private func yearLine(_ detail: JellyfinClient.Detail) -> String {
        var parts: [String] = []
        if let year = detail.ProductionYear {
            let end = detail.EndDate.flatMap { Int($0.prefix(4)) }
            parts.append(series && end != nil && end != year ? "\(year)–\(end!)" : String(year))
        }
        if series {
            let count = seasons.filter { ($0.IndexNumber ?? 0) >= 1 }.count
            if count > 0 { parts.append(count == 1 ? "1 season" : "\(count) seasons") }
            if let left = detail.UserData?.UnplayedItemCount, left > 0 { parts.append("\(left) unwatched") }
        } else if let minutes = detail.RunTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 {
            parts.append(Self.runtime(minutes))
        }
        return parts.joined(separator: " · ")
    }
    /// The genres on one line: as many as fit, then "+3". A tap lists them all, each opening its list.
    @ViewBuilder private func genreLine(_ detail: JellyfinClient.Detail) -> some View {
        let items = detail.GenreItems ?? []
        let names = items.isEmpty ? (detail.Genres ?? []) : items.compactMap(\.Name)
        if !names.isEmpty {
            let line = ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: min(3, names.count), through: 1, by: -1)), id: \.self) { shown in
                    genreText(names, shown: shown)
                }
            }
            if items.isEmpty {
                line
            } else {
                Menu {
                    ForEach(items, id: \.Id) { genre in
                        Button(genre.Name ?? "Genre") {
                            router.paths[router.selectedTab, default: NavigationPath()].append(JellyListRoute(kind: .genre, id: genre.Id, name: genre.Name ?? "Genre"))
                        }
                    }
                } label: { line }
                .buttonStyle(.plain).accessibilityLabel("Genres: " + names.joined(separator: ", ")).accessibilityIdentifier("jellyspace-detail-genres")
            }
        }
    }
    private func genreText(_ names: [String], shown: Int) -> some View {
        let rest = names.count - shown
        let more = rest > 0 ? Text(" +\(rest)").foregroundStyle(HomeStyle.secondary) : Text("")
        return Text("\(names.prefix(shown).joined(separator: " · "))\(more)")
            .font(.system(size: 14, weight: .medium)).foregroundStyle(HomeStyle.primary.opacity(0.85)).lineLimit(1).fixedSize()
    }
    /// The score and the critics' score, each in a small container; the row is left out with neither.
    @ViewBuilder private func ratingsRow(_ detail: JellyfinClient.Detail) -> some View {
        let score = detail.CommunityRating.flatMap { $0 > 0 ? $0 : nil }
        let critics = detail.CriticRating.flatMap { $0 > 0 ? $0 : nil }
        if score != nil || critics != nil {
            HStack(spacing: 8) {
                if let score {
                    ratingPill {
                        Image(systemName: "star.fill").foregroundStyle(Color(themed: "#f5c451"))
                        Text(String(format: "%.1f", score))
                    }.accessibilityLabel("Rating \(String(format: "%.1f", score))")
                }
                if let critics {
                    ratingPill {
                        Circle().fill(Color(red: 0.98, green: 0.2, blue: 0.04)).frame(width: 11, height: 11)
                        Text("\(Int(critics))%")
                    }.accessibilityLabel("Rotten Tomatoes \(Int(critics)) percent")
                }
            }
        }
    }
    private func ratingPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            .padding(.horizontal, 11).frame(height: 28).background(Color.primary.opacity(0.09), in: Capsule())
            .accessibilityElement(children: .ignore)
    }
    /// Outlined badges, one line: the age rating, then (a film) the picture and sound. The least
    /// important ones drop off the end when they don't all fit.
    @ViewBuilder private func badgesRow(_ detail: JellyfinClient.Detail) -> some View {
        let all = badges(detail)
        if !all.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: all.count, through: 1, by: -1)), id: \.self) { count in
                    HStack(spacing: 6) { ForEach(all.prefix(count), id: \.text) { badge($0.symbol, $0.text) } }.fixedSize()
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(all.map(\.text).joined(separator: ", "))
        }
    }
    private func badge(_ symbol: String?, _ text: String) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.primary.opacity(0.85))
        .padding(.horizontal, 7).frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(HomeStyle.primary.opacity(0.3), lineWidth: 1))
    }
    private func badges(_ detail: JellyfinClient.Detail) -> [JellyBadge] {
        var out: [JellyBadge] = []
        if let rating = detail.OfficialRating, !rating.isEmpty { out.append(JellyBadge(symbol: nil, text: rating)) }
        guard !series, let source = chosenSource(detail) else { return out }
        let streams = source.MediaStreams ?? []
        if let video = streams.first(where: { $0.kind == "Video" }) {
            if let size = JellyFileInfo.resolution(video) { out.append(JellyBadge(symbol: nil, text: size)) }
            if let range = video.VideoRangeType, !range.isEmpty, range != "SDR" { out.append(JellyBadge(symbol: nil, text: JellyFileInfo.rangeName(range))) }
            if let codec = video.Codec { out.append(JellyBadge(symbol: nil, text: JellyFileInfo.videoCodec(codec))) }
        }
        if let audio = streams.first(where: { $0.kind == "Audio" && $0.IsDefault == true }) ?? streams.first(where: { $0.kind == "Audio" }) {
            if let layout = JellyFileInfo.channels(audio) { out.append(JellyBadge(symbol: "speaker.wave.2.fill", text: layout)) }
            if let codec = audio.Codec { out.append(JellyBadge(symbol: nil, text: JellyFileInfo.audioCodec(codec))) }
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

    // MARK: Play, watched, favourite, trailer, file info

    private func actions(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        VStack(spacing: 16) {
            Button { play(client) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(playLabel(detail)).lineLimit(1)
                }.font(.system(size: 16, weight: .bold)).foregroundStyle(WatchStyle.ink)
                    .frame(maxWidth: .infinity).frame(height: 50).background(WatchStyle.fill, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-detail-play")
            HStack(alignment: .top, spacing: 10) {
                labelled(played ? "checkmark.circle.fill" : "checkmark.circle", title: "Watched", label: played ? "Mark unwatched" : "Mark watched") {
                    guard let user else { return }
                    played.toggle()
                    let now = played
                    Task { try? await client.setPlayed(route.id, user: user, now) }
                }
                labelled(favourite ? "heart.fill" : "heart", title: "Favourite", label: favourite ? "Remove from favourites" : "Add to favourites") {
                    guard let user else { return }
                    favourite.toggle()
                    let now = favourite
                    Task { try? await client.setFavourite(route.id, user: user, now) }
                }
                if let trailer = trailer(detail, client: client) {
                    labelled("film", title: "Trailer", label: "Play trailer", action: trailer)
                }
                if !series, chosenSource(detail) != nil {
                    labelled("waveform", title: audioLanguages(detail) ?? "File info", label: "File info") { showFileInfo = true }
                        .accessibilityIdentifier("jellyspace-detail-file-info")
                }
            }
        }
    }
    /// A round button with its name under it.
    private func labelled(_ symbol: String, title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    .frame(width: 48, height: 48).background(Color.primary.opacity(0.09), in: Circle())
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            }.frame(minWidth: 0, maxWidth: 74).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityLabel(label)
    }
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
    /// "English, Japanese": the film's audio languages.
    private func audioLanguages(_ detail: JellyfinClient.Detail) -> String? {
        var seen: [String] = []
        for stream in chosenSource(detail)?.MediaStreams ?? [] where stream.kind == "Audio" {
            guard let code = stream.Language, let language = Locale.current.localizedString(forLanguageCode: code), !seen.contains(language) else { continue }
            seen.append(language)
        }
        return seen.isEmpty ? nil : seen.joined(separator: ", ")
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
    /// "Play", "Resume · 23m left", or a show's "Play S1 E4" (the length is on the line above).
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

    // MARK: Sections

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold)).tracking(-0.2).foregroundStyle(HomeStyle.primary)
            .accessibilityAddTraits(.isHeader)
    }
    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Overview")
            Text(overview).font(.system(size: 15)).foregroundStyle(HomeStyle.primary.opacity(0.85))
                .lineLimit(fullOverview ? nil : 4)
            Button(fullOverview ? "Show less" : "Show more") { withAnimation { fullOverview.toggle() } }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ThemeStore.accent)
        }
    }
    /// Trailers and special features, as wide cards that play.
    private func extrasRow(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Extras")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(extras, id: \.Id) { JellyWideCard(item: $0, client: client, playing: $playing).frame(width: 220) }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
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
    /// Episodes: the season in a menu, how many and how many are left, then the season's episodes
    /// (the next one to watch on a card).
    private func seasonsSection(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                sectionTitle("Episodes")
                Spacer(minLength: 8)
                if seasons.count > 1 {
                    Menu {
                        Picker("Season", selection: Binding(get: { season ?? "" }, set: { season = $0 })) {
                            ForEach(orderedSeasons, id: \.Id) { Text($0.Name ?? "Season").tag($0.Id) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(seasons.first { $0.Id == season }?.Name ?? "Season").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        .padding(.horizontal, 13).frame(height: 32).background(Color.primary.opacity(0.09), in: Capsule())
                    }.accessibilityLabel("Season").accessibilityIdentifier("jellyspace-season-menu")
                } else if let only = seasons.first?.Name {
                    Text(only).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                }
            }
            if !episodes.isEmpty {
                let left = episodes.filter { $0.UserData?.Played != true }.count
                HStack(spacing: 6) {
                    countPill(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes")
                    if left == 0 { countPill("All watched") } else if left < episodes.count { countPill("\(left) left") }
                }
            }
            LazyVStack(spacing: 2) {
                ForEach(episodes, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing, upNext: $0.Id == nextEpisode?.Id) }
            }
        }
    }
    private func countPill(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(HomeStyle.secondary)
            .padding(.horizontal, 10).frame(height: 26).background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func castRow(_ people: [JellyfinClient.Detail.Person], client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Cast & crew")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(people, id: \.Id) { person in
                      NavigationLink(value: JellyListRoute(kind: .person, id: person.Id, name: person.Name ?? "")) {
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                Rectangle().fill(HomeStyle.card)
                                Image(systemName: "person.fill").font(.system(size: 30)).foregroundStyle(HomeStyle.secondary)
                                JellyImage(url: person.PrimaryImageTag.flatMap { JellyfinClient.imageURL(base: client.base, item: person.Id, type: "Primary", tag: $0, width: 300) })
                            }.frame(width: 104, height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(person.Name ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            Text(person.Role ?? person.kind ?? "").font(.system(size: 11)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }.frame(width: 104, alignment: .leading).contentShape(Rectangle())
                      }.buttonStyle(.springPress)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
    /// Similar titles, their names on two lines (one line said little at this width).
    private func similarRow(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Similar")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(similar, id: \.Id) {
                        JellyTile(item: $0, client: client, playing: $playing, titleLines: 2)
                            .containerRelativeFrame(.horizontal, count: posterSize.columns, spacing: 12)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
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
