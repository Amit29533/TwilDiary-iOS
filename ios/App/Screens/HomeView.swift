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
        let projection = store.homeProjection(at: now)
        let overview = projection.overview
        let watching = projection.watching
        let recent = projection.recent
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 0) {
                // While searching, the plain header keeps the field and its results at the top.
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
                        Text("Based on your saved episode dates. Air dates may change.").font(.system(size: 13)).foregroundStyle(Color(webHex: "#a09aa9")).frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(spacing: 0) {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            calendarMetric(String(schedule.totalCount), mode == .catchup ? "Catch-up" : "Upcoming", accent: true)
                            calendarMetric(String(schedule.animeCount), "Anime")
                            calendarMetric(String(schedule.showCount), "TV Shows")
                            calendarMetric(String(schedule.thisWeekCount), mode == .catchup ? "Past 7d" : "Next 7d")
                        }
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                            ForEach(schedule.strip) { cell in
                                let isSelected = selectedDate.map { DiaryDate.calendar().isDate($0, inSameDayAs: cell.date) } ?? false
                                Button {
                                    if isSelected { selectedDate = nil } else { selectedDate = cell.date }
                                } label: {
                                    VStack(spacing: 3) {
                                        Text(cell.daysAway == 0 ? "Now" : cell.date.formatted(.dateTime.weekday(.narrow)))
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(cell.date, format: .dateTime.day())
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(cell.daysAway == 0 ? theme.accent : .primary)
                                        HStack(spacing: 3) {
                                            if cell.animeCount > 0 { Circle().fill(theme.accent).frame(width: 5, height: 5) }
                                            if cell.showCount > 0 { Circle().fill(Color.blue.opacity(0.85)).frame(width: 5, height: 5) }
                                            if cell.total == 0 { Circle().fill(.white.opacity(0.12)).frame(width: 4, height: 4) }
                                        }.frame(height: 6)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? theme.accent.opacity(0.24) : (cell.total > 0 ? theme.accent.opacity(0.09) : .white.opacity(0.02)),
                                        in: RoundedRectangle(cornerRadius: 9)
                                    )
                                }.buttonStyle(.plain)
                            }
                        }
                    }.diaryPanel()

                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(UpcomingSchedule.Mode.allCases) { item in
                            Button { mode = item; selectedDate = nil } label: {
                                Text(item.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .foregroundStyle(mode == item ? .primary : .secondary)
                                    .background(mode == item ? theme.accent.opacity(0.22) : .white.opacity(0.04), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        ForEach(UpcomingSchedule.CategoryFilter.allCases) { item in
                            Button { category = item } label: {
                                Text(item.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .foregroundStyle(category == item ? .primary : .secondary)
                                    .background(category == item ? theme.accent.opacity(0.22) : .white.opacity(0.04), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach([7, 30, 90], id: \.self) { days in
                            Button { horizonDays = days; selectedDate = nil } label: {
                                Text("\(days)d")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 10).frame(height: 32)
                                    .foregroundStyle(horizonDays == days ? .primary : .secondary)
                                    .background(horizonDays == days ? theme.accent.opacity(0.22) : .white.opacity(0.04), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        Button { dedupeByTitle.toggle() } label: {
                            Text(dedupeByTitle ? "Next only" : "All eps").lineLimit(1).fixedSize()
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 11).frame(height: 32)
                                .foregroundStyle(dedupeByTitle ? .primary : .secondary)
                                .background(dedupeByTitle ? theme.accent.opacity(0.22) : .white.opacity(0.04), in: Capsule())
                        }.buttonStyle(.plain)
                        if !schedule.items.isEmpty {
                            ShareLink(item: schedule.icsString(hideSpoilers: hideSpoilers), subject: Text("TwilDiary Airing Schedule")) {
                                HStack(spacing: 4) {
                                    DiaryIcon(name: "download", size: 12)
                                    Text(".ics").lineLimit(1).fixedSize()
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).frame(height: 32)
                                .foregroundStyle(.secondary)
                                .background(.white.opacity(0.04), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        Button {
                            guard !syncingDates else { return }
                            syncingDates = true
                            Task {
                                let activeSeries = store.workspace.activeTitles.filter { $0.isSeries && ($0.status == "watching" || $0.status == "planned") }.prefix(10)
                                for series in activeSeries {
                                    await store.refreshTitleMetadata(series)
                                }
                                syncingDates = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                DiaryIcon(name: "rotate-ccw", size: 12)
                                Text(syncingDates ? "Syncing…" : "Sync").lineLimit(1).fixedSize()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 32)
                            .foregroundStyle(.secondary)
                            .background(.white.opacity(0.04), in: Capsule())
                        }.buttonStyle(.plain).disabled(syncingDates || store.writesBlocked)
                    }

                    ForEach(visibleDays) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(day.daysAway == 0 ? "Today" : day.daysAway == 1 ? "Tomorrow" : day.daysAway == -1 ? "Yesterday" : day.daysAway < 0 ? "\(abs(day.daysAway))d ago" : "In \(day.daysAway) days")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                                Text("· " + day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(day.items.count) \(day.items.count == 1 ? "ep" : "eps")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(day.items) { item in
                                HStack(spacing: 10) {
                                    NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) {
                                        HStack(spacing: 12) {
                                            Artwork(path: item.title.poster, title: item.title.name, initialsOnly: false)
                                                .frame(width: 42, height: 62)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 6) {
                                                    Text(item.title.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                                    Text(item.title.categoryName)
                                                        .font(.system(size: 10, weight: .bold))
                                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                                        .background(item.isAnime ? theme.accent.opacity(0.22) : Color.blue.opacity(0.2), in: Capsule())
                                                }
                                                Text("S\(item.episode.season) E\(item.episode.number)" + (!hideSpoilers && !item.episode.name.isEmpty ? " · \(item.episode.name)" : ""))
                                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 4)
                                            VStack(alignment: .trailing, spacing: 4) {
                                                Text(item.daysAway == 0 ? "Today" : item.daysAway == 1 ? "Tomorrow" : item.daysAway < 0 ? "\(abs(item.daysAway))d ago" : "In \(item.daysAway)d")
                                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint)
                                                Text(item.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                            }
                                        }.foregroundStyle(.primary)
                                    }.buttonStyle(.plain)
                                    if item.daysAway <= 0 {
                                        Button {
                                            Task { await store.recordViewing(item.title, episode: item.episode, watchedAt: store.now) }
                                        } label: {
                                            DiaryIcon(name: "check", size: 18).foregroundStyle(theme.accent)
                                                .frame(width: 44, height: 44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(store.writesBlocked)
                                    }
                                }.diaryPanel()
                            }
                        }
                    }

                    if visibleDays.isEmpty {
                        Text(mode == .catchup
                             ? "No unwatched aired \(category == .all ? "anime or show" : category.rawValue.lowercased()) episodes in the past \(horizonDays) days."
                             : "No upcoming \(category == .all ? "anime or show" : category.rawValue.lowercased()) air dates in your library for the next \(horizonDays) days.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).diaryPanel()
                    }
                }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 24)
            }
        }.diaryScreenBackground().navigationTitle("Airing calendar").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
    private func calendarMetric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(accent ? theme.accent : .primary)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
