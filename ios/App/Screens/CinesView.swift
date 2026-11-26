import SwiftUI
import TwilDiaryCore

/// Cines (Home → Cines; owner's drawing, 25 Nov 2026): trailers, scenes and Shorts, one a screen,
/// swiped up as reels are.
/// - A wide clip plays centred on the screen (as near the centre as clears the buttons), the player
///   just the size of the video, over the title's blurred picture.
/// - A Short fills the screen. Its tabs, buttons and title show when it starts and fade after
///   three seconds (owner's call: a personal app); a tap brings them back, and they stay while
///   it's paused.
/// - No YouTube controls or buttons over the video (`CinesPlayer`, after youtube_player_flutter):
///   a tap pauses or plays, with a play button of ours while paused.
/// - On the right: Plan (a green tick once Planned; a tap takes it out again), Details and Sound
///   (Share was taken out, owner's call, 25 Nov 2026). Bottom left: what the clip is, the title, "Show · 2021 · genres" and the channel.
/// - At the top: back, then For you, Shows, Movies and Anime as plain text tabs.
struct CinesView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("confirmDeletions") private var confirmDeletions = true
    // Kept for the session (back to Cines later, you're where you were): the tab, its clips, and
    // the clip you were on in each.
    private static var lastTab = CinesTab.forYou
    private static let sharedFeeds = Dictionary(uniqueKeysWithValues: CinesTab.allCases.map { ($0, CinesFeed(tab: $0)) })
    private static var lastPositions: [CinesTab: String] = [:]
    @State private var tab = CinesView.lastTab
    @State private var feeds = CinesView.sharedFeeds
    @State private var positions = CinesView.lastPositions
    /// The video a little enlarged, its edges cut (a pinch out; a pinch in puts it back).
    @AppStorage("cines.zoomed") private var zoomed = false
    @State private var current: String?
    @State private var player = CinesPlayer()
    @State private var busy = Set<String>()
    @State private var failures: [String: String] = [:]
    @State private var removing: CinesClip?
    /// A Short's tabs, buttons and title: shown, or faded away.
    @State private var chromeShown = true
    @State private var fading: Task<Void, Never>?

    private var feed: CinesFeed { feeds[tab]! }
    private var currentClip: CinesClip? { current.flatMap { id in feed.clips.first { $0.id == id } } }
    /// Whether the tabs show: always, except over a Short once its buttons have faded.
    private var topShown: Bool { currentClip?.short != true || chromeShown }

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            let size = CGSize(width: outer.size.width, height: outer.size.height + insets.top + insets.bottom)
            ZStack(alignment: .top) {
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
                topBar
                    .padding(.top, insets.top + 4).padding(.horizontal, 14)
                    .opacity(topShown ? 1 : 0).allowsHitTesting(topShown)
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        // The bar is hidden, so UIKit's back swipes need turning back on (as Explore does).
        .background(EdgeSwipeBack().frame(width: 0, height: 0))
        .task { await open(tab) }
        .onChange(of: current) { _, id in
            settle(on: id); showChrome()
            if let id { positions[tab] = id; Self.lastPositions[tab] = id }
        }
        // A pause brings a Short's buttons back (and keeps them).
        .onChange(of: player.paused) { _, _ in showChrome() }
        .onChange(of: tab) { old, new in
            positions[old] = current
            Self.lastTab = new
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
        .onAppear { player.back(); showChrome() }
        .onDisappear { player.leave(); fading?.cancel() }
        .confirmationDialog("Remove \(removing?.name ?? "this title") from Planned?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { clip in
            Button("Remove from Planned", role: .destructive) { Task { await removePlanned(clip) } }
        } message: { _ in Text("It moves to Trash.") }
    }

    // MARK: Top

    /// Back, then the tabs as plain text: the one you're on white and underlined.
    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.white.opacity(0.16), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("cines-back")
            HStack(spacing: 16) {
                ForEach(CinesTab.allCases) { item in
                    Button { if tab != item { tab = item } } label: {
                        Text(item.name).font(.app(size: 17, weight: tab == item ? .semibold : .medium)).lineLimit(1).fixedSize()
                            .foregroundStyle(tab == item ? Color.white : Color.white.opacity(0.62))
                            .padding(.bottom, 4)
                            .overlay(alignment: .bottom) { if tab == item { Capsule().fill(.white).frame(height: 2) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                        .accessibilityIdentifier("cines-tab-" + item.rawValue)
                }
            }
            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(0.35), radius: 6)
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

    /// How much smaller the backdrop's wash is drawn than it shows.
    private static let washScale: CGFloat = 8
    /// How much bigger a pinch makes the video's box (its sides are cut by the screen).
    private static let zoom: CGFloat = 1.25

    /// The right-hand buttons' height (three 46 pt circles with their names, 10 pt apart).
    private static let railHeight: CGFloat = 3 * (46 + 4 + 16) + 2 * 10

    private func page(_ clip: CinesClip, size: CGSize, insets: EdgeInsets) -> some View {
        let active = clip.id == current
        let shown = !clip.short || !active || chromeShown
        let bottom = insets.bottom + 18
        let railTop = size.height - bottom - Self.railHeight
        // A wide clip's player is just the video (16:9, no black above or below it), centred on the
        // screen (owner's call, 25 Nov 2026), or as near the centre as clears the buttons.
        let videoHeight = size.width * 9 / 16
        // Zoomed (a pinch out): the box itself a quarter bigger, so the video is drawn taller and its
        // sides go past the screen's edges (scaling the picture inside the box left it the same size).
        let scale = zoomed ? Self.zoom : 1
        let boxHeight = videoHeight * scale
        let centre = max(insets.top + 56 + boxHeight / 2, min(size.height / 2, railTop - 8 - boxHeight / 2))
        return ZStack(alignment: .bottom) {
            Color.black
            if clip.short {
                stage(clip, active: active).frame(width: size.width * scale, height: size.height * scale)
                    .frame(width: size.width, height: size.height)
            } else {
                // The backdrop as a soft wash: drawn at an eighth of the screen, blurred there and
                // flattened, then scaled up (a full-screen blur on every page, two or three of them
                // on screen while swiping, cost the most of anything in the app).
                Artwork(path: clip.backdrop ?? clip.poster, title: clip.name, initialsOnly: false)
                    .frame(width: size.width / Self.washScale, height: size.height / Self.washScale)
                    .blur(radius: 36 / Self.washScale, opaque: true).drawingGroup()
                    .scaleEffect(Self.washScale)
                    .frame(width: size.width, height: size.height).clipped().opacity(0.5)
                    .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                stage(clip, active: active).frame(width: size.width * scale, height: boxHeight)
                    .position(x: size.width / 2, y: centre)
            }
            Group {
                if clip.short {
                    // Over a Short, soft shades so the tabs and the title read.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: insets.top + 90)
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 300)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    info(clip)
                    Spacer(minLength: 0)
                    rail(clip)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, bottom)
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            if active {
                // Drag along it to move through the clip (it thickens while held).
                CinesSeekBar(progress: player.progress, bright: shown, enabled: player.duration > 0) { player.seek(to: $0) }
                    .padding(.bottom, max(0, insets.bottom - 9)).padding(.horizontal, 14)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { tapped(clip) }
        // Pinch out: the video a little enlarged, its edges cut; pinch in: the whole picture again.
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            let next = value.magnification > 1.06 ? true : value.magnification < 0.94 ? false : zoomed
            guard next != zoomed else { return }
            withAnimation(.smooth(duration: 0.3)) { zoomed = next }
            Haptics.play(.light)
        })
    }

    /// The player, with the clip's own still in the video's place until it plays. YouTube centres
    /// the video in the player (a Short is tall, a trailer wide), so the still is placed the same way.
    private func stage(_ clip: CinesClip, active: Bool) -> some View {
        let refused = player.refused.contains(clip.id)
        let showing = active && !refused && player.playing
        return ZStack {
            if !clip.short { Color.clear } else { Color.black }
            if !showing {
                Color.clear.aspectRatio(clip.short ? CGFloat(9) / 16 : CGFloat(16) / 9, contentMode: .fit)
                    .overlay {
                        // Through the app's picture cache (decoded at the screen's size and kept): the
                        // system loader kept nothing, so a clip swiped back to loaded and flashed again.
                        Artwork(path: "https://i.ytimg.com/vi/\(clip.id)/hqdefault.jpg", title: clip.name, plainPlaceholder: true)
                            .background(Color.black)
                    }
                    .clipped()
                    .allowsHitTesting(false)
            }
            if active, !refused { CinesPlayerHost(player: player).opacity(showing ? 1 : 0) }
            if refused {
                VStack(spacing: 10) {
                    Text("This clip can't play in the app.").font(.app(size: 14, weight: .semibold))
                    Button("Watch on YouTube") { openURL(clip.watchURL) }.buttonStyle(.bordered).tint(.white)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.6))
            } else if active, player.paused {
                // YouTube's own pause screen is hidden: this play button shows it's paused.
                Image(systemName: "play.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(.black.opacity(0.5), in: Circle())
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else if active, !showing {
                ProgressView().tint(.white).allowsHitTesting(false)
            }
        }
        .clipped()
        .accessibilityElement(children: active && showing ? .contain : .ignore)
        .accessibilityLabel(clip.kind + ", " + clip.name)
    }

    private func info(_ clip: CinesClip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.kind).font(.app(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 2)
            Text(clip.name).font(.app(size: 21, weight: .semibold)).lineLimit(2)
            Text(clip.detail).font(.app(size: 15)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            if let channel = feed.channels[clip.id] {
                Label(channel, systemImage: "play.rectangle.fill").font(.app(size: 15)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            if let failure = failures[clip.id] {
                Text(failure).font(.app(size: 14)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(clip.short ? 0.4 : 0), radius: 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: The buttons

    private func rail(_ clip: CinesClip) -> some View {
        VStack(spacing: 10) {
            planButton(clip)
            railButton("Details", symbol: "info.circle") { details(clip) }.accessibilityIdentifier("cines-details")
            railButton("Sound", symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { player.muted.toggle(); showChrome() }
                .accessibilityLabel(player.muted ? "Sound off. Turn sound on" : "Sound on. Turn sound off")
                .accessibilityIdentifier("cines-sound")
        }
    }

    /// Plan: + adds the title to Planned; a green tick while it's Planned (a tap takes it out); a
    /// title you've watched or are watching says so instead.
    @ViewBuilder private func planButton(_ clip: CinesClip) -> some View {
        let id = libraryID(clip)
        let status = id.flatMap { store.title($0)?.status }
        let working = busy.contains(Self.key(clip))
        if let status, status != "planned" {
            railLabel(Self.stateName(status), symbol: status == "completed" ? "eye.fill" : "play.fill")
                .accessibilityElement(children: .combine).accessibilityIdentifier("cines-state")
        } else if status == "planned" {
            railButton("Planned", symbol: "checkmark", fill: Color(themed: "#30d158"), working: working) {
                if confirmDeletions { removing = clip } else { Task { await removePlanned(clip) } }
            }
            .accessibilityLabel("Planned. Remove " + clip.name + " from Planned")
            .accessibilityIdentifier("cines-planned")
        } else {
            let retry = failures[clip.id] != nil
            railButton(retry ? "Retry" : "Plan", symbol: retry ? "arrow.clockwise" : "plus", fill: retry ? .orange : .accentColor, working: working) {
                Task { await add(clip) }
            }
            .accessibilityLabel("Add " + clip.name + " to Planned")
            .accessibilityIdentifier("cines-plan")
        }
    }

    private func railButton(_ title: String, symbol: String, fill: Color = .white.opacity(0.18), working: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { railLabel(title, symbol: symbol, fill: fill, working: working) }
            .buttonStyle(.springPress).disabled(working)
    }
    private func railLabel(_ title: String, symbol: String, fill: Color = .white.opacity(0.18), working: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .opacity(working ? 0 : 1)
                .overlay { if working { ProgressView().tint(.white) } }
                .frame(width: 46, height: 46).background(fill, in: Circle())
            Text(title).font(.app(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1).frame(height: 16)
        }
        .frame(minWidth: 60)
        .shadow(color: .black.opacity(0.3), radius: 3)
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

    // MARK: Taps and fading

    /// A tap: over a Short whose buttons have faded, they come back; otherwise it pauses or plays
    /// (YouTube's player doesn't take taps).
    private func tapped(_ clip: CinesClip) {
        guard clip.id == current else { return }
        if clip.short, !chromeShown { showChrome(); return }
        player.toggle()
        showChrome()
    }

    /// Shows a Short's tabs, buttons and title, and fades them again three seconds later (not
    /// while it's paused). Wide clips keep theirs.
    private func showChrome() {
        fading?.cancel()
        if !chromeShown { withAnimation(.easeOut(duration: 0.2)) { chromeShown = true } }
        guard currentClip?.short == true, !player.paused else { return }
        fading = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, currentClip?.short == true, !player.paused else { return }
            withAnimation(.easeOut(duration: 0.45)) { chromeShown = false }
        }
    }

    // MARK: Actions

    /// A tab's clips. Back to a tab, the clip you were on comes back at once (it used to wait for
    /// YouTube to answer about the tab's first three clips, so one slow answer held it up). New to a
    /// tab, only the first clip is waited for, checked with YouTube before it plays (one it won't play
    /// here leaves the feed, and the next is checked); the next two are checked alongside.
    private func open(_ tab: CinesTab) async {
        let feed = feeds[tab]!
        if feed.clips.isEmpty { await feed.loadMore(store) }
        // The clip on screen when you come back (from a title's page: this ran again and went to the
        // tab's first clip), else where you were in this tab.
        let saved = [current, positions[tab]].compactMap { $0 }.first { saved in feed.clips.contains { $0.id == saved } }
        if saved == nil {
            let others = feed.clips.prefix(3).dropFirst().map(\.id)
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for id in others { group.addTask { _ = await feed.check(id) } }
                }
            }
            for _ in 0..<5 {
                guard let first = feed.clips.first?.id, !(await feed.check(first)) else { break }
            }
        }
        guard self.tab == tab else { return }
        let id = saved ?? feed.clips.first?.id
        if current == id { settle(on: id); showChrome() } else { current = id }
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

/// The clip's progress along the bottom, which also seeks: drag along it (or touch a point) to move
/// through the clip; it thickens while held. A tall invisible strip takes the finger.
private struct CinesSeekBar: View {
    let progress: Double
    /// Full white (the clip's buttons showing) or a little dimmer.
    let bright: Bool
    let enabled: Bool
    let seek: (Double) -> Void
    @State private var scrub: Double?
    var body: some View {
        GeometryReader { line in
            let shown = scrub ?? progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(bright || scrub != nil ? 1 : 0.8)).frame(width: max(0, line.size.width * shown))
            }
            .frame(height: scrub == nil ? 3 : 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard enabled, line.size.width > 0 else { return }
                    scrub = min(1, max(0, drag.location.x / line.size.width))
                }
                .onEnded { drag in
                    guard enabled, line.size.width > 0 else { scrub = nil; return }
                    seek(min(1, max(0, drag.location.x / line.size.width)))
                    scrub = nil
                })
        }
        .frame(height: 24)
        .animation(.snappy(duration: 0.15), value: scrub == nil)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            if direction == .increment { seek(progress + 0.1) } else if direction == .decrement { seek(progress - 0.1) }
        }
        .accessibilityIdentifier("cines-seek")
    }
}
