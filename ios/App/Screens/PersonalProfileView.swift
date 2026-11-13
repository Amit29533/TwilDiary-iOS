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

/// What each milestone is for, and the ladder it climbs (7-day streak, then 30-day streak).
enum MilestoneInfo {
    static func about(_ id: String) -> String {
        switch id {
        case "first-watch": "Log your very first movie or episode."
        case "hundred-titles": "Watch a hundred different movies and shows."
        case "week-streak": "Watch something seven days in a row."
        case "month-streak": "Keep a watching streak going for thirty days."
        case "ten-movies": "Watch ten different movies."
        case "fifty-movies": "Watch fifty different movies."
        case "first-anime": "Watch your first anime."
        case "anime-explorer": "Watch twenty-five different anime."
        case "hundred-hours": "Spend a hundred hours watching."
        case "five-hundred-hours": "Spend five hundred hours watching."
        case "genre-explorer": "Watch titles from five different genres."
        default: "Keep watching to earn it."
        }
    }
    static let ladders: [[String]] = [["first-watch", "hundred-titles"], ["week-streak", "month-streak"], ["ten-movies", "fifty-movies"],
                                      ["first-anime", "anime-explorer"], ["hundred-hours", "five-hundred-hours"], ["genre-explorer"]]
    static func ladder(_ id: String) -> [String] { ladders.first { $0.contains(id) } ?? [id] }
}

/// Tap a badge: it pops in over a dimmed page and spins (its back shows the name and status),
/// with what it's for and how far the next level is. Tap the badge to spin it again.
struct MilestoneDetailView: View {
    let milestone: ProfileMilestone
    let all: [ProfileMilestone]
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var angle = 0.0
    @State private var showsBack = false
    @State private var spinning = false
    @State private var drag: CGFloat = 0
    /// The progress bar fills once the panel has landed (so it never trails behind it).
    @State private var filled = false
    var body: some View {
        let ladder = MilestoneInfo.ladder(milestone.id)
        let level = (ladder.firstIndex(of: milestone.id) ?? 0) + 1
        let next = milestone.earned ? ladder.dropFirst(level).first.flatMap { id in all.first { $0.id == id } } : nil
        let goal = next ?? (milestone.earned ? nil : milestone)
        let colour = Color(webHex: milestone.colour)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.5)).ignoresSafeArea()
                .opacity(shown ? 1 : 0).onTapGesture(perform: dismiss).accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            .frame(width: 44, height: 44).background(.white.opacity(0.1), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("milestone-close")
                }.padding(.horizontal, 20).padding(.top, 8).opacity(shown ? 1 : 0)
                Spacer(minLength: 20)
                ZStack {
                    if showsBack { back(colour).rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0)) }
                    else { MilestoneBadge(milestone: milestone, size: 170).shadow(color: colour.opacity(milestone.earned ? 0.45 : 0), radius: 30) }
                }.frame(width: 200, height: 215)
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                    .scaleEffect(shown ? 1 : 0.35).opacity(shown ? 1 : 0)
                    .contentShape(Rectangle()).onTapGesture { Task { await spin() } }
                    .accessibilityElement().accessibilityLabel(milestone.title + (milestone.earned ? ", earned" : ", " + milestone.progressLabel))
                    .accessibilityHint("Spins the badge").accessibilityAction { Task { await spin() } }
                VStack(spacing: 8) {
                    Text("\(milestone.earned ? "EARNED" : "IN PROGRESS") · LEVEL \(level) OF \(ladder.count)")
                        .font(.system(size: 12, weight: .bold)).tracking(1.2).foregroundStyle(HomeStyle.secondary)
                    Text(milestone.title).font(.system(size: 28, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                    Text(MilestoneInfo.about(milestone.id)).font(.system(size: 15)).foregroundStyle(HomeStyle.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 30).padding(.horizontal, 32).opacity(shown ? 1 : 0).offset(y: shown ? 0 : 18)
                Spacer(minLength: 20)
                panel(next: next, goal: goal)
                    .padding(.horizontal, 16).padding(.bottom, 12).offset(y: shown ? 0 : 220)
            }.offset(y: max(0, drag))
        }.gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { value in
            if value.translation.height > 120 { dismiss() } else { withAnimation(.smooth) { drag = 0 } }
        })
        .sensoryFeedback(.success, trigger: shown) { _, now in now && milestone.earned }
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.72)) { shown = true }
            Task { try? await Task.sleep(for: .seconds(0.45)); withAnimation(.smooth(duration: 0.8)) { filled = true } }
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(0.2))
            await spin()
        }
    }
    /// The badge's back: its name, earned or how far along, and the app's name.
    private func back(_ colour: Color) -> some View {
        ZStack {
            Hexagon().fill(LinearGradient(colors: [colour.opacity(0.35), colour.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            Hexagon().stroke(colour, lineWidth: 3)
            VStack(spacing: 8) {
                Text(milestone.title).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(milestone.earned ? "Earned" : milestone.progressLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(colour)
                Text("TWILDIARY").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.55)).padding(.top, 6)
            }.padding(24)
        }.frame(width: 170, height: 184)
    }
    private func panel(next: ProfileMilestone?, goal: ProfileMilestone?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(next.map { "Next: " + $0.title } ?? (goal == nil ? "Top level reached" : "Your progress"))
                .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            if let goal {
                let done = min(goal.progress, goal.target)
                HStack {
                    Text("\(done.formatted()) of \(goal.target.formatted())\(goal.unit)")
                    Spacer()
                    Text("\((goal.target - done).formatted()) to go")
                }.font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                Capsule().fill(.white.opacity(0.1)).frame(height: 8).overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(Color(webHex: goal.colour))
                            .frame(width: proxy.size.width * (filled ? min(1, Double(goal.progress) / Double(max(1, goal.target))) : 0))
                    }
                }
            } else {
                Text("You've earned every level of this badge.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .accessibilityElement(children: .combine).accessibilityIdentifier("milestone-next")
    }
    /// One full turn: the back shows through the middle half.
    private func spin() async {
        guard !spinning, !reduceMotion else { return }
        spinning = true
        withAnimation(.easeIn(duration: 0.22)) { angle += 90 }
        try? await Task.sleep(for: .seconds(0.22))
        showsBack = true
        withAnimation(.linear(duration: 0.44)) { angle += 180 }
        try? await Task.sleep(for: .seconds(0.44))
        showsBack = false
        withAnimation(.easeOut(duration: 0.4)) { angle += 90 }
        try? await Task.sleep(for: .seconds(0.4))
        spinning = false
    }
    private func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) { shown = false; drag = 0 }
        Task { try? await Task.sleep(for: .seconds(0.2)); close() }
    }
}

/// Shows a badge's detail over everything (tab bar included), without the cover's slide-up.
struct MilestoneDetailPresenter: ViewModifier {
    @Binding var selection: ProfileMilestone?
    let all: [ProfileMilestone]
    func body(content: Content) -> some View {
        content.fullScreenCover(item: $selection) { milestone in
            MilestoneDetailView(milestone: milestone, all: all) {
                var quiet = Transaction(); quiet.disablesAnimations = true
                withTransaction(quiet) { selection = nil }
            }.presentationBackground(.clear)
        }
    }
}
extension Binding where Value == ProfileMilestone? {
    /// Opens the detail without the system slide (it animates itself).
    func open(_ milestone: ProfileMilestone) {
        var quiet = Transaction(); quiet.disablesAnimations = true
        withTransaction(quiet) { wrappedValue = milestone }
    }
}

struct PersonalProfileView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("profileUsername") private var username = ""
    private var profile = PersonalProfile.shared
    @State private var showAvatarPicker = false
    @State private var editing = false
    @State private var trakt: TraktProfileSummary?
    @State private var openMilestone: ProfileMilestone?
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
            .sheet(isPresented: $showAvatarPicker) { NavigationStack { AvatarPickerView() }.presentationDragIndicator(.visible) }
            .sheet(isPresented: $editing) { NavigationStack { EditProfileView() }.presentationDragIndicator(.visible) }
            .task { await ProfileAvatarCatalog.shared.load(preview: store.isPreview) }
            .task(id: store.sessionRevision) { trakt = await TraktProfileSummary.load(store: store) }
            .modifier(MilestoneDetailPresenter(selection: $openMilestone, all: milestones))
    }

    private var handle: String {
        if !username.isEmpty { return "@" + username.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
        if store.traktSignedInOnPhone, let name = store.providerSettings.config(for: .trakt).username, !name.isEmpty { return "@" + name }
        return ""
    }
    private var header: some View {
        let art = store.activeEvents.max { ($0.watchedAt ?? $0.recordedAt) < ($1.watchedAt ?? $1.recordedAt) }.flatMap { store.title($0.titleId) }
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
                    // Reaches up under the status bar (owner's request): 80 pt taller, starting 80 pt higher.
                    .frame(height: 310).clipped()
                    .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black.opacity(0.05), location: 0.3),
                                                    .init(color: .black.opacity(0.55), location: 0.7), .init(color: .black, location: 1)],
                                            startPoint: .top, endPoint: .bottom))
                    .padding(.horizontal, -16).offset(y: -140).allowsHitTesting(false).accessibilityHidden(true)
            }
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
        for event in store.activeEvents {
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
                        Button { $openMilestone.open(milestone) } label: { MilestoneBadge(milestone: milestone, size: 46) }.buttonStyle(.springPress)
                            .accessibilityLabel(milestone.title + (milestone.earned ? ", earned" : ", " + milestone.progressLabel))
                            .accessibilityIdentifier("profile-milestone-" + milestone.id)
                    }
                }.padding(.vertical, 4).padding(.horizontal, 18)
            }.scrollIndicators(.hidden).padding(.horizontal, -18)
        }.padding(18).diaryPanel(padding: 0, radius: 22)
    }
    /// What you watched on this date in earlier months and years; opens On this day.
    private var onThisDay: some View {
        let days = OnThisDay.days(store.historyEntries(HistoryQuery()), now: store.now)
        let watches = days.reduce(0) { $0 + $1.entries.count }
        return NavigationLink(value: OnThisDayRoute()) { HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(store.now.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent)
                Text(store.now.formatted(.dateTime.day())).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
            }.frame(width: 56, height: 60).background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("On this day").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                if let first = days.first, let entry = first.entries.first {
                    Text("\(first.ago) you watched \(entry.title.name)" + (watches > 1 ? " and \(watches - 1) more." : "."))
                        .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Nothing happened today.").font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !days.isEmpty { DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary) }
        }.padding(16).diaryPanel(padding: 0, radius: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).allowsHitTesting(!days.isEmpty).accessibilityElement(children: .combine).accessibilityIdentifier("profile-on-this-day")
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
        let recent = store.activeEventsNewestFirst
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
        let planned = store.activeTitles.filter { $0.status == "planned" }.count
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
}

/// The characters offered as avatars, loaded once per launch and shared by the picker and Edit profile.
@MainActor @Observable final class ProfileAvatarCatalog {
    static let shared = ProfileAvatarCatalog()
    private(set) var characters: [ProfileAvatarChoice] = []
    private(set) var error: String?
    private var loading = false
    func load(preview: Bool) async {
        guard characters.isEmpty, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        #if DEBUG
        if preview { characters = [ProfileAvatarChoice(id: 176754, name: "Frieren", image: "/demo/frieren.jpg"), ProfileAvatarChoice(id: 138100, name: "Anya", image: nil)]; return }
        #endif
        do { characters = try await AniListClient.shared.popularAvatars() }
        catch { self.error = "Characters are unavailable. You can still choose a custom photo." }
    }
}

struct OnThisDayRoute: Hashable {}

/// Watches from today's date in earlier months and years (11 May and 11 Nov 2022 on 11 November).
enum OnThisDay {
    struct Day: Identifiable {
        let id: String
        let date: Date
        /// "6 months ago", "4 years ago", "1 year, 6 months ago".
        let ago: String
        let entries: [HistoryEntry]
    }
    static func days(_ entries: [HistoryEntry], now: Date) -> [Day] {
        let calendar = DiaryDate.calendar()
        let today = calendar.startOfDay(for: now)
        let dayOfMonth = calendar.component(.day, from: today)
        var byDay: [String: (date: Date, entries: [(Date, HistoryEntry)])] = [:]
        for entry in entries {
            guard let watched = DiaryDate.parse(entry.event.watchedAt) else { continue }
            let start = calendar.startOfDay(for: watched)
            guard start < today, calendar.component(.day, from: start) == dayOfMonth else { continue }
            byDay[DiaryDate.day(start), default: (start, [])].entries.append((watched, entry))
        }
        return byDay.map { key, value in
            Day(id: key, date: value.date, ago: ago(from: value.date, to: today, calendar: calendar),
                entries: value.entries.sorted { $0.0 > $1.0 }.map(\.1))
        }.sorted { $0.date > $1.date }
    }
    static func ago(from: Date, to: Date, calendar: Calendar) -> String {
        let months = max(1, calendar.dateComponents([.month], from: from, to: to).month ?? 1)
        let years = months / 12, rest = months % 12
        if years == 0 { return months.counted("month", "months") + " ago" }
        if rest == 0 { return years.counted("year", "years") + " ago" }
        return years.counted("year", "years") + ", " + rest.counted("month", "months") + " ago"
    }
}

/// On this day: a carousel of the days (auto-advancing, with pause), then each day's watches.
struct OnThisDayView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var page: String?
    @State private var paused = false
    var body: some View {
        let days = OnThisDay.days(store.historyEntries(HistoryQuery()), now: store.now)
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if days.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "calendar").font(.system(size: 28)).foregroundStyle(theme.accent)
                        Text("Nothing on this day yet").font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.primary)
                        Text("Watches from this date in earlier months and years appear here.").font(.system(size: 14))
                            .foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    carousel(days)
                    ForEach(days) { day in dayCard(day) }
                    Text("More memories tomorrow").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 6)
                }
            }.padding(.horizontal, 16).padding(.bottom, 28)
        }.diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("On this day").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Text(store.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    }.lineLimit(1).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                }
            }
    }
    private func carousel(_ days: [OnThisDay.Day]) -> some View {
        let current = page ?? days.first?.id
        return VStack(spacing: 12) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(days) { day in
                        NavigationLink(value: day.entries[0].title.id) { memoryCard(day) }.buttonStyle(.springPress)
                            .containerRelativeFrame(.horizontal).id(day.id)
                    }
                }.scrollTargetLayout()
            }.scrollTargetBehavior(.viewAligned).scrollPosition(id: $page).scrollIndicators(.hidden)
                .contentMargins(.horizontal, 30, for: .scrollContent).padding(.horizontal, -16)
                .accessibilityIdentifier("on-this-day-carousel")
            if days.count > 1 {
                HStack(spacing: 14) {
                    if days.count <= 12 {
                        HStack(spacing: 6) {
                            ForEach(days) { day in
                                Capsule().fill(day.id == current ? Color.white : Color.white.opacity(0.3)).frame(width: day.id == current ? 22 : 7, height: 7)
                            }
                        }.animation(.smooth(duration: 0.3), value: current).accessibilityHidden(true)
                    } else {
                        Text("\((days.firstIndex { $0.id == current } ?? 0) + 1) of \(days.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(HomeStyle.secondary)
                    }
                    if !reduceMotion {
                        Button { paused.toggle() } label: {
                            Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(paused ? "Play memories" : "Pause memories").accessibilityIdentifier("on-this-day-pause")
                    }
                }.frame(maxWidth: .infinity)
            }
        }.task(id: "\(paused)-\(days.count)-\(reduceMotion)") {
            // Every few seconds, the next day (Reduce Motion or Pause holds still).
            guard !paused, !reduceMotion, days.count > 1 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                let index = days.firstIndex { $0.id == page } ?? 0
                withAnimation(.smooth(duration: 0.5)) { page = days[(index + 1) % days.count].id }
            }
        }
    }
    private func memoryCard(_ day: OnThisDay.Day) -> some View {
        let first = day.entries[0]
        let others = Set(day.entries.map(\.title.id)).count - 1
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Artwork(path: first.title.backdrop ?? first.title.poster, title: first.title.name, initialsOnly: false) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(day.ago).font(.system(size: 24, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 8) {
                    Text(first.title.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    // The rest of that day's titles, kept visible however long the first name is.
                    if others > 0 {
                        Text("+\(others)").font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                            .padding(.horizontal, 8).frame(height: 22).background(HomeStyle.chip, in: Capsule()).fixedSize()
                            .accessibilityLabel("and \(others) more")
                    }
                }
            }.foregroundStyle(.white).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).background(theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 26))
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 26))
            .accessibilityElement(children: .combine)
    }
    private func dayCard(_ day: OnThisDay.Day) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.ago).font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.primary)
                Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ForEach(day.entries) { entry in
                NavigationLink(value: entry.title.id) { row(entry) }.buttonStyle(.plain)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
            .accessibilityElement(children: .contain).accessibilityIdentifier("on-this-day-" + day.id)
    }
    private func row(_ entry: HistoryEntry) -> some View {
        let watched = DiaryDate.parse(entry.event.watchedAt)
        let detail = entry.episode.map { episode in
            "S\(episode.season) · E\(episode.number)" + (episode.name.isEmpty || episode.name.hasPrefix("Episode ") ? "" : " · " + episode.name)
        } ?? [entry.title.categoryName, entry.title.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        let meta = [entry.title.runtimeMinutes.flatMap { $0 > 0 ? DiaryDate.duration($0) : nil },
                    watched.map { $0.formatted(date: .omitted, time: .shortened) }].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 14) {
            Color.clear.frame(width: 106, height: 60)
                .overlay { Artwork(path: entry.title.backdrop ?? entry.title.poster, title: entry.title.name, initialsOnly: false) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(detail).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                if !meta.isEmpty { Text(meta).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

/// Milestones: how many you've earned, every earned badge, and the next one with its progress.
struct MilestonesView: View {
    @Environment(DiaryStore.self) private var store
    @State private var selected: ProfileMilestone?
    /// Closest first, so "Next up" and the top of the Up next list agree (ties keep their order).
    static func closestFirst(_ items: [ProfileMilestone]) -> [ProfileMilestone] {
        func share(_ item: ProfileMilestone) -> Double { Double(item.progress) / Double(max(1, item.target)) }
        return items.enumerated().sorted { share($0.element) != share($1.element) ? share($0.element) > share($1.element) : $0.offset < $1.offset }.map(\.element)
    }
    var body: some View {
        let milestones = ProfileMilestone.make(store.workspace, now: store.now)
        let earned = milestones.filter(\.earned)
        let upcoming = Self.closestFirst(milestones.filter { !$0.earned })
        let next = upcoming.first
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
                            Button { $selected.open(item) } label: {
                                VStack(spacing: 10) {
                                    MilestoneBadge(milestone: item, size: 52)
                                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity).contentShape(Rectangle())
                            }.buttonStyle(.springPress).accessibilityElement(children: .combine).accessibilityIdentifier("milestone-" + item.id)
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Up next").font(.system(size: 22, weight: .bold))
                    ForEach(upcoming.prefix(6)) { item in
                        Button { $selected.open(item) } label: { HStack(spacing: 14) {
                            MilestoneBadge(milestone: item, size: 40)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(item.title).font(.system(size: 16, weight: .semibold)); Spacer(); Text(item.progressLabel).font(.system(size: 13)).foregroundStyle(.secondary) }
                                Capsule().fill(.white.opacity(0.1)).frame(height: 8).overlay(alignment: .leading) {
                                    GeometryReader { proxy in Capsule().fill(Color(webHex: item.colour)).frame(width: proxy.size.width * min(1, Double(item.progress) / Double(max(1, item.target)))) }
                                }
                            }
                        }.foregroundStyle(.white).contentShape(Rectangle()) }.buttonStyle(.plain)
                            .accessibilityElement(children: .combine).accessibilityIdentifier("milestone-" + item.id)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
            }.padding(.horizontal, 16).padding(.bottom, 28)
        }.diaryScreenBackground().diaryPageNavigation("Milestones")
            .modifier(MilestoneDetailPresenter(selection: $selected, all: milestones))
    }
}

/// Edit profile: picture (a character or your own photo), name and username. Saved on this iPhone.
struct EditProfileView: View {
    @Environment(DiaryStore.self) private var store
    private var catalog: ProfileAvatarCatalog { .shared }
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
                            ForEach(catalog.characters) { choice in ProfileCharacterAvatarButton(choice: choice, size: 72) { PersonalProfile.shared.select(choice) } }
                        }
                    }.scrollIndicators(.hidden)
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Upload a photo", systemImage: "camera").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50).background(.white.opacity(0.07), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }.accessibilityIdentifier("profile-custom-photo")
                    if let error = error ?? catalog.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 0, radius: 22)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name").font(.system(size: 14)).foregroundStyle(.secondary)
                    TextField("Name", text: $name).textContentType(.name).padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    Text("Username").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 6)
                    TextField("@username", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled().padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }.padding(18).diaryPanel(padding: 0, radius: 22)
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 28)
        }.diaryScreenBackground().navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .task { await catalog.load(preview: store.isPreview) }
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
    @Environment(DiaryStore.self) private var store
    private var catalog: ProfileAvatarCatalog { .shared }
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
                if let error = error ?? catalog.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Button("Use initials") { generation = UUID(); PersonalProfile.shared.useInitials(); dismiss() }
                if !catalog.characters.isEmpty {
                    // Same sideways row as Edit profile (a lazy grid here never drew in the sheet).
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose a character").font(.system(size: 20, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading)
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(catalog.characters) { choice in
                                    ProfileCharacterAvatarButton(choice: choice, size: 72) {
                                        generation = UUID(); PersonalProfile.shared.select(choice)
                                    }
                                }
                            }.padding(.horizontal, 20)
                        }.scrollIndicators(.hidden).padding(.horizontal, -20)
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
            .task { await catalog.load(preview: store.isPreview) }
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
