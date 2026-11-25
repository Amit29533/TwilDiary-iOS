import SwiftUI
import TwilDiaryCore

/// Cines (Home → Cines; owner's drawing, 25 Nov 2026, after the anime.com app's): trailers and
/// scenes, one a screen, swiped up as reels are. YouTube's player has the middle to itself, its own
/// title at its top and its logo at its bottom, with nothing of ours over it (the first drawing's
/// buttons sat on the video). Round the video, the title's picture, blurred. Below it a panel: what
/// the clip is, the title (› opens its page), "Show · 2021 · genres", Share, and Plan (green once
/// it's Planned; a tap takes it out again). At the top: For you, Shows, Movies, Anime and Sound
/// (muted until it's on), and a thin line for how far the clip has played. Clips YouTube won't play
/// here are skipped (`CinesFeed.check`); titles already in the diary come up less often.
struct CinesView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @AppStorage("confirmDeletions") private var confirmDeletions = true
    @State private var tab = CinesTab.forYou
    @State private var feeds = Dictionary(uniqueKeysWithValues: CinesTab.allCases.map { ($0, CinesFeed(tab: $0)) })
    @State private var positions: [CinesTab: String] = [:]
    @State private var current: String?
    @State private var player = CinesPlayer()
    @State private var busy = Set<String>()
    @State private var failures: [String: String] = [:]
    @State private var removing: CinesClip?

    private var feed: CinesFeed { feeds[tab]! }
    private static let panel = Color(white: 0.07)

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(feed.clips) { clip in
                        page(clip).frame(width: proxy.size.width, height: proxy.size.height).id(clip.id)
                    }
                    if feed.clips.isEmpty || feed.loading || feed.failure != nil {
                        status.frame(width: proxy.size.width, height: feed.clips.isEmpty ? proxy.size.height : 160)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .top, spacing: 0) { progressLine }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { chips }
            ToolbarItem(placement: .topBarTrailing) {
                Button { player.muted.toggle() } label: {
                    Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .accessibilityLabel(player.muted ? "Sound off. Turn sound on" : "Sound on. Turn sound off")
                .accessibilityIdentifier("cines-sound")
            }
        }
        .task { await open(tab) }
        .onChange(of: current) { _, id in settle(on: id) }
        .onChange(of: tab) { old, new in
            positions[old] = current
            player.stop()
            Task { await open(new) }
        }
        .onChange(of: player.refused) { _, refused in
            // YouTube wouldn't play the clip after all (a region block, say): on to the next one.
            guard let current, refused.contains(current), let index = feed.clips.firstIndex(where: { $0.id == current }),
                  index + 1 < feed.clips.count else { return }
            let next = feed.clips[index + 1].id
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if self.current == current { withAnimation(.smooth) { self.current = next } }
            }
        }
        .onAppear { player.back() }
        .onDisappear { player.leave() }
        .confirmationDialog("Remove \(removing?.name ?? "this title") from Planned?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { clip in
            Button("Remove from Planned", role: .destructive) { Task { await removePlanned(clip) } }
        } message: { _ in Text("It moves to Trash.") }
    }

    // MARK: Top

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(CinesTab.allCases) { item in
                Button { if tab != item { tab = item } } label: {
                    Text(item.name).font(.app(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(tab == item ? Color.black : Color.white)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(tab == item ? Color.white : Color.white.opacity(0.16), in: Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("cines-tab-" + item.rawValue)
            }
        }.fixedSize()
    }

    /// How far the clip on screen has played.
    private var progressLine: some View {
        Capsule().fill(.white.opacity(0.22)).frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { line in Capsule().fill(.white).frame(width: line.size.width * player.progress) }
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 6)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var status: some View {
        if let failure = feed.failure {
            VStack(spacing: 12) {
                Text(failure).font(.app(size: 14)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                Button("Try again") { Task { await open(tab) } }.buttonStyle(.bordered).tint(.white)
            }.padding(.horizontal, 32)
        } else if feed.loading || feed.clips.isEmpty {
            ProgressView().tint(.white)
        }
    }

    // MARK: A clip

    private func page(_ clip: CinesClip) -> some View {
        VStack(spacing: 0) {
            stage(clip, active: clip.id == current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panel(clip)
        }
    }

    /// The player's area: YouTube's whole player fills it (its title and logo at its edges). Until
    /// the video plays, the clip's own still in its place; a tap pauses or plays.
    private func stage(_ clip: CinesClip, active: Bool) -> some View {
        let refused = player.refused.contains(clip.id)
        let showing = active && !refused && player.playing
        return ZStack {
            Color.black
            Artwork(path: clip.backdrop ?? clip.poster, title: clip.name, initialsOnly: false)
                .blur(radius: 36).opacity(0.5)
                .overlay(LinearGradient(colors: [.black.opacity(0.4), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)
            if !showing {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(clip.id)/hqdefault.jpg")) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color.black }
                    }
                    .clipped()
            }
            if active, !refused { CinesPlayerHost(player: player).opacity(player.playing ? 1 : 0) }
            if refused {
                VStack(spacing: 10) {
                    Text("This clip can't play in the app.").font(.app(size: 14, weight: .semibold))
                    Button("Watch on YouTube") { openURL(clip.watchURL) }.buttonStyle(.bordered).tint(.white)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.6))
            } else if active, !player.playing {
                ProgressView().tint(.white)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { if active { player.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.kind + ", " + clip.name)
        .accessibilityHint(active ? "Double-tap to pause or play" : "")
        .accessibilityAddTraits(.startsMediaSession)
    }

    /// Below the video: what it is and its title (› its page), then Share and Plan.
    private func panel(_ clip: CinesClip) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.kind).font(.app(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                Button { details(clip) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(clip.name).font(.app(size: 18, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint("Opens its page")
                    .accessibilityIdentifier("cines-details")
                Text(clip.detail).font(.app(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if let failure = failures[clip.id] {
                    Text(failure).font(.app(size: 12)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            ShareLink(item: clip.watchURL, subject: Text(clip.name), message: Text(clip.name + " · " + clip.kind)) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.white.opacity(0.14), in: Circle())
            }.buttonStyle(.springPress).accessibilityLabel("Share").accessibilityIdentifier("cines-share")
            planButton(clip)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Self.panel)
    }

    // MARK: Plan

    /// "+ Plan" adds the title to Planned; "✓ Planned" (green) while it is, a tap taking it out; a
    /// title you've watched or are watching says so instead.
    @ViewBuilder private func planButton(_ clip: CinesClip) -> some View {
        let id = libraryID(clip)
        let status = id.flatMap { store.title($0)?.status }
        let working = busy.contains(Self.key(clip))
        if let status, status != "planned" {
            pill(Self.stateName(status), symbol: status == "completed" ? "eye.fill" : "play.fill", fill: .white.opacity(0.14))
                .accessibilityElement(children: .combine).accessibilityIdentifier("cines-state")
        } else if status == "planned" {
            Button { if confirmDeletions { removing = clip } else { Task { await removePlanned(clip) } } } label: {
                pill("Planned", symbol: "checkmark", fill: Color(themed: "#30d158"), working: working)
            }.buttonStyle(.springPress).disabled(working)
                .accessibilityLabel("Planned. Remove " + clip.name + " from Planned")
                .accessibilityIdentifier("cines-planned")
        } else {
            let retry = failures[clip.id] != nil
            Button { Task { await add(clip) } } label: {
                pill(retry ? "Retry" : "Plan", symbol: retry ? "arrow.clockwise" : "plus", fill: retry ? .orange : .accentColor, working: working)
            }.buttonStyle(.springPress).disabled(working)
                .accessibilityLabel("Add " + clip.name + " to Planned")
                .accessibilityIdentifier("cines-plan")
        }
    }

    private func pill(_ title: String, symbol: String, fill: Color, working: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
            Text(title).font(.app(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        .opacity(working ? 0 : 1)
        .overlay { if working { ProgressView().tint(.white) } }
        .padding(.horizontal, 16).frame(height: 42)
        .background(fill, in: Capsule())
        .fixedSize()
    }

    private static func stateName(_ status: String) -> String {
        switch status {
        case "completed": "Watched"
        case "watching": "Watching"
        case "paused", "on_hold": "Paused"
        case "dropped": "Dropped"
        default: "In library"
        }
    }
    private static func key(_ clip: CinesClip) -> String { clip.route.kind.rawValue + ":" + String(clip.route.id) }

    // MARK: Actions

    /// A tab's clips: the first few checked with YouTube before the first one plays.
    private func open(_ tab: CinesTab) async {
        let feed = feeds[tab]!
        if feed.clips.isEmpty { await feed.loadMore(store) }
        await withTaskGroup(of: Void.self) { group in
            for clip in feed.clips.prefix(3) { let id = clip.id; group.addTask { _ = await feed.check(id) } }
        }
        guard self.tab == tab else { return }
        let id = positions[tab].flatMap { saved in feed.clips.contains { $0.id == saved } ? saved : nil } ?? feed.clips.first?.id
        if current == id { settle(on: id) } else { current = id }
    }

    /// A clip came on screen: play it, check the next few with YouTube, and load more near the end.
    private func settle(on id: String?) {
        guard let id, let index = feed.clips.firstIndex(where: { $0.id == id }) else { return }
        player.play(id)
        let feed = feed
        let ahead = feed.clips.dropFirst(index + 1).prefix(3).map(\.id)
        Task { for next in ahead { _ = await feed.check(next) } }
        if index >= feed.clips.count - 4 { Task { await feed.loadMore(store) } }
    }

    private func libraryID(_ clip: CinesClip) -> String? {
        store.libraryIdentity(CatalogItem(id: clip.route.id, mediaType: clip.route.kind, name: clip.name))
    }

    private func details(_ clip: CinesClip) {
        if let id = libraryID(clip), store.title(id) != nil { router.openTitle(id, tab: router.selectedTab) }
        else { router.paths[router.selectedTab, default: NavigationPath()].append(clip.route) }
    }

    /// Plan: the title joins the diary as Planned, as Search's + does (its full details read first).
    private func add(_ clip: CinesClip) async {
        let key = Self.key(clip)
        guard store.canMutate, busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        failures[clip.id] = nil
        do {
            let browse = try await store.browse(clip.route)
            if await store.importTitle(browse.details, category: browse.details.suggestedCategory) == nil {
                failures[clip.id] = store.error ?? "This title couldn't be added."
            } else { Haptics.play(.light) }
        } catch {
            failures[clip.id] = FriendlyError.message(error)
        }
    }

    private func removePlanned(_ clip: CinesClip) async {
        let key = Self.key(clip)
        guard let id = libraryID(clip), let title = store.title(id), title.status == "planned", busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        if await store.trash(title) { Haptics.play(.light) }
    }
}
