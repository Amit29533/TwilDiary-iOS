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

/// A film's or show's page, before playing: the backdrop with its logo, ratings, genres, Play (or
/// Resume, or a show's next episode), watched and favourite, the file's details, the overview, a
/// show's seasons and episodes, cast and crew, and similar titles.
struct JellyDetailPage: View {
    let route: JellyDetailRoute
    @State private var detail: JellyfinClient.Detail?
    @State private var item: JellyfinClient.Item?
    @State private var seasons: [JellyfinClient.Item] = []
    @State private var season: String?
    @State private var episodes: [JellyfinClient.Item] = []
    @State private var nextEpisode: JellyfinClient.Item?
    @State private var similar: [JellyfinClient.Item] = []
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    @State private var played = false
    @State private var favourite = false
    @State private var fullOverview = false
    @State private var user: String?

    private var series: Bool { detail?.kind == "Series" }

    var body: some View {
        EdgeToEdgeScroll(artworkUnderBar: true) {
            VStack(alignment: .leading, spacing: 18) {
                if let client = JellySpace.client {
                    header(client)
                    if let detail {
                        VStack(alignment: .leading, spacing: 18) {
                            facts(detail)
                            actions(detail, client: client)
                            if !series, let source = detail.MediaSources?.first { videoInfo(source) }
                            if let overview = detail.Overview.map(JellySpace.plainText), !overview.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Overview").font(.system(size: 20, weight: .bold)).foregroundStyle(HomeStyle.primary)
                                    Text(overview).font(.system(size: 15)).foregroundStyle(HomeStyle.primary.opacity(0.85))
                                        .lineLimit(fullOverview ? nil : 4)
                                    Button(fullOverview ? "Show less" : "Show more") { withAnimation { fullOverview.toggle() } }
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(ThemeStore.accent)
                                }
                            }
                            if series { seasonsSection(client) }
                            if let people = detail.People?.prefix(20), !people.isEmpty { castRow(Array(people), client: client) }
                            if !similar.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Similar").font(.system(size: 20, weight: .bold)).foregroundStyle(HomeStyle.primary)
                                    ScrollView(.horizontal) {
                                        LazyHStack(alignment: .top, spacing: 12) {
                                            ForEach(similar, id: \.Id) { JellyTile(item: $0, client: client, playing: $playing).frame(width: 112) }
                                        }
                                    }.scrollIndicators(.hidden).scrollClipDisabled()
                                }
                            }
                        }.padding(.horizontal, 16)
                    } else if let failure {
                        RetryNotice(message: failure) { Task { await load() } }.padding(.horizontal, 16)
                    } else {
                        DiaryLoadingPlaceholder(height: 260, label: "Loading").padding(.horizontal, 16)
                    }
                }
            }.padding(.bottom, 48)
        }
        .diaryScreenBackground()
        .task { await load() }
        .task(id: season) { await loadEpisodes() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    // MARK: Header and facts

    private func header(_ client: JellyfinClient) -> some View {
        let backdrop = detail?.BackdropImageTags?.first.flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Backdrop", tag: $0, width: 1200) }
        let logo = detail?.ImageTags?["Logo"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Logo", tag: $0, width: 800) }
        // The picture fills a fixed box laid out at the screen's width; it never sizes the page (a
        // filled picture in a plain stack made the whole page wider than the screen).
        return Color.clear.frame(maxWidth: .infinity).frame(height: 330)
            .overlay { JellyImage(url: backdrop ?? detail?.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: route.id, type: "Primary", tag: $0, width: 900) }) }
            .overlay { LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom) }
            .overlay(alignment: .bottomLeading) {
                if let logo { JellyImage(url: logo, mode: .fit).frame(maxWidth: 260, maxHeight: 100, alignment: .bottomLeading).padding(16) }
            }
            .background(HomeStyle.card).clipped()
    }

    private func facts(_ detail: JellyfinClient.Detail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let rating = detail.OfficialRating, !rating.isEmpty { chip(Text(rating)) }
                if let score = detail.CommunityRating, score > 0 {
                    chip(Text("\(Image(systemName: "star.fill")) \(String(format: "%.1f", score))"), tint: Color(themed: "#e7ca90"))
                }
                if let critic = detail.CriticRating, critic > 0 { chip(Text("Critics \(Int(critic))%")) }
            }
            Text(detail.Name ?? route.name).font(.system(size: 24, weight: .bold)).tracking(-0.3).foregroundStyle(HomeStyle.primary)
            Text(yearLine(detail)).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
            if let genres = detail.GenreItems, !genres.isEmpty {
                InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(genres, id: \.Id) { genre in
                        NavigationLink(value: JellyListRoute(kind: .genre, id: genre.Id, name: genre.Name ?? "Genre")) { chip(Text(genre.Name ?? "")) }
                            .buttonStyle(.springPress)
                    }
                }
            } else if let genres = detail.Genres, !genres.isEmpty {
                InlineFlowLayout(spacing: 8, rowSpacing: 8) { ForEach(genres, id: \.self) { chip(Text($0)) } }
            }
        }
    }
    private func yearLine(_ detail: JellyfinClient.Detail) -> String {
        var parts: [String] = []
        if let year = detail.ProductionYear {
            let end = detail.EndDate.flatMap { Int($0.prefix(4)) }
            parts.append(series && end != nil && end != year ? "\(year)–\(end!)" : String(year))
        }
        if let minutes = detail.RunTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0, !series { parts.append(Self.runtime(minutes)) }
        if series, let left = detail.UserData?.UnplayedItemCount, left > 0 { parts.append("\(left) unwatched") }
        return parts.joined(separator: " · ")
    }
    /// "52m", "1h 52m".
    private static func runtime(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m")
    }
    private func chip(_ text: Text, tint: Color = HomeStyle.primary) -> some View {
        text.font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 10).frame(height: 28).background(Color.primary.opacity(0.09), in: Capsule())
    }

    // MARK: Play, watched and favourite

    private func actions(_ detail: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        HStack(spacing: 10) {
            Button { play(client) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(playLabel(detail)).lineLimit(1)
                }.font(.system(size: 16, weight: .bold)).foregroundStyle(WatchStyle.ink)
                    .frame(maxWidth: .infinity).frame(height: 48).background(WatchStyle.fill, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-detail-play")
            roundToggle(played ? "checkmark.circle.fill" : "checkmark.circle", label: played ? "Mark unwatched" : "Mark watched") {
                guard let user else { return }
                played.toggle()
                let now = played
                Task { try? await client.setPlayed(route.id, user: user, now) }
            }
            roundToggle(favourite ? "heart.fill" : "heart", label: favourite ? "Remove from favourites" : "Add to favourites") {
                guard let user else { return }
                favourite.toggle()
                let now = favourite
                Task { try? await client.setFavourite(route.id, user: user, now) }
            }
        }
    }
    private func roundToggle(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                .frame(width: 48, height: 48).background(Color.primary.opacity(0.09), in: Circle()).contentShape(Circle())
        }.buttonStyle(.springPress).accessibilityLabel(label)
    }
    /// "Play 1h 52m", "Resume · 23m left", or a show's "Play S1 E4".
    private func playLabel(_ detail: JellyfinClient.Detail) -> String {
        if series {
            guard let next = nextEpisode else { return "Play" }
            let place = [next.ParentIndexNumber.map { "S\($0)" }, next.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
            return (next.UserData?.PlayedPercentage ?? 0) > 0 ? "Resume \(place)" : "Play \(place)"
        }
        let total = detail.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        if let at = detail.UserData?.PlaybackPositionTicks.map({ Double($0) / 10_000_000 }), at > 30, total > at {
            return "Resume · \(Self.runtime(max(1, Int((total - at) / 60)))) left"
        }
        return total > 0 ? "Play \(Self.runtime(Int(total / 60)))" : "Play"
    }
    private func play(_ client: JellyfinClient) {
        if series {
            if let next = nextEpisode ?? episodes.first { playing = JellySpace.playback(next, client: client) }
        } else if let item {
            playing = JellySpace.playback(item, client: client)
        }
    }

    // MARK: File details, seasons, people

    /// "2.13 GB · 1920x960 · SDR · H264 · 2.44 Mbps · 24 fps", as chips.
    private func videoInfo(_ source: JellyfinClient.Detail.Source) -> some View {
        let video = source.MediaStreams?.first { $0.kind == "Video" }
        let audio = source.MediaStreams?.filter { $0.kind == "Audio" } ?? []
        var chips: [(String, String)] = []
        if let size = source.Size, size > 0 { chips.append(("internaldrive", String(format: "%.2f GB", Double(size) / 1_073_741_824))) }
        if let width = video?.Width, let height = video?.Height { chips.append(("rectangle", "\(width)x\(height)")) }
        if let range = video?.VideoRangeType, !range.isEmpty { chips.append(("sun.max", range == "SDR" ? "SDR" : range)) }
        if let codec = video?.Codec { chips.append(("chevron.left.forwardslash.chevron.right", codec.uppercased())) }
        if let rate = source.Bitrate, rate > 0 { chips.append(("speedometer", String(format: "%.2f Mbps", Double(rate) / 1_000_000))) }
        if let fps = video?.RealFrameRate, fps > 0 { chips.append(("film", String(format: fps == fps.rounded() ? "%.0f fps" : "%.2f fps", fps))) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Video").font(.system(size: 20, weight: .bold)).foregroundStyle(HomeStyle.primary)
            InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(chips, id: \.1) { chip in
                    chip_(Text("\(Image(systemName: chip.0)) \(chip.1)"))
                }
            }
            if !audio.isEmpty {
                Text("Audio: " + audio.compactMap { $0.DisplayTitle ?? $0.Language }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
            }
        }
    }
    private func chip_(_ text: Text) -> some View { chip(text) }

    private func seasonsSection(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.Id) { entry in
                            let chosen = season == entry.Id
                            Button { season = entry.Id } label: {
                                Text(entry.Name ?? "Season").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(chosen ? ThemeStore.current.accentInk : HomeStyle.primary)
                                    .padding(.horizontal, 14).frame(height: 36)
                                    .background(chosen ? AnyShapeStyle(ThemeStore.accent) : AnyShapeStyle(Color.primary.opacity(0.09)), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)
            } else if let only = seasons.first {
                Text(only.Name ?? "Episodes").font(.system(size: 20, weight: .bold)).foregroundStyle(HomeStyle.primary)
            }
            LazyVStack(spacing: 8) {
                ForEach(episodes, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing) }
            }
        }
    }

    private func castRow(_ people: [JellyfinClient.Detail.Person], client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast & crew").font(.system(size: 20, weight: .bold)).foregroundStyle(HomeStyle.primary)
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
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
            return
        }
        if series {
            seasons = (try? await client.seasons(of: route.id, user: user)) ?? []
            if let user { nextEpisode = try? await client.nextUp(series: route.id, user: user) }
            if season == nil { season = nextEpisode?.SeasonId ?? seasons.first?.Id }
        } else {
            item = try? await client.item(route.id)
        }
        similar = (try? await client.similar(route.id, user: user)) ?? []
    }
    private func loadEpisodes() async {
        guard let client = JellySpace.client, let season else { return }
        episodes = (try? await client.episodes(of: route.id, season: season, user: user)) ?? []
    }
}
