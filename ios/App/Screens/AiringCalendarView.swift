import SwiftUI
import TwilDiaryCore

/// Airing calendar (owner's design): Upcoming (two Monday-first weeks with today marked), Catch-up
/// (what aired that you haven't watched, per show, with Watch E52 and Mark all) and All. Type,
/// genre and range filters (the range only there); the ••• menu holds "Show all episodes", export
/// and sync (not on Global, which has none of them).
struct AiringCalendarView: View {
    /// Everything: every release in the next days, not only your diary's (owner's request).
    enum Tab: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming", catchup = "Catch-up", all = "All", everything = "Everything"
        var id: String { rawValue }
        /// The name on screen; the raw value stays as saved (calendar.tab) and in test ids.
        var title: String { switch self { case .upcoming: "Upcoming"; case .catchup: "Missed"; case .all: "Following"; case .everything: "Global" } }
    }
    enum Status: String, CaseIterable, Identifiable { case all = "All status", upcoming = "Upcoming", behind = "Behind"; var id: String { rawValue } }
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("calendar.tab") private var tab = Tab.upcoming
    @State private var category: UpcomingSchedule.CategoryFilter = .all
    @State private var upcomingDays = 30
    @State private var catchupDays = 7
    @State private var showAllEpisodes = true
    @State private var status = Status.all
    @State private var genres: Set<String> = []
    @State private var showGenres = false
    @State private var selectedDate: Date?
    @State private var syncingDates = false
    @State private var confirmMarkAll = false
    @State private var marking = false
    @Namespace private var underline

    private var range: Int { tab == .catchup ? catchupDays : upcomingDays }
    /// Both schedules, worked out in the background when the diary or the filters change (they read
    /// every episode and watch): redraws, and the swipe back, only show what's already done.
    @State private var computed: (key: String, upcoming: UpcomingSchedule, aired: UpcomingSchedule)?
    private var scheduleKey: String {
        [store.homeWorkspaceRevision.uuidString, category.rawValue, tab.rawValue, String(upcomingDays), String(catchupDays),
         String(showAllEpisodes), DiaryDate.day(store.now)].joined(separator: "|")
    }
    private func computeSchedules() async {
        let key = scheduleKey, snapshot = store.workspace, now = store.now, category = category, dedupe = !showAllEpisodes
        let upcomingSpan = tab == .all ? 365 : upcomingDays, airedSpan = tab == .all ? 365 : catchupDays
        let result = await Task.detached(priority: .userInitiated) {
            (UpcomingSchedule(workspace: snapshot, now: now, category: category, horizonDays: upcomingSpan, dedupeByTitle: dedupe, mode: .upcoming),
             UpcomingSchedule(workspace: snapshot, now: now, category: category, horizonDays: airedSpan, dedupeByTitle: false, mode: .catchup))
        }.value
        guard !Task.isCancelled else { return }
        computed = (key, result.0, result.1)
    }
    private static let empty = UpcomingSchedule(workspace: Workspace(), now: .now, category: .all, horizonDays: 1, dedupeByTitle: false, mode: .upcoming)
    private func narrowed(_ items: [UpcomingSchedule.Item]) -> [UpcomingSchedule.Item] {
        genres.isEmpty ? items : items.filter { !genres.isDisjoint(with: $0.title.genres) }
    }

    var body: some View {
        let upcoming = computed?.upcoming ?? Self.empty
        let aired = computed?.aired ?? Self.empty
        let upcomingItems = narrowed(upcoming.items), airedItems = narrowed(aired.items)
        let genreNames = Set((upcoming.items + aired.items).flatMap(\.title.genres)).sorted()
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 16) {
                tabs
                if tab == .everything { UniversalCalendarSection() }
                else if computed == nil { DiaryLoadingPlaceholder(height: 260, label: "Loading the calendar") }
                else { switch tab {
                case .upcoming:
                    monthCard(upcomingItems)
                    filters
                    upcomingList(upcomingItems)
                case .catchup:
                    if !airedItems.isEmpty { catchupCard(airedItems) }
                    filters
                    catchupList(airedItems)
                case .all:
                    filters
                    allList(upcoming: status == .behind ? [] : upcomingItems, aired: status == .upcoming ? [] : airedItems)
                case .everything:
                    EmptyView()
                } }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 110)
        }.diaryScreenBackground().diaryPageNavigation("Airing calendar")
            .toolbar {
                // Global has none of these (its own filters do it all).
                if tab != .everything { ToolbarItem(placement: .topBarTrailing) { optionsMenu(upcoming: upcoming, aired: aired) } }
            }
            .sheet(isPresented: $showGenres) { CalendarGenreSheet(names: genreNames, chosen: $genres) }
            .onChange(of: tab) { _, _ in selectedDate = nil }
            // Everything has its own list: your shows' schedules wait until you're back on their tabs.
            .task(id: scheduleKey) { if tab != .everything { await computeSchedules() } }
            .task { await TraktAirTimes.shared.refresh(store: store) }
    }

    // MARK: Header pieces

    private var tabs: some View {
        HStack(spacing: 24) {
            ForEach(Tab.allCases) { item in
                let on = tab == item
                Button { withAnimation(.snappy(duration: 0.25)) { tab = item } } label: {
                    VStack(spacing: 8) {
                        Text(item.title).font(.system(size: 16, weight: on ? .bold : .semibold)).foregroundStyle(on ? HomeStyle.primary : HomeStyle.secondary)
                        ZStack { if on { Capsule().fill(theme.accent).matchedGeometryEffect(id: "line", in: underline) } else { Color.clear } }.frame(height: 3)
                    }.fixedSize().frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("calendar-tab-" + item.id)
            }
            Spacer()
        }.overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private func optionsMenu(upcoming: UpcomingSchedule, aired: UpcomingSchedule) -> some View {
        // The range is the filter row's pill alone (one way to pick days, owner's request).
        Menu {
            Section { Toggle("Show all episodes", isOn: $showAllEpisodes) }
            Section {
                if !upcoming.items.isEmpty {
                    ShareLink(item: upcoming.icsString(hideSpoilers: hideSpoilers), subject: Text("TwilDiary Airing Schedule")) { Label("Export .ics", systemImage: "calendar.badge.plus") }
                }
                Button(syncingDates ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise") { syncDates() }.disabled(syncingDates || store.writesBlocked)
            }
        } label: { TitleMoreButtonLabel() }.accessibilityLabel("Calendar options").accessibilityIdentifier("calendar-options")
    }
    private func rangeLabel(_ days: Int) -> String { (tab == .catchup ? "Last " : "Next ") + "\(days) days" }

    private var filters: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Type", selection: $category) {
                    Text("Anime & shows").tag(UpcomingSchedule.CategoryFilter.all)
                    Text("Anime").tag(UpcomingSchedule.CategoryFilter.anime)
                    Text("Shows").tag(UpcomingSchedule.CategoryFilter.show)
                }
            } label: { pill(category == .all ? "All types" : category.rawValue, active: category != .all) }.accessibilityIdentifier("calendar-type")
            Button { showGenres = true } label: { pill(genreLabel, active: !genres.isEmpty) }.buttonStyle(.plain).accessibilityIdentifier("calendar-genres")
            Spacer(minLength: 0)
            if tab == .all {
                Menu { Picker("Status", selection: $status) { ForEach(Status.allCases) { Text($0.rawValue).tag($0) } } }
                    label: { pill(status.rawValue, active: status != .all) }.accessibilityIdentifier("calendar-status")
            } else {
                Menu { Picker("Range", selection: tab == .catchup ? $catchupDays : $upcomingDays) { ForEach([7, 30, 90], id: \.self) { Text(rangeLabel($0)).tag($0) } } }
                    label: { pill(rangeLabel(range)) }.accessibilityIdentifier("calendar-range")
            }
        }
    }
    private var genreLabel: String {
        guard let first = genres.sorted().first else { return "Genres" }
        return genres.count == 1 ? first : first + " +\(genres.count - 1)"
    }
    private func pill(_ label: String, active: Bool = false) -> some View { CalendarStyle.pill(label, active: active) }

    // MARK: Upcoming

    /// Two weeks from this Monday: today lilac with NOW, days with episodes tinted with a dot, past days dimmed.
    private func monthCard(_ items: [UpcomingSchedule.Item]) -> some View {
        var calendar = DiaryDate.calendar(); calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: store.now)
        let monday = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        var counts: [Date: Int] = [:]
        for item in items { counts[calendar.startOfDay(for: item.date), default: 0] += 1 }
        // The same Monday-to-Sunday week as the grid and the "This week" group (not the next seven days).
        let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
        let thisWeek = items.filter { $0.date >= monday && $0.date < nextMonday }.count
        let months = Set(days.map { calendar.component(.month, from: $0) })
        let monthName = months.count > 1
            ? (days.first?.formatted(.dateTime.month(.wide)) ?? "") + " – " + (days.last?.formatted(.dateTime.month(.wide)) ?? "")
            : today.formatted(.dateTime.month(.wide))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(monthName).font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text("\(items.count)").foregroundStyle(HomeStyle.chipText).bold()
                    Text("upcoming ·").foregroundStyle(HomeStyle.secondary)
                    Text("\(thisWeek)").foregroundStyle(HomeStyle.chipText).bold()
                    Text("this week").foregroundStyle(HomeStyle.secondary)
                }.font(.system(size: 13)).lineLimit(1).monospacedDigit()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                }
                ForEach(days, id: \.self) { day in dayCell(day, today: today, count: counts[day] ?? 0) }
            }
        }.padding(16).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
    private func dayCell(_ day: Date, today: Date, count: Int) -> some View {
        let isToday = day == today, past = day < today
        let selected = selectedDate == day
        return Button { withAnimation(.snappy) { selectedDate = selected ? nil : day } } label: {
            VStack(spacing: 2) {
                Text(day, format: .dateTime.day()).font(.system(size: 16, weight: count > 0 || isToday ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(isToday ? ThemeStore.current.accentInk : count > 0 ? HomeStyle.primary : HomeStyle.secondary.opacity(past ? 0.45 : 1))
                if isToday { Text("NOW").font(.system(size: 8, weight: .heavy)).foregroundStyle(ThemeStore.current.accentInk) }
                else { Circle().fill(count > 0 ? HomeStyle.chipText : .clear).frame(width: 4, height: 4) }
            }.frame(maxWidth: .infinity).frame(height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12).fill(isToday
                        ? AnyShapeStyle(LinearGradient(colors: [ThemeStore.current.accentTop, ThemeStore.current.accentBottom], startPoint: .top, endPoint: .bottom))
                        : count > 0 ? AnyShapeStyle(HomeStyle.chip) : AnyShapeStyle(Color.primary.opacity(past ? 0.02 : 0.05)))
                }
                .overlay { if selected { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent, lineWidth: 1.5) } }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(count == 0 && !selected)
            .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted) + ", " + count.counted("episode", "episodes"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func upcomingList(_ items: [UpcomingSchedule.Item]) -> some View {
        let calendar = DiaryDate.calendar()
        let shown = selectedDate.map { day in items.filter { calendar.isDate($0.date, inSameDayAs: day) } } ?? items
        ForEach(weekGroups(shown), id: \.label) { group in
            LazyVStack(alignment: .leading, spacing: 16) {
                heading(group.label, group.items.count)
                ForEach(group.items) { item in upcomingRow(item) }
            }
        }
        if shown.isEmpty { empty("No upcoming \(kindWord) air dates in your library for the next \(upcomingDays) days.") }
    }
    private var kindWord: String { category == .all ? "anime or show" : category.rawValue.lowercased() }
    private func heading(_ label: String, _ count: Int) -> some View { CalendarStyle.heading(label, count) }
    private func away(_ days: Int) -> String { CalendarStyle.away(days) }
    private func episodeLine(_ item: UpcomingSchedule.Item) -> String { item.title.categoryName + " · S\(item.episode.season) E\(item.episode.number)" }

    /// The episode's day as TMDB gives it (the network's own day).
    private func airDay(_ item: UpcomingSchedule.Item) -> String { item.episode.airedOn ?? DiaryDate.day(item.date) }
    /// When it airs: Trakt's or TVmaze's exact time, else TMDB's day alone.
    private func airTime(_ item: UpcomingSchedule.Item) -> Date? {
        EpisodeAirTimes.shared.time(tmdb: item.title.tmdbId, season: item.episode.season, number: item.episode.number, day: airDay(item))
    }
    private func loadAirTime(_ item: UpcomingSchedule.Item) async {
        await EpisodeAirTimes.shared.load(tmdb: item.title.tmdbId, season: item.episode.season, number: item.episode.number, day: airDay(item), store: store)
    }
    /// "Sat 15 Nov · 9:30 PM" in your own time zone (an episode can air on another day here than on
    /// its network's), and how many days away that is.
    private func when(_ item: UpcomingSchedule.Item) -> (text: String, away: Int) {
        let dayFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        guard let at = airTime(item) else { return (item.date.formatted(dayFormat), item.daysAway) }
        let calendar = DiaryDate.calendar()
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: store.now), to: calendar.startOfDay(for: at)).day ?? item.daysAway
        return (at.formatted(dayFormat) + " · " + at.formatted(date: .omitted, time: .shortened), days)
    }
    private func upcomingRow(_ item: UpcomingSchedule.Item) -> some View {
        let summary = hideSpoilers ? item.title.overview : (item.episode.overview.isEmpty ? item.title.overview : item.episode.overview)
        let when = when(item)
        return HStack(alignment: .top, spacing: 14) {
            NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) {
                CalendarStyle.row(poster: item.title.poster, name: item.title.name, when: when.text, line: episodeLine(item)) {
                    if let score = item.title.communityScore, score > 0 { scoreBadge(score) }
                    CalendarStyle.badge(away(when.away))
                } extra: {
                    if !summary.isEmpty { Text(summary).font(.system(size: 13)).foregroundStyle(Color(themed: "#a9a3b5")).lineLimit(2).multilineTextAlignment(.leading) }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("calendar-row-" + item.id)
            if item.daysAway <= 0 {
                Button { Task { await store.recordViewing(item.title, episode: item.episode, watchedAt: store.now) } } label: {
                    DiaryIcon(name: "check", size: 18).foregroundStyle(theme.accent).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.writesBlocked).accessibilityLabel("Mark watched")
            }
        }.task(id: item.id) { await loadAirTime(item) }
    }
    private func scoreBadge(_ score: Double) -> some View {
        HStack(spacing: 3) { Image(systemName: "star.fill").font(.system(size: 9)); Text(score.formatted(.number.precision(.fractionLength(1)))) }
            .font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.chipText)
            .padding(.horizontal, 8).frame(height: 22).background(HomeStyle.chip, in: Capsule())
    }
    private func badge(_ text: String, strong: Bool = false) -> some View { CalendarStyle.badge(text, strong: strong) }
    private func poster(_ title: MediaTitle) -> some View { CalendarStyle.poster(title.poster, name: title.name) }

    private struct WeekGroup { let label: String; let items: [UpcomingSchedule.Item] }
    /// This week, next week, then by week, in date order.
    private func weekGroups(_ items: [UpcomingSchedule.Item]) -> [WeekGroup] {
        var calendar = DiaryDate.calendar(); calendar.firstWeekday = 2
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: store.now)?.start ?? store.now
        var groups: [Int: [UpcomingSchedule.Item]] = [:]
        for item in items {
            let start = calendar.dateInterval(of: .weekOfYear, for: item.date)?.start ?? item.date
            groups[Int((start.timeIntervalSince(thisWeek) / (7 * 86_400)).rounded()), default: []].append(item)
        }
        func label(_ offset: Int) -> String { offset == 0 ? "This week" : offset == 1 ? "Next week" : "In \(offset) weeks" }
        return groups.keys.sorted().map { WeekGroup(label: label($0), items: (groups[$0] ?? []).sorted { $0.date < $1.date }) }
    }

    // MARK: Catch-up

    private struct Behind: Identifiable {
        let title: MediaTitle
        let items: [UpcomingSchedule.Item]
        var id: String { title.id }
    }
    private func behind(_ items: [UpcomingSchedule.Item]) -> [Behind] {
        var order: [String] = [], byTitle: [String: [UpcomingSchedule.Item]] = [:]
        for item in items.sorted(by: { $0.date > $1.date }) {
            if byTitle[item.title.id] == nil { order.append(item.title.id) }
            byTitle[item.title.id, default: []].append(item)
        }
        return order.compactMap { id in
            guard let list = byTitle[id], let first = list.first else { return nil }
            return Behind(title: first.title, items: list.sorted { ($0.episode.season, $0.episode.number) < ($1.episode.season, $1.episode.number) })
        }
    }
    private func catchupCard(_ items: [UpcomingSchedule.Item]) -> some View {
        let shows = Set(items.map(\.title.id)).count
        return HStack(spacing: 14) {
            Text("\(items.count)").font(.system(size: 44, weight: .bold)).foregroundStyle(HomeStyle.chipText).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(items.count == 1 ? "episode to catch up" : "episodes to catch up").font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).minimumScaleFactor(0.85)
                Text("Across " + shows.counted("show", "shows") + " · aired in the last \(catchupDays) days").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button { confirmMarkAll = true } label: {
                Group { if marking { ProgressView().controlSize(.small) } else { Text("Mark all") } }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    .padding(.horizontal, 16).frame(height: 40).pillSurface(border: nil)
                    .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
            }.buttonStyle(.springPress).disabled(marking || store.writesBlocked).accessibilityIdentifier("calendar-mark-all")
                .confirmationDialog("Mark \(items.count.counted("episode", "episodes")) watched?", isPresented: $confirmMarkAll, titleVisibility: .visible) {
                    Button("Mark all watched") { markAll(items) }
                } message: { Text("Every episode that aired in the last \(catchupDays) days and isn't watched yet, dated today.") }
        }.padding(16).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
    @ViewBuilder private func catchupList(_ items: [UpcomingSchedule.Item]) -> some View {
        let groups = behind(items)
        if !groups.isEmpty {
            LazyVStack(alignment: .leading, spacing: 16) {
                heading("Behind", groups.count)
                ForEach(groups) { group in behindRow(group) }
            }
        } else {
            empty("You're caught up: no unwatched \(kindWord) episodes aired in the last \(catchupDays) days.")
        }
    }
    private func behindRow(_ group: Behind) -> some View {
        let first = group.items.first!, last = group.items.last!
        let dates = group.items.map(\.date)
        let start = dates.min() ?? first.date, end = dates.max() ?? first.date
        let sameDay = DiaryDate.calendar().isDate(start, inSameDayAs: end)
        let airedText = "Aired " + (sameDay ? end.formatted(.dateTime.day().month(.abbreviated))
            : start.formatted(.dateTime.day()) + " – " + end.formatted(.dateTime.day().month(.abbreviated)))
        let span = group.items.count == 1 ? "S\(first.episode.season) E\(first.episode.number)"
            : first.episode.season == last.episode.season ? "S\(first.episode.season) E\(first.episode.number) – E\(last.episode.number)"
            : "S\(first.episode.season) E\(first.episode.number) – S\(last.episode.season) E\(last.episode.number)"
        let progress = watchedProgress(group.title)
        return HStack(alignment: .top, spacing: 14) {
            NavigationLink(value: SavedTitleRoute(id: group.title.id, season: first.episode.season)) { poster(group.title) }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(airedText).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    badge("\(group.items.count) behind", strong: true)
                }
                NavigationLink(value: SavedTitleRoute(id: group.title.id, season: first.episode.season)) {
                    Text(group.title.name).font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.plain)
                Text(group.title.categoryName + " · " + span).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText).lineLimit(1)
                if progress.aired > 0 {
                    GeometryReader { proxy in
                        Capsule().fill(Color.primary.opacity(0.1)).overlay(alignment: .leading) {
                            Capsule().fill(LinearGradient(colors: [ThemeStore.current.accentTop, ThemeStore.current.accentBottom], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * CGFloat(progress.watched) / CGFloat(progress.aired))
                        }
                    }.frame(height: 4).padding(.top, 4)
                }
                HStack(spacing: 8) {
                    Text("\(progress.watched) of \(progress.aired) watched").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1).monospacedDigit()
                    Spacer(minLength: 4)
                    Button { Task { await store.recordViewing(group.title, episode: first.episode, watchedAt: store.now) } } label: {
                        Text("Watch E\(first.episode.number)").font(.system(size: 14, weight: .bold)).foregroundStyle(WatchStyle.ink).lineLimit(1)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(WatchStyle.fill, in: Capsule())
                            .frame(minHeight: 44).contentShape(Capsule())
                    }.buttonStyle(.springPress).disabled(store.writesBlocked || marking)
                        .accessibilityLabel("Mark S\(first.episode.season) E\(first.episode.number) of \(group.title.name) watched")
                        .accessibilityIdentifier("calendar-watch-" + group.title.id)
                }.padding(.top, 2)
            }
        }
    }
    /// Episodes of the show that have aired, and how many of those you've watched.
    private func watchedProgress(_ title: MediaTitle) -> (watched: Int, aired: Int) {
        let today = DiaryDate.day(store.now)
        let watched = Set(store.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
        let aired = store.workspace.episodes.filter { $0.titleId == title.id && $0.season > 0 && $0.skipped != true && ($0.airedOn.map { $0 <= today } ?? false) }
        return (aired.filter { watched.contains($0.id) }.count, aired.count)
    }
    private func markAll(_ items: [UpcomingSchedule.Item]) {
        guard !marking else { return }
        marking = true
        Task {
            for item in items.sorted(by: { ($0.title.id, $0.episode.season, $0.episode.number) < ($1.title.id, $1.episode.season, $1.episode.number) }) {
                await store.recordViewing(item.title, episode: item.episode, watchedAt: store.now)
            }
            marking = false
        }
    }

    // MARK: All

    @ViewBuilder private func allList(upcoming: [UpcomingSchedule.Item], aired: [UpcomingSchedule.Item]) -> some View {
        if !upcoming.isEmpty {
            LazyVStack(alignment: .leading, spacing: 16) {
                heading("Upcoming", upcoming.count)
                ForEach(upcoming) { item in compactRow(item, badge: away(item.daysAway), strong: false) }
            }
        }
        if !aired.isEmpty {
            LazyVStack(alignment: .leading, spacing: 16) {
                heading("Aired", aired.count)
                ForEach(aired) { item in compactRow(item, badge: "Behind", strong: true) }
            }
        }
        if upcoming.isEmpty && aired.isEmpty { empty("No \(kindWord) episodes to show with these filters.") }
    }
    private func compactRow(_ item: UpcomingSchedule.Item, badge text: String, strong: Bool) -> some View {
        NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) {
            CalendarStyle.row(poster: item.title.poster, name: item.title.name, when: when(item).text, line: episodeLine(item)) {
                badge(text, strong: strong)
            } extra: { EmptyView() }
        }.buttonStyle(.plain).accessibilityIdentifier("calendar-row-" + item.id)
            .task(id: item.id) { await loadAirTime(item) }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
    private func syncDates() {
        guard !syncingDates else { return }
        syncingDates = true
        Task {
            let activeSeries = store.activeTitles.filter { $0.isSeries && ($0.status == "watching" || $0.status == "planned") }.prefix(10)
            for series in activeSeries { await store.refreshTitleMetadata(series) }
            syncingDates = false
        }
    }
}

/// The calendar's pieces, shared by every tab (Upcoming, Missed, Following and Global look alike:
/// owner's request): filter pills, section headings, badges, posters and the row layout.
@MainActor enum CalendarStyle {
    /// One poster size across the calendar.
    static let posterWidth: CGFloat = 72
    static func pill(_ label: String, active: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 120)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).opacity(0.8)
        }.font(.system(size: 14, weight: .semibold)).fixedSize()
            .foregroundStyle(active ? HomeStyle.chipText : Color(themed: "#e6e1ee"))
            .padding(.horizontal, 14).frame(height: 38)
            .pillSurface(HomeStyle.card, chosen: active ? HomeStyle.chip : nil)
            .frame(minHeight: 44).contentShape(Capsule())
    }
    /// "This week (12)", "Today (8)".
    static func heading(_ label: String, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Color(themed: "#c5c0cf"))
            Text("(\(count))").foregroundStyle(HomeStyle.primary)
        }.font(.system(size: 20, weight: .bold)).padding(.top, 4)
    }
    static func badge(_ text: String, strong: Bool = false) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(strong ? HomeStyle.chipText : HomeStyle.primary).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 22)
            .background(strong ? HomeStyle.chip : Color.primary.opacity(0.08), in: Capsule())
    }
    static func poster(_ path: String?, name: String) -> some View {
        Artwork(path: path, title: name, initialsOnly: false).frame(width: posterWidth, height: posterWidth * 1.4)
            .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
    /// "Today", "Tomorrow", "In 6d", "2d ago".
    static func away(_ days: Int) -> String { days == 0 ? "Today" : days == 1 ? "Tomorrow" : days < 0 ? "\(-days)d ago" : "In \(days)d" }
    /// Every row: the poster; when it airs on top with its badges on the right; the name; the
    /// episode line in lilac; then anything a tab adds (a summary, progress).
    static func row<Badges: View, Extra: View>(poster path: String?, name: String, when: String, line: String,
                                              @ViewBuilder badges: () -> Badges, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            poster(path, name: name)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text(when).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    badges()
                }
                Text(name).font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                Text(line).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText).lineLimit(1)
                extra()
            }
        }.contentShape(Rectangle())
    }
}

/// Genres: the genres of the shows on the calendar as chips; pick any, then Apply.
struct CalendarGenreSheet: View {
    let names: [String]
    @Binding var chosen: Set<String>
    @State private var pending: Set<String> = []
    /// The chips' height, so a short list opens a short sheet (no empty half screen).
    @State private var chipsHeight: CGFloat = 120
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Genres").font(.system(size: 24, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.dateChipText)
                        .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
                        .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                }.buttonStyle(.plain).accessibilityLabel("Close")
            }.padding(.horizontal, 20).padding(.top, 22)
            ScrollView {
                if names.isEmpty {
                    Text("None of the shows on your calendar have genres yet.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    InlineFlowLayout {
                        ForEach(names, id: \.self) { name in
                            let on = pending.contains(name)
                            Button { withAnimation(.snappy(duration: 0.2)) { if on { pending.remove(name) } else { pending.insert(name) } } } label: {
                                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    .foregroundStyle(on ? HomeStyle.chipText : Color(themed: "#e6e1ee"))
                                    .padding(.horizontal, 15).frame(height: 40)
                                    .background(on ? HomeStyle.chip : HomeStyle.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(on ? HomeStyle.chipText.opacity(0.35) : HomeStyle.dateChipBorder, lineWidth: 1))
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("calendar-genre-" + name)
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 14)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, height in chipsHeight = height }
            HStack(spacing: 10) {
                Button("Clear") { withAnimation(.snappy) { pending = [] } }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    .frame(width: 110, height: 52).pillSurface(border: nil)
                    .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    .buttonStyle(.plain).disabled(pending.isEmpty).opacity(pending.isEmpty ? 0.5 : 1)
                Button { chosen = pending; dismiss() } label: {
                    Text(pending.isEmpty ? "Show all genres" : "Apply · " + pending.count.counted("genre", "genres")).lineLimit(1)
                }.buttonStyle(SettingsPrimaryButtonStyle()).accessibilityIdentifier("calendar-genres-apply")
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
        }.presentationDetents([.height(min(640, chipsHeight + 180)), .large]).presentationDragIndicator(.visible).presentationBackground(Color(themed: "#111116"))
            .onAppear { pending = chosen }
    }
}
