import SwiftUI
import AetherEngine

/// JellySpace (first build): your Jellyfin films and episodes, newest first or by search, each
/// played by AetherEngine straight from the file (Jellyfin's static stream, nothing converted).
/// Opens from the TwilDiary logo on Home. Browsing by library, Continue watching and syncing
/// progress back come next.
struct JellySpaceView: View {
    @State private var items: [JellyfinClient.Item] = []
    @State private var query = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    private var client: JellyfinClient? {
        guard let base = JellyfinSettings.address, let key = JellyfinSettings.apiKey else { return nil }
        return JellyfinClient(base: base, key: key)
    }

    var body: some View {
        ExploreBrowsePage(title: "JellySpace", symbol: "play.rectangle.on.rectangle", subtitle: query.isEmpty ? "Recently added" : "Search") {
            VStack(alignment: .leading, spacing: 14) {
                if client == nil {
                    NavigationLink(value: AppDestination.jellyfin) {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack").font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            Text("Connect Jellyfin").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14).frame(minHeight: 50).diaryPanel(padding: 0, radius: 14).contentShape(Rectangle())
                    }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-connect")
                } else {
                    SearchField(placeholder: "Search Jellyfin", text: $query, label: "Search Jellyfin")
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading Jellyfin", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text(query.isEmpty ? "Nothing in Jellyfin yet." : "Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(items, id: \.Id) { item in tile(item) }
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .task(id: query) {
            // A pause after typing, so a search goes once per word, not once per letter.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .fullScreenCover(item: $playing) { JellyPlayerView(playback: $0) }
    }

    private func tile(_ item: JellyfinClient.Item) -> some View {
        Button {
            guard let url = client?.streamURL(item.Id) else { return }
            playing = JellyPlayback(id: item.Id, url: url, title: Self.name(item))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(path: client.flatMap { Self.poster(item, base: $0.base) }?.absoluteString, title: item.Name ?? "", initialsOnly: false)
                    .aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(item.SeriesName ?? item.Name ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(Self.detail(item)).font(.system(size: 11)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityLabel("Play " + Self.name(item)).accessibilityIdentifier("jellyspace-item-" + item.Id)
    }

    private func load() async {
        guard let client else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let found = try await client.videos(search: query.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !Task.isCancelled else { return }
            items = found
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    /// An episode by its show's poster; a film by its own.
    static func poster(_ item: JellyfinClient.Item, base: URL) -> URL? {
        if let series = item.SeriesId, let tag = item.SeriesPrimaryImageTag { return JellyfinClient.posterURL(base: base, item: series, tag: tag) }
        return JellyfinClient.posterURL(base: base, item: item.Id, tag: item.ImageTags?["Primary"])
    }
    /// "S1 E4 · Name" for an episode, "2019" for a film.
    static func detail(_ item: JellyfinClient.Item) -> String {
        guard item.kind == "Episode" else { return item.ProductionYear.map(String.init) ?? "Movie" }
        let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
        return [place.isEmpty ? nil : place, item.Name].compactMap { $0 }.joined(separator: " · ")
    }
    static func name(_ item: JellyfinClient.Item) -> String {
        guard item.kind == "Episode", let show = item.SeriesName else { return item.Name ?? "Video" }
        return show + " · " + detail(item)
    }
}

/// What the player opens: the stream and the title shown over it.
struct JellyPlayback: Identifiable {
    let id: String
    let url: URL
    let title: String
}

/// The first player: AetherEngine's picture with basic controls (close, play and pause, 10 seconds
/// back and on, a scrub bar). A tap shows or hides them.
struct JellyPlayerView: View {
    let playback: JellyPlayback
    @Environment(\.dismiss) private var dismiss
    @State private var engine: AetherEngine?
    @State private var state: PlaybackState = .idle
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var scrub: Double?
    @State private var showsControls = true
    @State private var failure: String?

    init(playback: JellyPlayback) {
        self.playback = playback
        _engine = State(initialValue: try? AetherEngine())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine {
                AetherPlayerSurface(engine: engine).ignoresSafeArea()
                    .onReceive(engine.$state) { state = $0 }
                    .onReceive(engine.clock.$currentTime) { time = $0 }
                    .onReceive(engine.$duration) { duration = $0 }
            }
            Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() } }
            if showsControls || failure != nil { controls.transition(.opacity) }
        }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(.hidden)
        .task {
            guard let engine else { failure = "The player couldn’t start."; return }
            do {
                try await engine.load(url: playback.url)
                engine.play()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .onDisappear { engine?.stop() }
    }

    private var playingNow: Bool { state == .playing }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { engine?.stop(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Close player").accessibilityIdentifier("jellyspace-close")
                Text(playback.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.top, 8)
            Spacer(minLength: 0)
            if let failure {
                Text(failure).font(.system(size: 14)).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 24)
            } else if state == .loading || state == .idle {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                HStack(spacing: 48) {
                    transport("gobackward.10", label: "Back 10 seconds") { jump(-10) }
                    transport(playingNow ? "pause.fill" : "play.fill", label: playingNow ? "Pause" : "Play", size: 34) {
                        if playingNow { engine?.pause() } else { engine?.play() }
                    }
                    transport("goforward.10", label: "Forward 10 seconds") { jump(10) }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Slider(value: Binding(get: { scrub ?? time }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
                    guard !editing, let target = scrub else { return }
                    Task { await seek(target); scrub = nil }
                }.tint(.white).disabled(duration <= 0)
                HStack {
                    Text(Self.clock(scrub ?? time)); Spacer(minLength: 0); Text("-" + Self.clock(max(0, duration - (scrub ?? time))))
                }.font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            }.padding(.horizontal, 20).padding(.bottom, 14)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom).frame(height: 160).ignoresSafeArea().allowsHitTesting(false)
        }
    }

    private func transport(_ symbol: String, label: String, size: CGFloat = 26, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func jump(_ seconds: Double) {
        let target = min(max(0, time + seconds), max(duration, 0))
        Task { await seek(target) }
    }
    private func seek(_ seconds: Double) async {
        guard let engine else { return }
        _ = await engine.seek(to: seconds)
    }
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let whole = Int(seconds)
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
