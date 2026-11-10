import SwiftUI
import PhotosUI
import TwilDiaryCore

struct PersonalAvatar: View {
    var profile = PersonalProfile.shared
    var size: CGFloat = 52
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        Group {
            if profile.usesPhoto, let image = profile.photo { Image(uiImage: image).resizable().scaledToFill() }
            else if let character = profile.character { Artwork(path: character.image, title: character.name) }
            else { Text(String(profile.name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.accent.opacity(0.2)) }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

/// Your counts on Trakt: followers, following, friends, when you joined, ratings, collection,
/// watchlist and lists. Read with your Trakt sign-in; nothing is written.
struct TraktProfileSummary: Equatable {
    var joined: Date?
    var followers = 0, following = 0, friends = 0
    var collected = 0, watchlist = 0, lists = 0
    @MainActor static func load(store: DiaryStore) async -> TraktProfileSummary? {
        guard let client = try? await TraktDirectStore.shared.client(store: store) else { return nil }
        func json(_ path: String, _ query: [String: String] = [:]) async -> Any? {
            guard let reply = try? await client.get(path, query: query) else { return nil }
            return try? JSONSerialization.jsonObject(with: reply.data)
        }
        var value = TraktProfileSummary()
        if let user = await json("/users/me", ["extended": "full"]) as? [String: Any], let joined = user["joined_at"] as? String { value.joined = DiaryDate.parse(joined) }
        if let stats = await json("/users/me/stats") as? [String: Any] {
            let network = stats["network"] as? [String: Any]
            value.followers = network?["followers"] as? Int ?? 0
            value.following = network?["following"] as? Int ?? 0
            value.friends = network?["friends"] as? Int ?? 0
            value.collected = ((stats["movies"] as? [String: Any])?["collected"] as? Int ?? 0) + ((stats["shows"] as? [String: Any])?["collected"] as? Int ?? 0)
        }
        // One item per page: the page count is the number of items.
        if let reply = try? await client.get("/sync/watchlist", query: ["page": "1", "limit": "1"]) { value.watchlist = reply.pageCount }
        if let lists = await json("/users/me/lists") as? [Any] { value.lists = lists.count }
        return value
    }
}

struct MilestonesRoute: Hashable {}

/// A milestone badge: a hexagon in its colour with its symbol, and a tab under it.
struct MilestoneBadge: View {
    let milestone: ProfileMilestone
    var size: CGFloat = 54
    var body: some View {
        let colour = Color(webHex: milestone.colour)
        ZStack {
            Hexagon().fill(colour.opacity(milestone.earned ? 0.22 : 0.06))
            Hexagon().stroke(colour.opacity(milestone.earned ? 1 : 0.4), style: StrokeStyle(lineWidth: 2.5, dash: milestone.earned ? [] : [4, 3]))
            Image(systemName: milestone.symbol).font(.system(size: size * 0.32, weight: .medium)).foregroundStyle(colour.opacity(milestone.earned ? 1 : 0.55))
        }.frame(width: size, height: size * 1.08)
            .overlay(alignment: .bottom) {
                if milestone.earned { Capsule().fill(colour).frame(width: size * 0.55, height: size * 0.18).offset(y: size * 0.07) }
            }
            .accessibilityHidden(true)
    }
}
struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w / 2, y: 0))
        path.addLine(to: CGPoint(x: w, y: h * 0.25)); path.addLine(to: CGPoint(x: w, y: h * 0.75))
        path.addLine(to: CGPoint(x: w / 2, y: h)); path.addLine(to: CGPoint(x: 0, y: h * 0.75)); path.addLine(to: CGPoint(x: 0, y: h * 0.25))
        path.closeSubpath()
        return path
    }
}

struct PersonalProfileView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("profileUsername") private var username = ""
    private var profile = PersonalProfile.shared
    @State private var characters: [ProfileAvatarChoice] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showAvatarPicker = false
    @State private var editing = false
    @State private var trakt: TraktProfileSummary?
    /// The Statistics tab a card opens (Statistics reads the same key).
    @AppStorage("stats.tab") private var statsTab = StatsView.Tab.overview
    var body: some View {
        let milestones = ProfileMilestone.make(store.workspace, now: store.now)
        let insights = StatsInsights(workspace: store.workspace, now: store.now)
        let overview = StatsOverview(workspace: store.workspace, period: .week, now: store.now)
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 14) {
                header
                statTiles(insights)
                HStack(alignment: .top, spacing: 12) { streakTile(overview.streaks); weekTile }
                NavigationLink(value: AppDestination.statistics) {
                    HStack(spacing: 14) {
                        Image(systemName: "chart.bar.fill").font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 48, height: 48).background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Statistics").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                            Text("Watch time, habits, taste and more").font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        Spacer(); DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary)
                    }.padding(16).background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.accent.opacity(0.25))).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("profile-statistics")
                milestonesCard(milestones)
                onThisDay
                ratingsCard(insights)
                historyCard
                collectionTiles
            }.padding(.horizontal, 16).padding(.bottom, 28)
        }.diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: "\(profile.name) on TwilDiary · \(insights.episodes.formatted()) episodes, \(insights.movies.formatted()) movies, \(longDuration(insights.totalMinutes)) watched") {
                        Image(systemName: "square.and.arrow.up")
                    }.accessibilityLabel("Share your profile")
                    NavigationLink(value: AppDestination.appearance) { Image(systemName: "sun.max") }.accessibilityLabel("Appearance")
                }
            }
            .sheet(isPresented: $showAvatarPicker) { NavigationStack { AvatarPickerView(characters: characters) }.presentationDragIndicator(.visible) }
            .sheet(isPresented: $editing) { NavigationStack { EditProfileView(characters: characters) }.presentationDragIndicator(.visible) }
            .task { await loadCharacters() }
            .task(id: store.sessionRevision) { trakt = await TraktProfileSummary.load(store: store) }
    }

    private var handle: String {
        if !username.isEmpty { return "@" + username.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
        if let name = store.traktController.status?.username, !name.isEmpty { return "@" + name }
        return ""
    }
    private var header: some View {
        let art = store.workspace.activeEvents.max { ($0.watchedAt ?? $0.recordedAt) < ($1.watchedAt ?? $1.recordedAt) }.flatMap { store.title($0.titleId) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                Button { showAvatarPicker = true } label: {
                    PersonalAvatar(size: 100).padding(3).overlay(Circle().strokeBorder(theme.accent, lineWidth: 2.5))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill").font(.system(size: 12)).foregroundStyle(.white).frame(width: 30, height: 30).background(.black.opacity(0.75), in: Circle())
                        }
                }.buttonStyle(.plain).accessibilityLabel("Change profile picture").accessibilityIdentifier("profile-avatar")
                Spacer()
                Button { editing = true } label: {
                    Text("Edit profile").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 20).frame(height: 46)
                        .background(.white.opacity(0.1), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                }.buttonStyle(.plain).accessibilityIdentifier("profile-edit-name")
            }
            Text(profile.name).font(.system(size: 30, weight: .bold)).tracking(-0.8).foregroundStyle(.white).padding(.top, 6)
            if !handle.isEmpty { Text(handle).font(.system(size: 16)).foregroundStyle(.secondary) }
            if let trakt {
                if let joined = trakt.joined {
                    HStack(spacing: 6) { Image(systemName: "calendar"); Text("Joined " + joined.formatted(.dateTime.month(.wide).year())) }
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
        }.padding(.top, 70)
            .background(alignment: .top) {
                Artwork(path: art?.backdrop ?? art?.poster, title: art?.name ?? "")
                    .frame(height: 230).clipped()
                    .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black.opacity(0.05), location: 0.3),
                                                    .init(color: .black.opacity(0.55), location: 0.7), .init(color: .black, location: 1)],
                                            startPoint: .top, endPoint: .bottom))
                    .padding(.horizontal, -16).offset(y: -60).allowsHitTesting(false).accessibilityHidden(true)
            }
    }
    private func count(_ value: Int, _ label: String) -> some View {
        HStack(spacing: 4) { Text(value.formatted()).bold().foregroundStyle(.white); Text(label).foregroundStyle(.secondary) }.font(.system(size: 15))
            .accessibilityElement(children: .combine)
    }
    private func statTiles(_ insights: StatsInsights) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Button { openStats(.overview) } label: { tile("play.rectangle", "Episodes", insights.episodes.formatted()) }.buttonStyle(.plain)
            Button { openStats(.overview) } label: { tile("clock", "Show time", longDuration(insights.showMinutes)) }.buttonStyle(.plain)
            Button { openStats(.taste) } label: { tile("film", "Movies", insights.movies.formatted()) }.buttonStyle(.plain)
            Button { openStats(.overview) } label: { tile("clock", "Movie time", longDuration(insights.movieMinutes)) }.buttonStyle(.plain)
        }
    }
    private func tile(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 13)).foregroundStyle(theme.accent); Text(label).font(.system(size: 14)).foregroundStyle(.secondary) }
            Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 20).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    /// Opens Statistics on a tab.
    private func openStats(_ tab: StatsView.Tab) {
        statsTab = tab
        router.paths[router.selectedTab, default: NavigationPath()].append(AppDestination.statistics)
    }
    private func streakTile(_ streaks: StatsOverview.Streaks) -> some View {
        let week = Array(streaks.heatmap.suffix(7))
        return Button { openStats(.habits) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "flame").font(.system(size: 16)).foregroundStyle(theme.accent).frame(width: 36, height: 36).background(theme.accent.opacity(0.16), in: Circle())
                    Spacer(); DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(streaks.current)").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    Text("day streak").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: 3) {
                            Circle().fill(day.count > 0 ? theme.accent : .white.opacity(0.12)).frame(width: 14, height: 14)
                                .overlay { if day.date == DiaryDate.day(store.now) { Circle().strokeBorder(theme.accent, lineWidth: 1.5).padding(-2) } }
                            Text(Self.weekdayLetter(day.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 20)
        }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityLabel("\(streaks.current) day streak")
    }
    /// "M" for a "2026-11-09" day key: the dots are the last seven days, so each says its own weekday.
    static func weekdayLetter(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let calendar = DiaryDate.calendar()
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return "" }
        return ["S", "M", "T", "W", "T", "F", "S"][calendar.component(.weekday, from: date) - 1]
    }
    /// This week (Monday to Sunday): each day's watch time from its titles' runtimes.
    private var week: [(day: Date, minutes: Int)] {
        let calendar = DiaryDate.calendar()
        let today = calendar.startOfDay(for: store.now)
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: today) + 5) % 7), to: today) ?? today
        var minutes: [Date: Int] = [:]
        for event in store.workspace.activeEvents {
            guard let date = DiaryDate.parse(event.watchedAt), date >= monday, let title = store.title(event.titleId) else { continue }
            minutes[calendar.startOfDay(for: date), default: 0] += max(0, title.runtimeMinutes ?? 0)
        }
        return (0..<7).compactMap { offset in calendar.date(byAdding: .day, value: offset, to: monday).map { ($0, minutes[$0] ?? 0) } }
    }
    private var weekTile: some View {
        let days = week, today = DiaryDate.calendar().startOfDay(for: store.now)
        let most = max(1, days.map(\.minutes).max() ?? 1)
        return Button { openStats(.overview) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("This week").font(.system(size: 14)).foregroundStyle(.secondary)
                Text(DiaryDate.duration(days.reduce(0) { $0 + $1.minutes })).font(.system(size: 26, weight: .bold)).foregroundStyle(theme.accent).lineLimit(1).minimumScaleFactor(0.7)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3).fill(item.minutes > 0 ? theme.accent : .white.opacity(0.12))
                                .frame(height: item.minutes > 0 ? max(6, 48 * CGFloat(item.minutes) / CGFloat(most)) : 3)
                            Text(["M", "T", "W", "T", "F", "S", "S"][index]).font(.system(size: 10, weight: item.day == today ? .bold : .regular))
                                .foregroundStyle(item.day == today ? theme.accent : .secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 66, alignment: .bottom)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityIdentifier("profile-this-week")
    }
    private func milestonesCard(_ milestones: [ProfileMilestone]) -> some View {
        let earned = milestones.filter(\.earned)
        return VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: MilestonesRoute()) {
                HStack {
                    Text("Milestones").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 3) { Text("\(earned.count) earned"); DiaryIcon(name: "chevron-right", size: 12) }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#ff8a6a"))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("profile-milestones").accessibilityLabel("Milestones, \(earned.count) earned")
            // Every badge, sideways; a tap opens Milestones.
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach((earned.isEmpty ? Array(milestones.prefix(12)) : earned)) { milestone in
                        NavigationLink(value: MilestonesRoute()) { MilestoneBadge(milestone: milestone, size: 46) }.buttonStyle(.springPress)
                    }
                }.padding(.vertical, 4).padding(.horizontal, 18)
            }.scrollIndicators(.hidden).padding(.horizontal, -18)
        }.padding(18).diaryPanel(padding: 0, radius: 22)
    }
    /// What you watched on this day in earlier years.
    private var onThisDay: some View {
        let calendar = DiaryDate.calendar()
        let today = calendar.dateComponents([.month, .day, .year], from: store.now)
        let past = store.workspace.activeEvents.compactMap { event -> (Date, MediaTitle)? in
            guard let date = DiaryDate.parse(event.watchedAt), let title = store.title(event.titleId) else { return nil }
            let parts = calendar.dateComponents([.month, .day, .year], from: date)
            return parts.month == today.month && parts.day == today.day && parts.year != today.year ? (date, title) : nil
        }.sorted { $0.0 > $1.0 }
        return NavigationLink(value: HistoryRoute(day: past.first?.0)) { HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(store.now.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent)
                Text(store.now.formatted(.dateTime.day())).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
            }.frame(width: 56, height: 60).background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("On this day").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                if let first = past.first {
                    let years = (today.year ?? 0) - calendar.component(.year, from: first.0)
                    Text("\(years.counted("year", "years")) ago you watched \(first.1.name)" + (past.count > 1 ? " and \(past.count - 1) more." : "."))
                        .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Nothing happened today.").font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !past.isEmpty { DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary) }
        }.padding(16).diaryPanel(padding: 0, radius: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).allowsHitTesting(!past.isEmpty).accessibilityElement(children: .combine).accessibilityIdentifier("profile-on-this-day")
    }
    private func ratingsCard(_ insights: StatsInsights) -> some View {
        let most = max(1, insights.ratingCounts.max() ?? 1)
        let top = insights.ratingCounts.firstIndex(of: most)
        return Button { openStats(.taste) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Ratings").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 3) { Text("\(insights.ratedCount) total"); DiaryIcon(name: "chevron-right", size: 12) }.font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<10, id: \.self) { index in
                        let count = insights.ratingCounts[index]
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 5).fill(index == top && count > 0 ? theme.accent : theme.accent.opacity(count > 0 ? 0.5 : 0.12))
                                .frame(height: count > 0 ? max(6, 90 * CGFloat(count) / CGFloat(most)) : 3)
                            Text("\(index + 1)").font(.system(size: 12, weight: index == top ? .bold : .regular)).foregroundStyle(index == top ? .white : .secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 116, alignment: .bottom)
            }.padding(18).diaryPanel(padding: 0, radius: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Ratings, \(insights.ratedCount) total")
    }
    private var historyCard: some View {
        var seen = Set<String>()
        let recent = store.workspace.activeEvents.sorted { ($0.watchedAt ?? $0.recordedAt) > ($1.watchedAt ?? $1.recordedAt) }
            .compactMap { store.title($0.titleId) }.filter { seen.insert($0.id).inserted }.prefix(6)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Watch history").font(.system(size: 22, weight: .bold))
                Spacer()
                SeeAllLink(value: AppDestination.history, identifier: "profile-history-all")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(recent)) { title in
                        NavigationLink(value: title.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(width: 116, height: 172).clipShape(RoundedRectangle(cornerRadius: 14))
                                Text(title.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white).lineLimit(2).frame(width: 116, alignment: .leading)
                            }
                        }.buttonStyle(.springPress)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
    private var collectionTiles: some View {
        let favourites = FavouritesStore.shared.items.count
        let planned = store.workspace.activeTitles.filter { $0.status == "planned" }.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Button { router.library("planned") } label: { collection("bookmark", "Watchlist", (trakt?.watchlist ?? planned).counted("title", "titles")) }.buttonStyle(.plain)
            Button { router.library("all") } label: { collection("archivebox", "Collection", (trakt?.collected ?? 0).counted("title", "titles")) }.buttonStyle(.plain)
            NavigationLink(value: AppDestination.favourites) { collection("heart", "Favourites", favourites.counted("title", "titles")) }.buttonStyle(.plain)
            NavigationLink(value: AppDestination.canvas) { collection("list.bullet", "Lists", (trakt?.lists ?? 0).counted("list", "lists")) }.buttonStyle(.plain)
        }
    }
    private func collection(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(theme.accent).frame(width: 44, height: 44).background(theme.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 20).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
    private func loadCharacters() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            #if DEBUG
            if store.isPreview { characters = [ProfileAvatarChoice(id: 176754, name: "Frieren", image: "/demo/frieren.jpg"), ProfileAvatarChoice(id: 138100, name: "Anya", image: nil)]; return }
            #endif
            let values = try await AniListClient.shared.popularAvatars()
            guard !Task.isCancelled else { return }; characters = values
        } catch { if !Task.isCancelled { self.error = "Characters are unavailable. You can still choose a custom photo." } }
    }
}

/// Milestones: how many you've earned, every earned badge, and the next one with its progress.
struct MilestonesView: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        let milestones = ProfileMilestone.make(store.workspace, now: store.now)
        let earned = milestones.filter(\.earned)
        let next = milestones.filter { !$0.earned }.max { Double($0.progress) / Double(max(1, $0.target)) < Double($1.progress) / Double(max(1, $1.target)) }
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    Text("\(earned.count)").font(.system(size: 52, weight: .heavy)).foregroundStyle(Color(webHex: "#ffc83d"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("milestones earned").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        if let next { Text("Next up: " + next.title + " · " + next.progressLabel).font(.system(size: 14)).foregroundStyle(.secondary) }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Earned").font(.system(size: 22, weight: .bold))
                    if earned.isEmpty { Text("Log a watch to earn your first milestone.").font(.subheadline).foregroundStyle(.secondary) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4), spacing: 22) {
                        ForEach(earned) { item in
                            VStack(spacing: 10) {
                                MilestoneBadge(milestone: item, size: 52)
                                Text(item.title).font(.system(size: 12.5, weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Up next").font(.system(size: 22, weight: .bold))
                    ForEach(milestones.filter { !$0.earned }.prefix(6)) { item in
                        HStack(spacing: 14) {
                            MilestoneBadge(milestone: item, size: 40)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(item.title).font(.system(size: 16, weight: .semibold)); Spacer(); Text(item.progressLabel).font(.system(size: 13)).foregroundStyle(.secondary) }
                                Capsule().fill(.white.opacity(0.1)).frame(height: 8).overlay(alignment: .leading) {
                                    GeometryReader { proxy in Capsule().fill(Color(webHex: item.colour)).frame(width: proxy.size.width * min(1, Double(item.progress) / Double(max(1, item.target)))) }
                                }
                            }
                        }.accessibilityElement(children: .combine)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
            }.padding(.horizontal, 16).padding(.bottom, 28)
        }.diaryScreenBackground().diaryPageNavigation("Milestones")
    }
}

/// Edit profile: picture (a character or your own photo), name and username. Saved on this iPhone.
struct EditProfileView: View {
    let characters: [ProfileAvatarChoice]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("profileUsername") private var username = ""
    @State private var name = PersonalProfile.shared.name
    @State private var handle = ""
    @State private var selection: PhotosPickerItem?
    @State private var error: String?
    var body: some View {
        EdgeToEdgeScroll {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    PersonalAvatar(size: 120).padding(4).overlay(Circle().strokeBorder(theme.accent, lineWidth: 2.5))
                    Text("Pick a character or use your own photo").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose a character").font(.system(size: 22, weight: .bold))
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(characters) { choice in ProfileCharacterAvatarButton(choice: choice, size: 72) { PersonalProfile.shared.select(choice) } }
                        }
                    }.scrollIndicators(.hidden)
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Upload a photo", systemImage: "camera").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50).background(.white.opacity(0.07), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }.accessibilityIdentifier("profile-custom-photo")
                    if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name").font(.system(size: 14)).foregroundStyle(.secondary)
                    TextField("Name", text: $name).textContentType(.name).padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    Text("Username").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 6)
                    TextField("@username", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled().padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }.padding(18).diaryPanel(padding: 0, radius: 22)
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
        }.diaryScreenBackground().navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PersonalProfile.shared.rename(name)
                        username = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ ").union(.whitespacesAndNewlines))
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("profile-save")
                }
            }
            .onAppear { handle = username.isEmpty ? "" : "@" + username }
            .task(id: selection) {
                guard let selection else { return }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                    try PersonalProfile.shared.savePhoto(data)
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
}

private struct AvatarPickerView: View {
    let characters: [ProfileAvatarChoice]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        let fieldColour = theme.field
        EdgeToEdgeScroll {
            VStack(spacing: 22) {
                PersonalAvatar(size: 112)
                PhotosPicker(selection: $selection, matching: .images) {
                    Label("Choose custom photo", systemImage: "photo.badge.plus").frame(maxWidth: .infinity, minHeight: 48).background(fieldColour, in: RoundedRectangle(cornerRadius: 12))
                }.disabled(loading).accessibilityIdentifier("profile-custom-photo")
                if loading { ProgressView("Preparing photo") }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Button("Use initials") { generation = UUID(); PersonalProfile.shared.useInitials(); dismiss() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))], spacing: 20) {
                    ForEach(characters) { choice in
                        ProfileCharacterAvatarButton(choice: choice, size: 72) {
                            generation = UUID(); PersonalProfile.shared.select(choice); dismiss()
                        }
                    }
                }
            }.padding(20)
        }.diaryScreenBackground().navigationTitle("Avatar").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: selection) {
                guard let selection else { return }; let request = UUID(); generation = request; loading = true; error = nil
                defer { if generation == request { loading = false } }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self), !Task.isCancelled, generation == request else { return }
                    try PersonalProfile.shared.savePhoto(data); dismiss()
                } catch { if !Task.isCancelled && generation == request { self.error = error.localizedDescription } }
            }
            .onDisappear { generation = UUID() }
    }
}

/// Explicit accessibility on the control keeps decorative Artwork from hiding
/// the avatar option, and observes selection in each small leaf's own body.
private struct ProfileCharacterAvatarButton: View {
    let choice: ProfileAvatarChoice
    let size: CGFloat
    let choose: () -> Void
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private var profile: PersonalProfile { .shared }
    var body: some View {
        let selected = !profile.usesPhoto && profile.character?.id == choice.id
        Button(action: choose) {
            VStack(spacing: 6) {
                Artwork(path: choice.image, title: choice.name).frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().strokeBorder(selected ? theme.accent : .clear, lineWidth: 3))
                Text(choice.name).font(.caption).lineLimit(2).frame(width: size)
            }.foregroundStyle(.primary)
        }.buttonStyle(.plain)
            .accessibilityRepresentation {
                Button("Use " + choice.name + " as avatar", action: choose)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("profile-character-\(choice.id)")
            }
    }
}
