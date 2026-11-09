import SwiftUI
import TwilDiaryCore

/// Owner's Home design: a full-bleed Continue watching backdrop behind the header, a wide
/// Explore button, This week, Up next posters, New episodes and Recently watched.
struct HomeView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = Date.now
    @State private var upcomingLimit = 3
    /// Changes only when vertical scrolling starts or settles, never per frame.
    @State private var scrolling = false
    @SceneStorage("home.continue.title") private var continueSelection = ""
    @AppStorage("homeHistoryGrid") private var historyGrid = false
    @AppStorage("upcomingGrid") private var upcomingGrid = false
    var body: some View {
        let now = store.isPreview ? store.now : clock
        let request = store.homeProjectionRequest(at: now)
        ZStack {
            // A missing projection is still loading. Only a loaded diary with no
            // watching titles should show the shorter Home header.
            if let projection = store.homeProjection {
                dashboard(projection, now: now)
            } else {
                ProgressView().accessibilityLabel("Opening your diary")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: request) { await store.prepareHomeProjection(request) }
        // Favourites are kept on the server; one small read per session brings them up to date.
        .task(id: store.sessionRevision) { await FavouritesStore.shared.sync(store: store) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { clock = store.now } }
        .task {
            clock = store.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                clock = store.now
            }
        }
    }
    private func dashboard(_ projection: DiaryStore.HomeProjection, now: Date) -> some View {
        let overview = projection.overview
        let watching = projection.watching
        let recent = projection.recent
        return EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 0) {
                if watching.isEmpty { header(overArtwork: false) } else { continueSection(watching) }
                VStack(alignment: .leading, spacing: 28) {
                    // Explore is systematic discovery; Canvas is for browsing artwork at random.
                    HStack(spacing: 10) {
                        NavigationLink(value: AppDestination.explore) { discoverButton("Explore", icon: "compass") }.buttonStyle(.plain).accessibilityIdentifier("explore-shortcut")
                        NavigationLink(value: AppDestination.canvas) { discoverButton("Canvas", icon: "layout-grid") }.buttonStyle(.plain).accessibilityIdentifier("canvas-shortcut")
                    }
                    VStack(spacing: 12) {
                        heading("This week") { SectionMoreButton(label: "Stats", identifier: "home-stats") { router.statsToday() } }
                        weekPanel(overview, now: now)
                    }
                    if !overview.planned.isEmpty { VStack(spacing: 12) {
                        heading("Up next") { SectionMoreButton(label: "Planned", identifier: "home-upnext-more") { router.library("planned") } }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(overview.planned.prefix(12)) { title in
                                    NavigationLink(value: title.id) { HomePlannedCard(title: title).zoomSource(ZoomID.title(title.id)) }
                                        .buttonStyle(.plain).accessibilityIdentifier("home-planned-" + title.id)
                                        .containerRelativeFrame(.horizontal) { width, _ in min(144, max(96, (width - 24) / 3.15)) }
                                        .shelfTransition()
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                    }.padding(.horizontal, -4)
                    }
                    if let seed = recent.first(where: { $0.title.tmdbId != nil })?.title { HomeRecommendedShelf(seed: seed) }
                    // Recently hearted cast and characters together, right under Up next; › opens them by kind.
                    let favourites = FavouritesStore.shared.items
                    if !favourites.isEmpty { VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill").foregroundStyle(theme.accent).accessibilityHidden(true)
                            Text("Favourites").font(.system(size: 22, weight: .bold)).tracking(-0.6)
                            Spacer(minLength: 4)
                            SectionMoreLink(label: "All favourites", value: AppDestination.favourites, identifier: "home-favourites")
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(favourites.prefix(12)) { item in
                                    FavouriteLink(item: item, homeCard: true)
                                        .containerRelativeFrame(.horizontal) { width, _ in min(144, max(96, (width - 24) / 3.15)) }
                                        .shelfTransition()
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                    }.padding(.horizontal, -4) }
                    VStack(spacing: 12) {
                        heading("New episodes") { CollectionLayoutToggle(grid: $upcomingGrid, collection: "upcoming", gridName: "cards"); SectionMoreLink(label: "Airing calendar", value: AppDestination.calendar, identifier: "home-calendar-more") }
                        HomeActivityLayout(cards: upcomingGrid) { ForEach(overview.upcoming.prefix(upcomingLimit)) { item in
                            NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) {
                                HomeEpisodeCard(model: HomeEpisodeCardModel(upcoming: item), cards: upcomingGrid)
                            }.buttonStyle(.plain).accessibilityIdentifier("home-upcoming-" + item.title.id)
                        } }
                        if overview.upcoming.isEmpty {
                            HStack(spacing: 16) {
                                DiaryIcon(name: "calendar-days", size: 22).foregroundStyle(theme.accent)
                                Text("No upcoming air dates in your library for the next 30 days.").font(.system(size: 15)).foregroundStyle(Color(webHex: "#c5c0cf")).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 6).diaryPanel(radius: 18)
                        }
                        if overview.upcoming.count > upcomingLimit { Button("Show more episodes") { upcomingLimit += 5 } }
                    }.padding(.horizontal, -4)
                    if !recent.isEmpty { VStack(spacing: 12) {
                        heading("Recently watched") { CollectionLayoutToggle(grid: $historyGrid, collection: "home-history", gridName: "cards"); SectionMoreLink(label: "All history", value: AppDestination.history, identifier: "home-history-more") }
                        HomeActivityLayout(cards: historyGrid) { ForEach(recent) { entry in
                            NavigationLink(value: entry.title.id) {
                                HomeEpisodeCard(model: HomeEpisodeCardModel(history: entry), cards: historyGrid)
                            }.buttonStyle(.plain).accessibilityIdentifier("home-history-event-" + entry.id)
                        } }
                    }.padding(.horizontal, -4) }
                }.padding(.horizontal, 16).padding(.top, watching.isEmpty ? 8 : 20).padding(.bottom, 24)
            }
        }
        .contentMargins(.bottom, 90, for: .scrollContent)
        .onScrollPhaseChange { _, phase in
            // The automatic carousel step must not animate mid-fling under the finger.
            let active = phase != .idle
            if scrolling != active { scrolling = active }
        }
        .refreshable { clock = store.now; await store.refresh(); await FavouritesStore.shared.sync(store: store) }
    }
    /// True full screen: the whole header scrolls away with the artwork.
    private func header(overArtwork: Bool) -> some View { PageHeader(name: "TwilDiary", overArtwork: overArtwork) }
    /// The selected title's backdrop fills the top of the page, under the status bar and header,
    /// and fades into the page so the text below it stays readable.
    private func continueSection(_ titles: [MediaTitle]) -> some View {
        let current = titles.first { $0.id == continueSelection } ?? titles[0]
        return VStack(alignment: .leading, spacing: 0) {
            header(overArtwork: true)
            Spacer(minLength: 72)
            // "CONTINUE WATCHING" sits inside each page, right above its title.
            ContinueWatchingCarousel(titles: titles, selection: $continueSelection, automaticAllowed: !scrolling).padding(.horizontal, 8)
        }.background(alignment: .top) {
            // The art fills the section and reaches just under the status bar. It used to reach 140 pt
            // higher, which enlarged a 16:9 backdrop about 2x and cut off half of it; with only the
            // status bar's height it is enlarged about 1.7x, so more of the picture shows.
            GeometryReader { proxy in
            Artwork(path: current.backdrop ?? current.poster, title: current.name)
                .frame(width: proxy.size.width, height: proxy.size.height + Self.artLift)
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.05), location: 0.28),
                                           .init(color: .black.opacity(0.35), location: 0.62), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .overlay { LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .center) }
                .offset(y: -Self.artLift).modifier(StretchOnPull()).id(current.id).transition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: current.id)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    /// Just enough to reach under the status bar; pulling down stretches the art instead of revealing a gap.
    private static let artLift: CGFloat = 64
    private func discoverButton(_ name: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            DiaryIcon(name: icon, size: 16).foregroundStyle(theme.ink).frame(width: 30, height: 30).background(theme.accent, in: Circle())
            Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
            Spacer(minLength: 0)
        }.frame(height: 54).frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { DiaryIcon(name: "chevron-right", size: 15).foregroundStyle(theme.accent).padding(.trailing, 16) }
            .background(theme.accent.opacity(0.1), in: Capsule()).overlay(Capsule().strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.5))
            .contentShape(Capsule())
    }
    private func heading<Trailing: View>(_ name: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 22, weight: .bold)).tracking(-0.6)
            Spacer(minLength: 4)
            trailing().font(.system(size: 15, weight: .semibold)).tint(theme.accent)
        }.frame(minHeight: 32)
    }
    private func weekPanel(_ overview: HomeOverview, now: Date) -> some View {
        let maximum = max(1, overview.days.map(\.minutes).max() ?? 0)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 0) {
                metric(DiaryDate.duration(overview.minutes), "Watch time", accent: true)
                divider
                metric(String(overview.watches), "Watches")
                divider
                metric("\(overview.streak) \(overview.streak == 1 ? "day" : "days")", "Current streak")
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) { ForEach(overview.days) { day in
                NavigationLink(value: HistoryRoute(day: day.date)) {
                    VStack(spacing: 6) {
                        Text(day.date, format: .dateTime.weekday(.narrow)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(day.date, format: .dateTime.day()).font(.system(size: 16, weight: .semibold)).foregroundStyle(DiaryDate.calendar().isDate(day.date, inSameDayAs: now) ? theme.accent : .primary)
                        // Days without watches keep a dim full-height slot, as in the design.
                        VStack { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 4).fill(day.minutes > 0 ? theme.accent : .white.opacity(0.08)).frame(width: 13, height: day.minutes > 0 ? max(8, 30 * CGFloat(day.minutes) / CGFloat(maximum)) : 24) }.frame(height: 30)
                    }.frame(maxWidth: .infinity).foregroundStyle(.primary).opacity(day.future ? 0.45 : 1)
                }.buttonStyle(.plain).disabled(day.future).accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(day.count) watches")
            } }
        }.diaryPanel(radius: 18)
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 44).padding(.horizontal, 14) }
    private func metric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 24, weight: .bold)).tracking(-0.7).foregroundStyle(accent ? theme.accent : .primary).lineLimit(1).minimumScaleFactor(0.7); Text(label).font(.system(size: 13)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pulling the page down to refresh zooms the artwork from its bottom edge: it grows by exactly the
/// pull, so its top stays at the top of the screen instead of sliding down and leaving a gap.
private struct StretchOnPull: ViewModifier {
    @State private var restingY: CGFloat?
    func body(content: Content) -> some View {
        let rest = restingY
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView(axis: .vertical)).minY } action: { y in if restingY == nil { restingY = y } }
            .visualEffect { view, proxy in
                let height = proxy.size.height
                guard let rest, height > 0 else { return view.scaleEffect(1, anchor: .bottom) }
                let pull = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY - rest)
                return view.scaleEffect(1 + pull / height, anchor: .bottom)
            }
    }
}

struct AiringCalendarView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var category: UpcomingSchedule.CategoryFilter = .all
    @State private var mode: UpcomingSchedule.Mode = .upcoming
    @State private var horizonDays: Int = 30
    @State private var dedupeByTitle = false
    @State private var selectedDate: Date? = nil
    @State private var syncingDates = false
    var body: some View {
        let schedule = UpcomingSchedule(
            workspace: store.workspace,
            now: store.now,
            category: category,
            horizonDays: horizonDays,
            dedupeByTitle: dedupeByTitle,
            mode: mode
        )
        let visibleDays = selectedDate.map { day in schedule.days.filter { DiaryDate.calendar().isDate($0.date, inSameDayAs: day) } } ?? schedule.days
        let groups = weekGroups(visibleDays.flatMap(\.items))
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 22) {
                    ForEach(UpcomingSchedule.Mode.allCases) { item in
                        Button { mode = item; selectedDate = nil } label: {
                            VStack(spacing: 8) {
                                Text(item.rawValue).font(.system(size: 17, weight: .semibold)).foregroundStyle(mode == item ? .white : .secondary)
                                Capsule().fill(mode == item ? theme.accent : .clear).frame(height: 3)
                            }.fixedSize()
                        }.buttonStyle(.plain).accessibilityAddTraits(mode == item ? .isSelected : [])
                    }
                    Spacer()
                }.overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                monthCard(schedule)
                HStack(spacing: 8) {
                    Menu {
                        Picker("Type", selection: $category) { ForEach(UpcomingSchedule.CategoryFilter.allCases) { Text($0.rawValue).tag($0) } }
                    } label: { FilterPill(label: category.rawValue, active: category != .all) }
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Range", selection: $horizonDays) { ForEach([7, 30, 90], id: \.self) { Text((mode == .catchup ? "Past " : "Next ") + "\($0) days").tag($0) } }
                    } label: { FilterPill(label: (mode == .catchup ? "Past " : "Next ") + "\(horizonDays) days") }
                }
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 4) {
                            Text(group.label).foregroundStyle(Color(webHex: "#c5c0cf"))
                            Text("(\(group.items.count))").foregroundStyle(.white)
                        }.font(.system(size: 20, weight: .bold))
                        ForEach(group.items) { item in episodeRow(item) }
                    }
                }
                if visibleDays.isEmpty {
                    Text(mode == .catchup
                         ? "No unwatched aired \(category == .all ? "anime or show" : category.rawValue.lowercased()) episodes in the past \(horizonDays) days."
                         : "No upcoming \(category == .all ? "anime or show" : category.rawValue.lowercased()) air dates in your library for the next \(horizonDays) days.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).diaryPanel()
                }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 24)
        }.diaryScreenBackground().navigationTitle("Airing calendar").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Next episode only", isOn: $dedupeByTitle)
                        if !schedule.items.isEmpty {
                            ShareLink(item: schedule.icsString(hideSpoilers: hideSpoilers), subject: Text("TwilDiary Airing Schedule")) { Label("Export to Calendar (.ics)", systemImage: "calendar.badge.plus") }
                        }
                        Button(syncingDates ? "Syncing air dates…" : "Sync air dates", systemImage: "arrow.clockwise") { syncDates() }.disabled(syncingDates || store.writesBlocked)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Calendar options")
                }
            }
    }
    private func syncDates() {
        guard !syncingDates else { return }
        syncingDates = true
        Task {
            let activeSeries = store.workspace.activeTitles.filter { $0.isSeries && ($0.status == "watching" || $0.status == "planned") }.prefix(10)
            for series in activeSeries { await store.refreshTitleMetadata(series) }
            syncingDates = false
        }
    }
    /// The month header: counts, then the strip of days (now marked; days with episodes tinted and dotted).
    private func monthCard(_ schedule: UpcomingSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.now.formatted(.dateTime.month(.wide))).font(.system(size: 20, weight: .bold))
                Spacer()
                HStack(spacing: 4) {
                    Text("\(schedule.totalCount)").foregroundStyle(theme.accent).bold()
                    Text(mode == .catchup ? "to catch up ·" : "upcoming ·").foregroundStyle(.secondary)
                    Text("\(schedule.thisWeekCount)").foregroundStyle(theme.accent).bold()
                    Text(mode == .catchup ? "past week" : "this week").foregroundStyle(.secondary)
                }.font(.system(size: 14))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
                    Text(["M", "T", "W", "T", "F", "S", "S"][index]).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(schedule.strip) { cell in
                    let isSelected = selectedDate.map { DiaryDate.calendar().isDate($0, inSameDayAs: cell.date) } ?? false
                    Button { selectedDate = isSelected ? nil : cell.date } label: {
                        VStack(spacing: 1) {
                            Text(cell.date, format: .dateTime.day()).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(cell.daysAway == 0 ? theme.ink : cell.total > 0 ? .white : .secondary)
                            if cell.daysAway == 0 { Text("NOW").font(.system(size: 8, weight: .heavy)).foregroundStyle(theme.ink) }
                            else { Circle().fill(cell.total > 0 ? theme.accent : .clear).frame(width: 5, height: 5) }
                        }.frame(maxWidth: .infinity).frame(height: 46)
                            .background(cell.daysAway == 0 ? AnyShapeStyle(theme.accent) : isSelected ? AnyShapeStyle(theme.accent.opacity(0.35)) : cell.total > 0 ? AnyShapeStyle(theme.accent.opacity(0.16)) : AnyShapeStyle(Color.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel(cell.date.formatted(date: .abbreviated, time: .omitted) + ", \(cell.total) episodes")
                }
            }
        }.padding(16).diaryPanel(padding: 0, radius: 22)
    }
    private struct WeekGroup { let label: String; let items: [UpcomingSchedule.Item] }
    /// This week, next week, then by week, in date order (catch-up: newest first).
    private func weekGroups(_ items: [UpcomingSchedule.Item]) -> [WeekGroup] {
        var calendar = DiaryDate.calendar(); calendar.firstWeekday = 2
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: store.now)?.start ?? store.now
        var groups: [Int: [UpcomingSchedule.Item]] = [:]
        for item in items {
            let start = calendar.dateInterval(of: .weekOfYear, for: item.date)?.start ?? item.date
            let offset = Int((start.timeIntervalSince(thisWeek) / (7 * 86_400)).rounded())
            groups[offset, default: []].append(item)
        }
        func label(_ offset: Int) -> String {
            switch offset {
            case 0: "This week"
            case 1: "Next week"
            case -1: "Last week"
            default: offset > 1 ? "In \(offset) weeks" : "\(-offset) weeks ago"
            }
        }
        let order = groups.keys.sorted { mode == .catchup ? $0 > $1 : $0 < $1 }
        return order.map { WeekGroup(label: label($0), items: (groups[$0] ?? []).sorted { mode == .catchup ? $0.date > $1.date : $0.date < $1.date }) }
    }
    private func episodeRow(_ item: UpcomingSchedule.Item) -> some View {
        let away = item.daysAway == 0 ? "Today" : item.daysAway == 1 ? "Tomorrow" : item.daysAway < 0 ? "\(abs(item.daysAway))d ago" : "In \(item.daysAway)d"
        let summary = hideSpoilers ? item.title.overview : (item.episode.overview.isEmpty ? item.title.overview : item.episode.overview)
        return HStack(alignment: .top, spacing: 14) {
            NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) {
                HStack(alignment: .top, spacing: 14) {
                    Artwork(path: item.title.poster, title: item.title.name, initialsOnly: false).frame(width: 80, height: 112).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            HStack(spacing: 0) {
                                Text(item.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " · ").foregroundStyle(.secondary)
                                Text(away).foregroundStyle(theme.accent)
                            }.lineLimit(1)
                            Spacer(minLength: 4)
                            if let score = item.title.communityScore, score > 0 {
                                HStack(spacing: 3) { Image(systemName: "star.fill").font(.system(size: 10)); Text(score.formatted(.number.precision(.fractionLength(1)))) }
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#d2c4f4"))
                                    .padding(.horizontal, 8).frame(height: 24).background(theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }.font(.system(size: 14))
                        Text(item.title.name).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
                        Text(item.title.categoryName + " · S\(item.episode.season) E\(item.episode.number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                        if !summary.isEmpty { Text(summary).font(.system(size: 14)).foregroundStyle(Color(webHex: "#c5c0cf")).lineLimit(2).multilineTextAlignment(.leading) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if item.daysAway <= 0 {
                Button { Task { await store.recordViewing(item.title, episode: item.episode, watchedAt: store.now) } } label: {
                    DiaryIcon(name: "check", size: 18).foregroundStyle(theme.accent).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.writesBlocked).accessibilityLabel("Mark watched")
            }
        }
    }
    private func calendarMetric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(accent ? theme.accent : .primary)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
