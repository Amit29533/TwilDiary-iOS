import SwiftUI
import TwilDiaryCore

/// Cines (Home → Cines; owner's drawing, 25 Nov 2026): trailers and scenes, one a screen, swiped
/// up as reels are. The video plays in the middle over its title's blurred picture (trailers are
/// landscape), muted until Sound is on. On the right: Plan (a green tick once it's Planned; a tap
/// takes it out again), Details (the title's page), Sound and Share. Below: what the clip is, the
/// title, "Show · 2021 · genres" and the channel that posted it. For you, Shows, Movies and Anime
/// at the top. Titles already in the diary come up less often (`CinesFeed`).
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

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            let size = CGSize(width: outer.size.width, height: outer.size.height + insets.top + insets.bottom)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(feed.clips) { clip in
                        page(clip, size: size, insets: insets).frame(width: size.width, height: size.height).id(clip.id)
                    }
                    if feed.clips.isEmpty || feed.loading || feed.failure != nil {
                        status.frame(width: size.width, height: feed.clips.isEmpty ? size.height : 160)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .principal) { chips } }
        .task { await open(tab) }
        .onChange(of: current) { _, id in settle(on: id) }
        .onChange(of: tab) { old, new in
            positions[old] = current
            player.stop()
            Task { await open(new) }
        }
        .onAppear { player.back() }
        .onDisappear { player.leave() }
        .confirmationDialog("Remove \(removing?.name ?? "this title") from Planned?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { clip in
            Button("Remove from Planned", role: .destructive) { Task { await removePlanned(clip) } }
        } message: { _ in Text("It moves to Trash.") }
    }

    // MARK: Pieces

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(CinesTab.allCases) { item in
                Button { if tab != item { tab = item } } label: {
                    Text(item.name).font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(tab == item ? Color.black : Color.white)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(tab == item ? Color.white : Color.white.opacity(0.16), in: Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("cines-tab-" + item.rawValue)
            }
        }.fixedSize()
    }

    @ViewBuilder private var status: some View {
        if let failure = feed.failure {
            VStack(spacing: 12) {
                Text(failure).font(.app(size: 14)).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                Button("Try again") { Task { await feed.loadMore(store); if current == nil { current = feed.clips.first?.id } } }
                    .buttonStyle(.bordered).tint(.white)
            }.padding(.horizontal, 32)
        } else if feed.loading || feed.clips.isEmpty {
            ProgressView().tint(.white)
        }
    }

    private func page(_ clip: CinesClip, size: CGSize, insets: EdgeInsets) -> some View {
        let active = clip.id == current
        let videoHeight = size.width * 9 / 16
        return ZStack(alignment: .bottom) {
            Color.black
            // The title's picture, blurred, fills the screen behind the landscape video.
            Artwork(path: clip.backdrop ?? clip.poster, title: clip.name, initialsOnly: false)
                .frame(width: size.width, height: size.height).blur(radius: 36).opacity(0.5)
                .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)
            video(clip, active: active).frame(width: size.width, height: videoHeight)
                .position(x: size.width / 2, y: size.height * 0.42)
            HStack(alignment: .bottom, spacing: 12) {
                info(clip)
                Spacer(minLength: 0)
                rail(clip)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, insets.bottom + 18)
            if active {
                Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: size.width * player.progress, height: 3) }
                    .padding(.bottom, insets.bottom + 4).padding(.horizontal, 14)
                    .accessibilityHidden(true)
            }
        }.clipped()
    }

    /// The video (the clip's own still until it plays), a tap pausing it.
    private func video(_ clip: CinesClip, active: Bool) -> some View {
        let refused = player.refused.contains(clip.id)
        return ZStack {
            Color.black
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(clip.id)/hqdefault.jpg")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color.black }
            .clipped()
            if active, !refused { CinesPlayerHost(player: player).opacity(player.playing ? 1 : 0) }
            if refused {
                VStack(spacing: 10) {
                    Text("This clip can't play in the app.").font(.app(size: 14, weight: .semibold))
                    Button("Watch on YouTube") { openURL(clip.watchURL) }.buttonStyle(.bordered).tint(.white)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.6))
            } else if active, player.paused {
                Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9)).accessibilityHidden(true)
            } else if active, !player.playing {
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if active { player.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.kind + ", " + clip.name)
        .accessibilityHint(active ? "Double-tap to pause or play" : "")
        .accessibilityAddTraits(.startsMediaSession)
    }

    private func info(_ clip: CinesClip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.kind).font(.app(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 2)
            Text(clip.name).font(.app(size: 18, weight: .semibold)).lineLimit(2)
            Text(clip.detail).font(.app(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            if let channel = feed.channels[clip.id] {
                Label(channel, systemImage: "play.rectangle.fill").font(.app(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            if let failure = failures[clip.id] {
                Text(failure).font(.app(size: 12)).foregroundStyle(.orange).lineLimit(2)
            }
        }.foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    // MARK: The rail

    private func rail(_ clip: CinesClip) -> some View {
        VStack(spacing: 16) {
            planButton(clip)
            railButton("Details", symbol: "info.circle") { details(clip) }.accessibilityIdentifier("cines-details")
            railButton("Sound", symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { player.muted.toggle() }
                .accessibilityLabel(player.muted ? "Sound off. Turn sound on" : "Sound on. Turn sound off")
                .accessibilityIdentifier("cines-sound")
            ShareLink(item: clip.watchURL, subject: Text(clip.name), message: Text(clip.name + " · " + clip.kind)) {
                railLabel("Share", symbol: "square.and.arrow.up")
            }.buttonStyle(.springPress).accessibilityIdentifier("cines-share")
        }
    }

    /// Plan: + adds the title to Planned; a green tick while it's Planned (a tap takes it out); a
    /// title you've watched or are watching says so instead.
    @ViewBuilder private func planButton(_ clip: CinesClip) -> some View {
        let id = libraryID(clip)
        let status = id.flatMap { store.title($0)?.status }
        let working = busy.contains(clip.route.kind.rawValue + ":" + String(clip.route.id))
        if let status, status != "planned" {
            railLabel(Self.stateName(status), symbol: status == "completed" ? "eye.fill" : "play.circle.fill", fill: .white.opacity(0.16))
                .accessibilityElement(children: .combine).accessibilityIdentifier("cines-state")
        } else if status == "planned" {
            railButton("Planned", symbol: "checkmark", fill: Color(themed: "#30d158"), working: working) {
                if confirmDeletions { removing = clip } else { Task { await removePlanned(clip) } }
            }
            .accessibilityLabel("Planned. Remove " + clip.name + " from Planned")
            .accessibilityIdentifier("cines-planned")
        } else {
            railButton("Plan", symbol: failures[clip.id] == nil ? "plus" : "arrow.clockwise", fill: failures[clip.id] == nil ? .accentColor : .orange, working: working) {
                Task { await add(clip) }
            }
            .accessibilityLabel("Add " + clip.name + " to Planned")
            .accessibilityIdentifier("cines-plan")
        }
    }

    private func railButton(_ title: String, symbol: String, fill: Color = .white.opacity(0.16), working: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { railLabel(title, symbol: symbol, fill: fill, working: working) }
            .buttonStyle(.springPress).disabled(working)
    }
    private func railLabel(_ title: String, symbol: String, fill: Color = .white.opacity(0.16), working: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .opacity(working ? 0 : 1)
                .overlay { if working { ProgressView().tint(.white) } }
                .frame(width: 46, height: 46).background(fill, in: Circle())
            Text(title).font(.app(size: 11, weight: .medium)).foregroundStyle(.white)
        }.frame(minWidth: 52)
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

    // MARK: Actions

    private func open(_ tab: CinesTab) async {
        let feed = feeds[tab]!
        if feed.clips.isEmpty { await feed.loadMore(store) }
        guard self.tab == tab else { return }
        let id = positions[tab].flatMap { saved in feed.clips.contains { $0.id == saved } ? saved : nil } ?? feed.clips.first?.id
        if current == id { settle(on: id) } else { current = id }
    }

    /// A clip came on screen: play it, read its channel (and the next one's), and load more near the end.
    private func settle(on id: String?) {
        guard let id, let index = feed.clips.firstIndex(where: { $0.id == id }) else { return }
        player.play(id)
        let feed = feed
        Task { await feed.channel(for: id) }
        if index + 1 < feed.clips.count { let next = feed.clips[index + 1].id; Task { await feed.channel(for: next) } }
        if index >= feed.clips.count - 3 { Task { await feed.loadMore(store) } }
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
        let key = clip.route.kind.rawValue + ":" + String(clip.route.id)
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
        let key = clip.route.kind.rawValue + ":" + String(clip.route.id)
        guard let id = libraryID(clip), let title = store.title(id), title.status == "planned", busy.insert(key).inserted else { return }
        defer { busy.remove(key) }
        if await store.trash(title) { Haptics.play(.light) }
    }
}
