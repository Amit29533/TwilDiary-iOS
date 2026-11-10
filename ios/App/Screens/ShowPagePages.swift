import SwiftUI
import TwilDiaryCore

// MARK: Episode rows and cards

enum EpisodeRowState: Equatable {
    case watched(Date?), next, notWatched, notAired
    /// "Watched today", "Watched yesterday", "Watched 3 Nov".
    var text: String {
        switch self {
        case .watched(let date):
            guard let date else { return "Watched" }
            let calendar = DiaryDate.calendar()
            if calendar.isDateInToday(date) { return "Watched today" }
            if calendar.isDateInYesterday(date) { return "Watched yesterday" }
            return "Watched " + date.formatted(.dateTime.day().month(.abbreviated))
        case .next: return "Up next"
        case .notWatched: return "Not watched"
        case .notAired: return "Not aired yet"
        }
    }
}

/// The newest watch of each episode of a title, for "Watched today".
@MainActor enum EpisodeWatchDates {
    static func latest(_ store: DiaryStore, titleID: String) -> [String: Date] {
        var result: [String: Date] = [:]
        for event in store.titleScope(titleID).activeEvents where event.titleId == titleID {
            guard let id = event.episodeId, let date = DiaryDate.parse(event.watchedAt ?? event.recordedAt) else { continue }
            if result[id].map({ date > $0 }) ?? true { result[id] = date }
        }
        return result
    }
}

/// A small grey or accent label inside episode rows.
struct EpisodeChip: View {
    let text: String
    var accent = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .foregroundStyle(accent ? HomeStyle.chipText : text.hasPrefix("Watched") ? HomeStyle.dateChipText : HomeStyle.secondary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(accent ? HomeStyle.chip : Color(webHex: "#1e1e26"), in: RoundedRectangle(cornerRadius: 11))
    }
}
struct ScoreChip: View {
    let score: Double
    var body: some View {
        HStack(spacing: 3) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(webHex: "#ffc83d")); Text(score.formatted(.number.precision(.fractionLength(1)))) }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            .padding(.horizontal, 9).frame(height: 22).background(Color(webHex: "#1e1e26"), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .ignore).accessibilityLabel("Rated " + score.formatted(.number.precision(.fractionLength(1))))
    }
}

/// The watched tick: filled when watched, a ring (accent for what's next) when not.
struct EpisodeTick: View {
    let watched: Bool
    var next = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        ZStack {
            if watched { Circle().fill(theme.accent) } else { Circle().strokeBorder(next ? theme.accent : Color(webHex: "#3a3a46"), lineWidth: 2) }
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(watched ? Color(webHex: "#0b0b10") : next ? theme.accent : Color(webHex: "#3a3a46"))
        }.frame(width: 32, height: 32).frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

/// One episode as a card row: still, "12. Name", its state and score, and the tick.
struct EpisodeCardRow: View {
    let number: Int
    let name: String
    let artwork: String?
    let hidden: Bool
    let state: EpisodeRowState
    let score: Double?
    let canToggle: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    /// False on a preview page: the title isn't in your diary, so there is nothing to tick.
    var showsTick = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private var watched: Bool { if case .watched = state { return true } else { return false } }
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Group {
                        if hidden { Color(webHex: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 20).foregroundStyle(.secondary) } }
                        else { Artwork(path: artwork, title: String(number)) }
                    }.frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name.hasPrefix("Episode ") || hidden ? name : "\(number). \(name)")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            EpisodeChip(text: state.text, accent: state == .next)
                            if let score, score > 0 { ScoreChip(score: score) }
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Episode \(number) details").accessibilityValue(name)
                .accessibilityIdentifier("title-episode-\(number)")
            if showsTick {
            Button(action: onToggle) { EpisodeTick(watched: watched, next: state == .next) }.buttonStyle(.plain)
                .disabled(!canToggle).accessibilityLabel("Mark episode \(number) \(watched ? "unwatched" : "watched")")
                .accessibilityIdentifier("episode-watch-\(number)")
            }
        }.padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 8)
            .background(state == .next ? Color(webHex: "#17142a") : HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(state == .next ? Color(webHex: "#34294f") : HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
}

/// One episode as a wide card for the sideways grid: still with its badge, name, state, length, score.
struct EpisodeGridCard: View {
    let number: Int
    let name: String
    let artwork: String?
    let hidden: Bool
    let state: EpisodeRowState
    let airedOn: String?
    let runtime: Int?
    let score: Double?
    let onOpen: () -> Void
    let onToggle: () -> Void
    /// False on a preview page: the title isn't in your diary, so there is nothing to tick.
    var showsTick = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private var watched: Bool { if case .watched = state { return true } else { return false } }
    var body: some View {
        // Design (board 2): a 232 x 130 still in a #17171d card (radius 22, #26262e hairline), a 24 pt
        // badge 10 pt in, the 34 pt tick 11 pt from the corner; then 16 pt name, 13 pt state, 24 pt chips.
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                Group {
                    if hidden { Color(webHex: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 24).foregroundStyle(HomeStyle.secondary) } }
                    else { Artwork(path: artwork, title: String(number)) }
                }.frame(width: 230, height: 128).clipShape(RoundedRectangle(cornerRadius: 21))
                    .padding(1).background(HomeStyle.round, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    .overlay(alignment: .topLeading) {
                        Text(state == .next ? "UP NEXT" : "E\(number)").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(state == .next ? HomeStyle.chipText : HomeStyle.primary)
                            .padding(.horizontal, 10).frame(height: 24).background(HomeStyle.card.opacity(0.8), in: Capsule()).padding(10)
                    }
            }.buttonStyle(.plain).accessibilityLabel("Episode \(number) details").accessibilityIdentifier("episode-thumbnail-\(number)")
                .overlay(alignment: .bottomTrailing) {
                    if showsTick {
                    Button(action: onToggle) {
                        ZStack {
                            Circle().fill(watched ? AnyShapeStyle(theme.accent) : AnyShapeStyle(HomeStyle.card.opacity(0.8)))
                            Circle().strokeBorder(state == .next || watched ? theme.accent : Color(webHex: "#3a3a46"), lineWidth: 2)
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(watched ? Color(webHex: "#0b0b10") : state == .next ? theme.accent : HomeStyle.secondary)
                        }.frame(width: 34, height: 34).frame(width: 48, height: 48).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Mark episode \(number) \(watched ? "unwatched" : "watched")")
                        .accessibilityIdentifier("episode-watch-\(number)").padding(4)
                    }
                }
            Text(hidden ? name : "\(number) · \(name)").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, 11)
            // When it aired (or that you watched it), then its length and rating, on one line.
            HStack(spacing: 6) {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                if let runtime {
                    Text("\(runtime) min").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
                        .padding(.horizontal, 10).frame(height: 24).background(Color(webHex: "#1e1e26"), in: Capsule()).fixedSize()
                }
                if let score, score > 0 {
                    HStack(spacing: 3) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(webHex: "#ffc83d")); Text(score.formatted(.number.precision(.fractionLength(1)))) }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        .padding(.horizontal, 10).frame(height: 24).background(Color(webHex: "#1e1e26"), in: Capsule()).fixedSize()
                }
            }.padding(.top, 7)
        }.frame(width: 232, alignment: .leading)
    }
    private var subtitle: String {
        if case .watched = state { return state.text }
        guard let airedOn, let date = DiaryDate.parse(airedOn + "T12:00:00Z") else { return state.text }
        if date > .now { return date.formatted(.dateTime.day().month(.abbreviated).year()) }
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: Destinations

struct ShowPageDestination: View {
    let route: ShowPageRoute
    var body: some View {
        switch route {
        case .episodes(let id, let season): EpisodesPage(titleID: id, initialSeason: season)
        case .cast(let catalog, let title, let anime, let year): CastCreditsPage(route: catalog, title: title, anime: anime, year: year)
        case .lists(let catalog, let title): InListsPage(route: catalog, title: title)
        case .collections(let route, let title, let anime): RelatedCollectionsPage(route: route, title: title, anime: anime)
        case .tmdbCollection(let id, let name): TMDbCollectionPage(id: id, name: name)
        case .catalogEpisodes(let route, let season): PreviewEpisodesPage(route: route, initialSeason: season)
        case .related(let route, let title): RelatedTitlesPage(route: route, title: title)
        case .companies(let catalog, let title): CompaniesPage(route: catalog, title: title)
        }
    }
}

/// A page title with the show's name under it.
struct ShowPageTitle: ToolbarContent {
    let title: String
    let subtitle: String
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }.accessibilityElement(children: .combine)
        }
    }
}

/// Selectable filter chips: "All 24", "Watched 12"…
struct ShowFilterChip: View {
    let label: String
    let on: Bool
    let action: () -> Void
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? theme.ink : Color(webHex: "#e6e1ee"))
                .padding(.horizontal, 16).frame(height: 40)
                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white.opacity(0.07)), in: Capsule())
                .overlay { if !on { Capsule().strokeBorder(.white.opacity(0.1)) } }
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Episodes

struct EpisodesPage: View {
    let titleID: String
    @State private var season: Int
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("episodesPageGrid") private var grid = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Filter { case all, watched, toWatch }
    @State private var filter = Filter.all
    @State private var openGroups = Set<String>()
    @State private var details = SavedEpisodeDetailsController()
    @State private var revealed = Set<String>()
    @State private var selected: Episode?
    @State private var sheetEpisode: Episode?
    @State private var forward = true
    @State private var showNotes = false
    @State private var confirmSeason = false
    init(titleID: String, initialSeason: Int) { self.titleID = titleID; _season = State(initialValue: initialSeason) }

    var body: some View {
        Group {
            if let title = store.title(titleID) { content(title) }
            else { ContentUnavailableView("Title unavailable", systemImage: "film") }
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
    private func content(_ title: MediaTitle) -> some View {
        let episodes = store.episodesForSeason(titleID, season: season)
        let watched = store.watchedEpisodeIDs(titleID)
        let dates = EpisodeWatchDates.latest(store, titleID: titleID)
        let nextIndex = episodes.firstIndex { !watched.contains($0.id) && aired($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                seasonCard(title)
                HStack(spacing: 8) {
                    let count = episodes.filter { watched.contains($0.id) }.count
                    ShowFilterChip(label: "All \(episodes.count)", on: filter == .all) { filter = .all }
                    ShowFilterChip(label: "Watched \(count)", on: filter == .watched) { filter = .watched }
                    ShowFilterChip(label: "To watch \(episodes.count - count)", on: filter == .toWatch) { filter = .toWatch }
                }
                if episodes.isEmpty { Text("No episode metadata yet").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8) }
                else if filter == .all {
                    let window = EpisodeWindow(count: episodes.count, focus: nextIndex)
                    if !window.before.isEmpty { group("before", Array(episodes[window.before]), title: title, watched: watched, dates: dates, nextIndex: nextIndex) }
                    list(Array(episodes[window.shown]), title: title, watched: watched, dates: dates, next: nextIndex.map { episodes[$0].id })
                    if !window.after.isEmpty { group("after", Array(episodes[window.after]), title: title, watched: watched, dates: dates, nextIndex: nextIndex) }
                } else {
                    let shown = episodes.filter { filter == .watched ? watched.contains($0.id) : !watched.contains($0.id) }
                    if shown.isEmpty { Text(filter == .watched ? "Nothing watched in this season yet." : "Every episode in this season is watched.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8) }
                    list(shown, title: title, watched: watched, dates: dates, next: nextIndex.map { episodes[$0].id })
                }
                if !episodes.isEmpty {
                    Button { confirmSeason = true } label: {
                        Label("Mark season as watched", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }.buttonStyle(.diarySecondary).padding(.top, 6)
                        .disabled(store.writesBlocked || episodes.filter(aired).allSatisfy { watched.contains($0.id) })
                        .accessibilityIdentifier("episodes-mark-season")
                }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }
        .toolbar {
            ShowPageTitle(title: "Episodes", subtitle: title.name)
            ToolbarItem(placement: .topBarTrailing) {
                Button { grid.toggle() } label: { DiaryIcon(name: grid ? "list" : "layout-grid", size: 19) }
                    .accessibilityLabel("Show episodes as " + (grid ? "list" : "grid")).accessibilityIdentifier("episodes-page-layout")
            }
        }
        .task(id: season) { if !hideSpoilers { await details.load(season) { try await store.revealedSeason(title, number: season) } } }
        .confirmationDialog("Mark every aired episode of season \(season) as watched?", isPresented: $confirmSeason, titleVisibility: .visible) {
            Button("Mark season as watched") {
                let count = episodes.filter(aired).count
                Task { await store.setSeasonProgress(title, season: season, count: count, watchedAt: store.now) }
            }
        }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let episode = selected ?? sheetEpisode { sheet(title, episode: episode, episodes: episodes, watched: watched) }
        }
        .onChange(of: selected) { _, episode in if let episode { sheetEpisode = episode } }
        .sheet(isPresented: $showNotes) { TitleNotesSheet(titleID: titleID) }
    }

    private func seasonCard(_ title: MediaTitle) -> some View {
        let progress = store.seasonProgress(title, season: season)
        return SeasonProgressCard(season: $season, seasons: EpisodeSelection.seasons(in: store.titleScope(titleID), titleID: titleID),
                                  watched: progress.watched, total: progress.total, remainingMinutes: progress.remainingMinutes)
    }

    @ViewBuilder private func list(_ episodes: [Episode], title: MediaTitle, watched: Set<String>, dates: [String: Date], next: String?) -> some View {
        if grid {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                ForEach(episodes) { episode in
                    EpisodeGridCard(number: episode.number, name: name(episode, watched: watched), artwork: artwork(episode, title: title), hidden: hidden(episode, watched: watched),
                                    state: state(episode, watched: watched, dates: dates, next: next), airedOn: episode.airedOn, runtime: title.runtimeMinutes,
                                    score: score(episode), onOpen: { open(episode, title: title, watched: watched) }, onToggle: { toggle(episode, title: title, watched: watched) })
                }
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(episodes) { episode in
                    EpisodeCardRow(number: episode.number, name: name(episode, watched: watched), artwork: artwork(episode, title: title), hidden: hidden(episode, watched: watched),
                                   state: state(episode, watched: watched, dates: dates, next: next), score: score(episode),
                                   canToggle: !store.writesBlocked && (watched.contains(episode.id) || aired(episode)),
                                   onOpen: { open(episode, title: title, watched: watched) }, onToggle: { toggle(episode, title: title, watched: watched) })
                }
            }
        }
    }

    /// "Episodes 1 to 11 · All watched": folded until tapped.
    @ViewBuilder private func group(_ key: String, _ episodes: [Episode], title: MediaTitle, watched: Set<String>, dates: [String: Date], nextIndex: Int?) -> some View {
        let open = openGroups.contains(key)
        let left = episodes.filter { !watched.contains($0.id) }
        let allWatched = left.isEmpty
        let minutes = title.runtimeMinutes.map { $0 * left.count }
        VStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { if open { openGroups.remove(key) } else { openGroups.insert(key) } }
            } label: {
                HStack(spacing: 12) {
                    EpisodeTick(watched: allWatched)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Episodes \(episodes.first?.number ?? 0) to \(episodes.last?.number ?? 0)").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        Text(allWatched ? "All watched" : ([left.count.formatted() + " to watch"] + (minutes.map { [DiaryDate.duration($0)] } ?? [])).joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    DiaryIcon(name: "chevron-down", size: 15).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
                }.padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)))
            }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed").accessibilityIdentifier("episodes-group-" + key)
            if open { list(episodes, title: title, watched: watched, dates: dates, next: nextIndex.map { store.episodesForSeason(titleID, season: season)[$0].id }) }
        }
    }

    private func sheet(_ title: MediaTitle, episode: Episode, episodes: [Episode], watched: Set<String>) -> some View {
        let isWatched = watched.contains(episode.id)
        return EpisodeInfoSheet(title: title, season: season, episodes: episodes, episode: episode,
                                name: name(episode, watched: watched), summary: summary(episode), artwork: artwork(episode, title: title),
                                hidden: hidden(episode, watched: watched), tmdbScore: score(episode), traktScore: nil, watched: isWatched, forward: forward,
                                onToggleWatched: { toggle(episode, title: title, watched: watched) },
                                onNeighbour: { neighbour(of: episode, forward: $0, episodes: episodes, title: title) },
                                onNote: { selected = nil; showNotes = true }, onClose: { selected = nil })
            .presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private func aired(_ episode: Episode) -> Bool { episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day(store.now) } ?? false }
    private func hidden(_ episode: Episode, watched: Set<String>) -> Bool { hideSpoilers && !watched.contains(episode.id) && !revealed.contains(episode.id) }
    private func name(_ episode: Episode, watched: Set<String>) -> String {
        if hidden(episode, watched: watched) { return "A story for later" }
        let name = details.episodes[episode.id]?.name ?? episode.name
        return name.isEmpty ? "Episode \(episode.number)" : name
    }
    private func summary(_ episode: Episode) -> String { let text = details.episodes[episode.id]?.overview ?? episode.overview; return text.isEmpty ? "No episode summary available." : text }
    private func artwork(_ episode: Episode, title: MediaTitle) -> String? { details.episodes[episode.id]?.artwork ?? episode.still ?? title.backdrop }
    private func score(_ episode: Episode) -> Double? { details.episodes[episode.id]?.communityScore ?? episode.communityScore }
    private func state(_ episode: Episode, watched: Set<String>, dates: [String: Date], next: String?) -> EpisodeRowState {
        if watched.contains(episode.id) { return .watched(dates[episode.id]) }
        if episode.id == next { return .next }
        return aired(episode) ? .notWatched : .notAired
    }
    private func open(_ episode: Episode, title: MediaTitle, watched: Set<String>) {
        if hidden(episode, watched: watched) { revealed.insert(episode.id) }
        else { selected = episode }
        if details.episodes[episode.id] == nil { Task { await details.load(season) { try await store.revealedSeason(title, number: season) } } }
    }
    private func toggle(_ episode: Episode, title: MediaTitle, watched: Set<String>) {
        Task {
            if watched.contains(episode.id) { await store.unwatchEpisode(episode) }
            else { await store.recordViewing(title, episode: episode, watchedAt: store.now) }
        }
    }
    private func neighbour(of episode: Episode, forward: Bool, episodes: [Episode], title: MediaTitle) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), episodes.indices.contains(index + (forward ? 1 : -1)) else { return }
        let next = episodes[index + (forward ? 1 : -1)]
        revealed.insert(next.id)
        if details.episodes[next.id] == nil { Task { await details.load(season) { try await store.revealedSeason(title, number: season) } } }
        self.forward = forward
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { selected = next }
    }
}

// MARK: More like this

/// Every title TMDB recommends for this one, as the app's poster grid.
struct RelatedTitlesPage: View {
    let route: CatalogRoute
    let title: String
    @Environment(DiaryStore.self) private var store
    @State private var items: [CatalogItem]?
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let items {
                    if items.isEmpty { Text("TMDB has no recommendations for this title yet.").font(.subheadline).foregroundStyle(HomeStyle.secondary) }
                    else { CatalogGrid(items: items, showsLayoutToggle: false) }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else { DiaryLoadingPlaceholder(height: 320, label: "Loading titles") }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: "More like this", subtitle: title) }
            .task(id: route) { await load() }
    }
    private func load() async {
        failure = nil
        do { items = try await store.related(route).items } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

// MARK: A preview title's Episodes page

/// The diary models of a title that isn't in your diary, so the title page's own episode sheet can
/// show its episodes (the preview page and its Episodes page use these).
@MainActor enum PreviewDiaryModels {
    static func title(_ route: CatalogRoute, details: CatalogDetails) -> MediaTitle? {
        let object: [String: Any] = [
            "id": "preview-\(route.id)", "name": details.name, "category": details.suggestedCategory, "year": details.year as Any? ?? NSNull(),
            "overview": details.overview, "poster": CatalogTools.image(details.posterPath) as Any? ?? NSNull(),
            "backdrop": CatalogTools.image(details.backdropPath, size: "w780") as Any? ?? NSNull(), "communityScore": details.communityScore as Any? ?? NSNull(),
            "tmdbId": route.id, "genres": details.genres, "tags": [], "runtimeMinutes": details.runtimeMinutes as Any? ?? NSNull(),
            "status": "planned", "favorite": false, "queued": false, "score": NSNull(), "notes": "", "deletedAt": NSNull(), "version": 1, "seasons": []
        ]
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(MediaTitle.self, from: $0) }
    }
    static func episodes(_ items: [CatalogEpisode], route: CatalogRoute, season: Int, artwork: (CatalogEpisode) -> String?) -> [Episode] {
        items.compactMap { episode in
            let object: [String: Any] = [
                "id": "preview-\(route.id)-s\(season)e\(episode.number)", "titleId": "preview-\(route.id)", "season": season, "number": episode.number,
                "name": episode.name, "overview": episode.overview, "airedOn": episode.airedOn as Any? ?? NSNull(),
                "still": artwork(episode) as Any? ?? NSNull(), "hidden": false, "communityScore": episode.communityScore as Any? ?? NSNull()
            ]
            return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(Episode.self, from: $0) }
        }
    }
}

/// The title page's Episodes page for a title that isn't in your diary: the same season picker,
/// rows or cards, folded "Episodes 1 to N" groups and episode sheet. Progress, Watched / To watch
/// and Mark season as watched need the title in your diary, so they aren't here.
struct PreviewEpisodesPage: View {
    let route: CatalogRoute
    @State private var season: Int
    @Environment(DiaryStore.self) private var store
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("episodesPageGrid") private var grid = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details: CatalogDetails?
    @State private var controller: CatalogEpisodeController?
    @State private var openGroups = Set<String>()
    @State private var revealed = Set<Int>()
    @State private var selected: Int?
    @State private var sheetEpisode: Int?
    @State private var forward = true
    private enum Filter { case all, watched, toWatch }
    @State private var filter = Filter.all
    init(route: CatalogRoute, initialSeason: Int) { self.route = route; _season = State(initialValue: initialSeason) }
    private func makeController() -> CatalogEpisodeController {
        if let controller { return controller }
        let made = CatalogEpisodeController { [store, route] number, reveal in try await store.catalogEpisodes(route, season: number, reveal: reveal) }
        controller = made
        return made
    }

    var body: some View {
        let items = controller?.items ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let details { seasonCard(details, count: items.count) }
                if !items.isEmpty {
                    HStack(spacing: 8) {
                        ShowFilterChip(label: "All \(items.count)", on: filter == .all) { filter = .all }
                        ShowFilterChip(label: "Watched 0", on: filter == .watched) { filter = .watched }
                        ShowFilterChip(label: "To watch \(items.count)", on: filter == .toWatch) { filter = .toWatch }
                    }
                }
                if controller?.loading == true && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading season") }
                if let error = controller?.error { RetryNotice(message: error) { Task { await controller?.load(season, reveal: !hideSpoilers, force: true) } } }
                if items.isEmpty && controller?.loading == false { Text("No episode metadata yet").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8) }
                if !items.isEmpty {
                    if filter == .all {
                        // As on the title page: the first episodes, then the rest folded until tapped.
                        let window = EpisodeWindow(count: items.count, focus: 0)
                        list(Array(items[window.shown]))
                        if !window.after.isEmpty { group("after", Array(items[window.after])) }
                    } else if filter == .watched {
                        Text("Nothing watched in this season yet.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                    } else { list(items) }
                }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar {
            ShowPageTitle(title: "Episodes", subtitle: details?.name ?? "")
            ToolbarItem(placement: .topBarTrailing) {
                Button { grid.toggle() } label: { DiaryIcon(name: grid ? "list" : "layout-grid", size: 19) }
                    .accessibilityLabel("Show episodes as " + (grid ? "list" : "grid")).accessibilityIdentifier("episodes-page-layout")
            }
        }
        .task(id: route) { if details == nil { details = try? await store.browse(route).details } }
        .task(id: season) { await makeController().load(season, reveal: !hideSpoilers) }
        .onChange(of: season) { _, _ in revealed = []; selected = nil; openGroups = [] }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let number = selected ?? sheetEpisode { sheet(number) }
        }
        .onChange(of: selected) { _, number in if let number { sheetEpisode = number } }
    }

    private func seasonCard(_ details: CatalogDetails, count: Int) -> some View {
        let expected = details.seasons?.first(where: { $0.number == season })?.expectedEpisodes ?? 0
        let total = max(count, expected)
        return SeasonProgressCard(season: $season, seasons: (details.seasons ?? []).map(\.number), watched: 0, total: total,
                                  remainingMinutes: details.runtimeMinutes.map { $0 * total })
    }

    @ViewBuilder private func list(_ episodes: [CatalogEpisode]) -> some View {
        if grid {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                ForEach(episodes) { episode in
                    EpisodeGridCard(number: episode.number, name: name(episode), artwork: artwork(episode), hidden: hidden(episode), state: state(episode),
                                    airedOn: episode.airedOn, runtime: details?.runtimeMinutes, score: episode.communityScore,
                                    onOpen: { open(episode) }, onToggle: {}, showsTick: false)
                }
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(episodes) { episode in
                    EpisodeCardRow(number: episode.number, name: name(episode), artwork: artwork(episode), hidden: hidden(episode), state: state(episode),
                                   score: episode.communityScore, canToggle: false, onOpen: { open(episode) }, onToggle: {}, showsTick: false)
                }
            }
        }
    }
    /// "Episodes 4 to 12 · 9 to watch": folded until tapped, as on the title page.
    @ViewBuilder private func group(_ key: String, _ episodes: [CatalogEpisode]) -> some View {
        let open = openGroups.contains(key)
        let minutes = details?.runtimeMinutes.map { $0 * episodes.count }
        VStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { if open { openGroups.remove(key) } else { openGroups.insert(key) } }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Episodes \(episodes.first?.number ?? 0) to \(episodes.last?.number ?? 0)").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        Text(([episodes.count.formatted() + " episodes"] + (minutes.map { [DiaryDate.duration($0)] } ?? [])).joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    DiaryIcon(name: "chevron-down", size: 15).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
                }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)))
            }.buttonStyle(.plain).accessibilityValue(open ? "Expanded" : "Collapsed").accessibilityIdentifier("episodes-group-" + key)
            if open { list(episodes) }
        }
    }
    private func sheet(_ number: Int) -> some View {
        let items = controller?.items ?? []
        let episodes = PreviewDiaryModels.episodes(items, route: route, season: season, artwork: artwork)
        return Group {
            if let details, let title = PreviewDiaryModels.title(route, details: details), let source = items.first(where: { $0.number == number }),
               let episode = episodes.first(where: { $0.number == number }) {
                EpisodeInfoSheet(title: title, season: season, episodes: episodes, episode: episode,
                                 name: source.name.isEmpty ? "Episode \(number)" : source.name, summary: source.overview,
                                 artwork: artwork(source), hidden: false, tmdbScore: source.communityScore,
                                 traktScore: TraktTitleReads.cachedRatings(show: route.id, season: season)[number],
                                 watched: false, forward: forward, onToggleWatched: {}, onNeighbour: { neighbour(of: number, forward: $0) },
                                 onNote: {}, onClose: { selected = nil }, inDiary: false)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        }
    }
    private func aired(_ episode: CatalogEpisode) -> Bool { episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day() } == true }
    private func hidden(_ episode: CatalogEpisode) -> Bool { hideSpoilers && !revealed.contains(episode.number) }
    private func state(_ episode: CatalogEpisode) -> EpisodeRowState { aired(episode) ? .notWatched : .notAired }
    private func artwork(_ episode: CatalogEpisode) -> String? { CatalogTools.image(episode.stillPath) ?? details.flatMap { CatalogTools.image($0.backdropPath, size: "w780") } }
    private func name(_ episode: CatalogEpisode) -> String { hidden(episode) ? "A story for later" : episode.name.isEmpty ? "Episode \(episode.number)" : episode.name }
    private func open(_ episode: CatalogEpisode) {
        if hidden(episode) { revealed.insert(episode.number); Task { await controller?.load(season, reveal: true) } }
        else { selected = episode.number }
    }
    private func neighbour(of number: Int, forward: Bool) {
        let items = controller?.items ?? []
        guard let index = items.firstIndex(where: { $0.number == number }), items.indices.contains(index + (forward ? 1 : -1)) else { return }
        let next = items[index + (forward ? 1 : -1)]
        revealed.insert(next.number)
        Task { await controller?.load(season, reveal: true) }
        self.forward = forward
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { selected = next.number }
    }
}

// MARK: Cast and crew

struct CastCreditsPage: View {
    let route: CatalogRoute
    let title: String
    let anime: Bool
    let year: Int?
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var crewTab = false
    @State private var characters: [AniCharacter] = []
    @State private var cast: [CastPerson] = []
    @State private var crew: [TitleCrewMember] = []
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 4) {
                    segment(anime ? "Voice cast" : "Cast", on: !crewTab) { crewTab = false }
                    segment("Crew", on: crewTab) { crewTab = true }
                }.padding(4).background(.white.opacity(0.06), in: Capsule())
                if crewTab { crewList } else if anime && !characters.isEmpty { characterList } else { castList }
                if let failure { RetryNotice(message: failure) { Task { await load() } } }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: anime ? "Cast and characters" : "Cast and crew", subtitle: title) }
            .task(id: route) { await load() }
    }
    private func segment(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? theme.ink : Color(webHex: "#c5c0cf"))
                .frame(maxWidth: .infinity).frame(height: 40)
                .background { if on { Capsule().fill(theme.accent) } }
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    private var characterList: some View {
        LazyVStack(spacing: 10) {
            ForEach(characters) { character in
                HStack(spacing: 12) {
                    NavigationLink(value: CharacterRoute(id: character.id, sourceTitle: title)) {
                        HStack(spacing: 12) {
                            Artwork(path: character.image, title: character.name).frame(width: 72, height: 88).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(character.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                if character.role != nil { EpisodeChip(text: character.roleName, accent: character.role == "MAIN") }
                                if let actor = character.voiceActor {
                                    Text("Voiced by").font(.system(size: 12.5)).foregroundStyle(.secondary)
                                    Text(actor.name).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Color(webHex: "#e6e1ee")).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if let actor = character.voiceActor {
                        NavigationLink(value: VoiceActorRoute(id: actor.id, name: actor.name)) {
                            Artwork(path: actor.image, title: actor.name).frame(width: 64, height: 78).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.springPress).accessibilityLabel(actor.name)
                    }
                }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07)))
            }
        }
    }
    private var castList: some View {
        LazyVStack(spacing: 10) {
            ForEach(cast) { person in
                NavigationLink(value: PersonRoute(id: person.id, sourceTitle: title, sourceRole: person.character)) {
                    personRow(name: person.name, detail: person.character, image: CatalogTools.image(person.profilePath, size: "w185"))
                }.buttonStyle(.plain)
            }
            if cast.isEmpty && failure == nil { Text("No cast listed yet.").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private var crewList: some View {
        LazyVStack(spacing: 10) {
            ForEach(crew) { person in
                NavigationLink(value: PersonRoute(id: person.id, sourceTitle: title, sourceRole: person.job)) {
                    personRow(name: person.name, detail: person.job, image: CatalogTools.image(person.profilePath, size: "w185"))
                }.buttonStyle(.plain)
            }
            if crew.isEmpty && failure == nil { Text("No crew listed yet.").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
    private func personRow(name: String, detail: String, image: String?) -> some View {
        HStack(spacing: 12) {
            if image == nil {
                Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Color(webHex: "#d2c4f4"))
                    .frame(width: 54, height: 54).background(Color(webHex: "#2a2440"), in: Circle())
            } else {
                Artwork(path: image, title: name).frame(width: 54, height: 54).clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(detail).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07))).contentShape(Rectangle())
    }
    private func load() async {
        failure = nil
        if anime { characters = (try? await AniListClient.shared.characters(title: title, year: year, movie: route.kind == .movie, tmdbID: route.id)) ?? [] }
        do { cast = try await store.cast(route).cast } catch { if !Task.isCancelled && characters.isEmpty { failure = error.localizedDescription } }
        crew = (try? await TitleExtrasCache.load(store: store, route: route).crew) ?? []
    }
}

// MARK: In lists

struct InListsPage: View {
    let route: CatalogRoute
    let title: String
    @Environment(DiaryStore.self) private var store
    private enum Tab: String, CaseIterable { case popular = "Popular", recent = "Recent", yours = "Yours" }
    @State private var tab = Tab.popular
    @State private var lists: [CanvasList] = []
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) { ForEach(Tab.allCases, id: \.self) { item in ShowFilterChip(label: item.rawValue, on: tab == item) { tab = item } } }
                if loading && lists.isEmpty { DiaryLoadingPlaceholder(height: 240, label: "Loading lists") }
                else if lists.isEmpty {
                    Text(failure ?? (tab == .yours ? "None of your Trakt lists has this title." : "No public Trakt lists have this title yet."))
                        .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(lists) { list in
                        NavigationLink(value: CanvasListRoute(id: list.id, name: list.name, user: list.user)) {
                            GeometryReader { proxy in ListCollageCard(list: list, width: proxy.size.width) }.frame(height: 280)
                        }.buttonStyle(.springPress)
                    }
                }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: "In lists", subtitle: title) }
            .task(id: tab) { await load() }
    }
    private func load() async {
        loading = true; failure = nil; lists = []
        defer { loading = false }
        do {
            switch tab {
            case .popular: lists = try await TitleListsCache.load(store: store, route: route, sort: "popular")
            case .recent: lists = try await TitleListsCache.load(store: store, route: route, sort: "updated")
            case .yours: lists = try await TraktTitleReads.yourLists(store: store, route: route)
            }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

// MARK: Related collections

struct RelatedCollectionsPage: View {
    let route: CatalogRoute
    let title: String
    let anime: Bool
    @Environment(DiaryStore.self) private var store
    @State private var model = RelatedCollectionsModel()
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, collection in
                    RelatedCollectionLink(collection: collection, route: route, anime: anime) {
                        RelatedCollectionCard(collection: collection, index: index, showCount: true).frame(height: 132)
                    }
                }
                if model.loaded && model.items.isEmpty {
                    Text(model.needsKey ? "Add your TMDB key in Settings → Connections → TMDB to see related collections." : "TMDB has no related collections for this title.")
                        .font(.subheadline).foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.center)
                }
                if !model.loaded { ProgressView().padding(.top, 40) }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: "Related collections", subtitle: title) }
            .task(id: route) { await model.load(store: store, route: route, anime: anime) }
    }
}

/// One TMDb collection (a film series): its films oldest first, each opening its page.
struct TMDbCollectionPage: View {
    let id: Int
    let name: String
    @Environment(DiaryStore.self) private var store
    @State private var collection: TitleCollection?
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let collection {
                    if !collection.overview.isEmpty {
                        Text(collection.overview).font(.system(size: 14)).lineSpacing(3).foregroundStyle(HomeStyle.soft)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 18) {
                        ForEach(collection.parts, id: \.key) { item in link(item) }
                    }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: name, subtitle: collection.map { $0.parts.count.counted("film", "films") } ?? "TMDb collection") }
            .task(id: id) { await load() }
    }
    @ViewBuilder private func link(_ item: CatalogItem) -> some View {
        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) {
            NavigationLink(value: saved) { poster(item) }.buttonStyle(.springPress)
        } else {
            NavigationLink(value: item.route) { poster(item) }.buttonStyle(.springPress)
        }
    }
    private func poster(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false).aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: HomeStyle.hairline))
            Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 9)
            Text(item.year.map(String.init) ?? "Movie").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).padding(.top, 4)
        }
    }
    private func load() async {
        failure = nil
        do {
            if let token = TMDBDirect.token(store) { collection = try await TMDBDirect.collection(id, token: token) }
            else { collection = try await store.read(CatalogTools.apiPath("/api/metadata/collection", query: ["id": String(id)])) }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

// MARK: Companies

struct CompaniesPage: View {
    let route: CatalogRoute
    let title: String
    @Environment(DiaryStore.self) private var store
    private enum Filter: String, CaseIterable { case all = "All", studios = "Studios", networks = "Networks" }
    @State private var filter = Filter.all
    @State private var extras: TitleExtras?
    @State private var failure: String?
    var body: some View {
        let companies = (extras?.companies ?? []).filter { filter == .all || (filter == .networks) == $0.isNetwork }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        if item != .networks || extras?.networks.isEmpty == false { ShowFilterChip(label: item.rawValue, on: filter == item) { filter = item } }
                    }
                }
                LazyVStack(spacing: 10) {
                    ForEach(companies, id: \.key) { company in
                        NavigationLink(value: CompanyRoutes.explore(company, kind: route.kind)) {
                            HStack(spacing: 14) {
                                CompanyLogo(company: company).frame(width: 108, height: 66)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(company.name).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(CompanyRoutes.label(company, animated: animated)).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
                            }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.07))).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("companies-page-\(company.key)")
                    }
                }
                if let failure { RetryNotice(message: failure) { Task { await load() } } }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: "Companies", subtitle: title) }
            .task(id: route) { await load() }
    }
    private var animated: Bool {
        guard let saved = store.workspace.activeTitles.first(where: { $0.tmdbId == route.id && $0.isSeries == (route.kind == .tv) }) else { return false }
        return saved.genres.contains("Animation") || saved.category.hasPrefix("anime")
    }
    private func load() async {
        failure = nil
        do { extras = try await TitleExtrasCache.load(store: store, route: route) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
