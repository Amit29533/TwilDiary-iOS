import SwiftUI
import Combine
import MediaPlayer
import AetherEngine
import TwilDiaryCore

/// JellySpace's music: one queue (an album's or folder's songs) played by its own AetherEngine, on
/// in the background and on the lock screen (with next and previous), until it's stopped.
@MainActor @Observable final class JellyMusic {
    static let shared = JellyMusic()
    private(set) var queue: [JellyfinClient.Item] = []
    private(set) var index = 0
    private(set) var state: PlaybackState = .idle
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// Repeat: off, the whole queue, or this song.
    enum Repeat { case off, all, one }
    private(set) var shuffled = false
    private(set) var repeatMode = Repeat.off
    @ObservationIgnored private var engine: AetherEngine?
    @ObservationIgnored private var watchers: Set<AnyCancellable> = []
    /// The queue before shuffling (shuffle off puts it back).
    @ObservationIgnored private var original: [JellyfinClient.Item] = []
    /// The song last reported to Jellyfin as playing.
    @ObservationIgnored private var reported: String?

    var current: JellyfinClient.Item? { queue.indices.contains(index) ? queue[index] : nil }
    var playing: Bool { state == .playing }

    func play(_ tracks: [JellyfinClient.Item], from start: Int) {
        shuffled = false; original = []
        queue = tracks
        index = min(max(0, start), max(0, tracks.count - 1))
        Task { await load() }
    }
    func toggle() {
        guard let engine else { return }
        if playing { engine.pause() } else { engine.play() }
    }
    func pause() { if playing { engine?.pause() } }
    func next() {
        if index + 1 < queue.count { index += 1 }
        else if repeatMode == .all, !queue.isEmpty { index = 0 }
        else { return }
        Task { await load() }
    }
    /// A song in Up Next, played now.
    func jump(to position: Int) {
        guard queue.indices.contains(position) else { return }
        index = position
        Task { await load() }
    }
    /// Shuffle: the rest of the queue in a random order after this song; off: back as it was.
    func toggleShuffle() {
        guard let current else { return }
        if shuffled {
            queue = original
            index = original.firstIndex { $0.Id == current.Id } ?? 0
        } else {
            original = queue
            queue = [current] + queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled()
            index = 0
        }
        shuffled.toggle()
        updateCommands()
    }
    func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
        updateCommands()
    }
    /// At a song's end: again (repeat one), else the next (from the top with repeat all).
    private func finished() {
        if repeatMode == .one { Task { await load() } } else { next() }
    }
    private func updateCommands() {
        let hasNext = index + 1 < queue.count || repeatMode == .all
        // Statements, not a lone `self?.next()` (that makes the closure return `Void?`).
        var next: (@MainActor @Sendable () -> Void)?
        if hasNext { next = { [weak self] in guard let self else { return }; self.next() } }
        let previous: @MainActor @Sendable () -> Void = { [weak self] in guard let self else { return }; self.previous() }
        engine?.setNowPlayingTrackCommands(next: next, previous: previous)
    }
    /// The song's play to Jellyfin (signed in only), so the server and its plugins see it.
    private func report(_ event: String, _ id: String) {
        guard JellyAccount.token != nil, let client = JellySpace.client else { return }
        let at = time, paused = state == .paused
        Task { await client.report(event, item: id, source: nil, seconds: at, paused: paused) }
    }
    /// Back to the start of the song, or (in its first seconds) the one before.
    func previous() {
        if time > 3 || index == 0 { Task { await seek(0) }; return }
        index -= 1
        Task { await load() }
    }
    func seek(_ seconds: Double) async { _ = await engine?.seek(to: seconds) }
    func stop() {
        if let reported { report("stop", reported) }
        reported = nil
        engine?.stop()
        queue = []; index = 0; state = .idle; time = 0; duration = 0
    }

    private func load() async {
        guard let client = JellySpace.client, let track = current, let url = client.audioURL(track.Id) else { return }
        if engine == nil { start() }
        guard let engine else { return }
        engine.ownsAudioNowPlaying = true
        engine.setNowPlayingInfo(nowPlaying(track, artwork: nil))
        updateCommands()
        if let reported { report("stop", reported) }
        reported = nil
        time = 0; duration = 0
        do {
            try await engine.load(url: url)
            engine.play()
            reported = track.Id
            report("start", track.Id)
        } catch {
            state = .idle
            return
        }
        if let art = JellyMusic.artwork(track, base: client.base), let image = await JellyfinPosterCache.shared.image(art), current?.Id == track.Id {
            engine.setNowPlayingInfo(nowPlaying(track, artwork: image))
        }
    }
    private func start() {
        guard let made = try? AetherEngine() else { return }
        engine = made
        made.$state.receive(on: DispatchQueue.main).sink { [weak self] value in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.state
                self.state = value
                if value == .ended { self.finished() }
                else if let id = self.reported, (value == .paused && was == .playing) || (value == .playing && was == .paused) {
                    self.report("progress", id)
                }
            }
        }.store(in: &watchers)
        made.clock.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.time = value }
        }.store(in: &watchers)
        made.$duration.receive(on: DispatchQueue.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.duration = value }
        }.store(in: &watchers)
    }
    private func nowPlaying(_ track: JellyfinClient.Item, artwork: UIImage?) -> [String: Any] {
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.Name ?? "Song"]
        if let artist = JellyMusic.artist(track) { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.Album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork {
            let picture = artwork
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: picture.size) { @Sendable _ in picture }
        }
        return info
    }

    static func artist(_ track: JellyfinClient.Item) -> String? { track.AlbumArtist ?? track.Artists?.first }
    /// The song's own picture, else its album's.
    static func artwork(_ track: JellyfinClient.Item, base: URL) -> URL? {
        if let tag = track.ImageTags?["Primary"] { return JellyfinClient.imageURL(base: base, item: track.Id, type: "Primary", tag: tag, width: 600) }
        if let album = track.AlbumId, let tag = track.AlbumPrimaryImageTag { return JellyfinClient.imageURL(base: base, item: album, type: "Primary", tag: tag, width: 600) }
        return nil
    }
}

/// A folder's or album's songs as a list: number, name, artist and length; a tap plays from there.
struct JellyTrackList: View {
    let tracks: [JellyfinClient.Item]
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.Id) { position, track in
                let now = JellyMusic.shared.current?.Id == track.Id
                Button { JellyMusic.shared.play(tracks, from: position) } label: {
                    HStack(spacing: 12) {
                        Group {
                            if now { Image(systemName: "speaker.wave.2.fill").foregroundStyle(ThemeStore.accent) }
                            else { Text(track.IndexNumber.map(String.init) ?? "·").foregroundStyle(HomeStyle.secondary) }
                        }.font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.Name ?? "Song").font(.system(size: 15, weight: now ? .semibold : .regular)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            if let artist = JellyMusic.artist(track) {
                                Text(artist).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if let seconds = track.RunTimeTicks.map({ Double($0) / 10_000_000 }), seconds > 0 {
                            Text(JellyPlayerView.clock(seconds)).font(.system(size: 12)).monospacedDigit().foregroundStyle(HomeStyle.secondary)
                        }
                    }.padding(.horizontal, 6).frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-track-" + track.Id)
                if position < tracks.count - 1 { SettingsDivider() }
            }
        }
    }
}

/// The song playing, over the bottom of JellySpace's pages: picture, name, play or pause, next; a tap
/// opens Now Playing.
struct JellyMiniPlayer: View {
    @State private var open = false
    /// The casting bar (while a Chromecast plays), then the song playing.
    var body: some View {
        VStack(spacing: 8) {
            JellyCastBar()
            musicBar
        }
    }
    @ViewBuilder private var musicBar: some View {
        let music = JellyMusic.shared
        if let track = music.current, let client = JellySpace.client {
            HStack(spacing: 12) {
                ZStack {
                    Rectangle().fill(HomeStyle.card)
                    Image(systemName: "music.note").foregroundStyle(HomeStyle.secondary)
                    JellyImage(url: JellyMusic.artwork(track, base: client.base))
                }.frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.Name ?? "Song").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    if let artist = JellyMusic.artist(track) { Text(artist).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                Button { music.toggle() } label: {
                    Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HomeStyle.primary).frame(width: 40, height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(music.playing ? "Pause" : "Play")
                Button { music.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HomeStyle.primary).frame(width: 40, height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Next song")
            }
            .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle()).onTapGesture { open = true }
            .padding(.horizontal, 12)
            .accessibilityIdentifier("jellyspace-mini-player")
            .sheet(isPresented: $open) { JellyNowPlaying().presentationDragIndicator(.visible) }
        }
    }
}

/// Now Playing: the big picture, the song and artist, the bar, previous, play or pause, next, and stop.
struct JellyNowPlaying: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var scrub: Double?
    /// What fills the top: the picture, the song's words, or Up Next.
    @State private var view = Face.artwork
    @State private var lyrics: [JellyfinClient.Lyrics.Line] = []
    @State private var lyricsLoading = false
    private enum Face { case artwork, lyrics, queue }
    var body: some View {
        let music = JellyMusic.shared
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            if let track = music.current, let client = JellySpace.client {
                Group {
                    switch view {
                    case .artwork:
                        ZStack {
                            Rectangle().fill(HomeStyle.card)
                            Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(HomeStyle.secondary)
                            JellyImage(url: JellyMusic.artwork(track, base: client.base))
                        }
                        .aspectRatio(1, contentMode: .fit).frame(maxWidth: 320).clipShape(RoundedRectangle(cornerRadius: 18))
                    case .lyrics: lyricsView(music)
                    case .queue: queueView(music)
                    }
                }
                .frame(maxHeight: 340)
                .task(id: track.Id) {
                    // Your server's lyrics, else LRCLIB's (kept on the phone).
                    lyricsLoading = true
                    lyrics = await JellyLyrics.find(track, client: client)
                    lyricsLoading = false
                }
                VStack(spacing: 4) {
                    Text(track.Name ?? "Song").font(.system(size: 21, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.center)
                    Text([JellyMusic.artist(track), track.Album].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 15)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                }
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? music.time }, set: { scrub = $0 }), in: 0...max(music.duration, 1)) { editing in
                        guard !editing, let target = scrub else { return }
                        Task { await music.seek(target); scrub = nil }
                    }.tint(theme.accent)
                    HStack {
                        Text(JellyPlayerView.clock(scrub ?? music.time))
                        Spacer()
                        Text("-" + JellyPlayerView.clock(max(0, music.duration - (scrub ?? music.time))))
                    }.font(.system(size: 12)).monospacedDigit().foregroundStyle(HomeStyle.secondary)
                }.padding(.horizontal, 8)
                HStack(spacing: 44) {
                    control("backward.fill", label: "Previous song", size: 26) { music.previous() }
                    control(music.playing ? "pause.circle.fill" : "play.circle.fill", label: music.playing ? "Pause" : "Play", size: 64) { music.toggle() }
                    control("forward.fill", label: "Next song", size: 26) { music.next() }
                }
                HStack(spacing: 34) {
                    toggle(music.shuffled ? "shuffle.circle.fill" : "shuffle", label: "Shuffle", on: music.shuffled) { music.toggleShuffle() }
                    toggle(music.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat", on: music.repeatMode != .off) { music.cycleRepeat() }
                    toggle("quote.bubble", label: "Lyrics", on: view == .lyrics) { view = view == .lyrics ? .artwork : .lyrics }
                    toggle("list.bullet", label: "Up Next", on: view == .queue) { view = view == .queue ? .artwork : .queue }
                }
                Button("Stop") { music.stop(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.secondary).accessibilityIdentifier("jellyspace-music-stop")
            }
            Spacer(minLength: 10)
        }
        .padding(24)
        .diaryScreenBackground()
    }
    private func toggle(_ symbol: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(on ? theme.accent : HomeStyle.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }
    /// The words, the line being sung lit and kept in view (when they're timed).
    private func lyricsView(_ music: JellyMusic) -> some View {
        let now = lyrics.lastIndex { ($0.Start ?? .max) <= Int64(music.time * 10_000_000) }
        // Plain lyrics (no times) show all lines bright; timed ones light the line being sung.
        let timed = lyrics.contains { $0.Start != nil }
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if lyricsLoading && lyrics.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                    else if lyrics.isEmpty { Text("No lyrics").font(.system(size: 15)).foregroundStyle(HomeStyle.secondary) }
                    ForEach(lyrics.indices, id: \.self) { index in
                        Text(lyrics[index].Text ?? "").font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(!timed || index == now ? HomeStyle.primary : HomeStyle.secondary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading).id(index)
                    }
                }.padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: now) { _, line in if let line { withAnimation { reader.scrollTo(line, anchor: .center) } } }
        }
    }
    /// The songs after this one; a tap plays one now.
    private func queueView(_ music: JellyMusic) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let upcoming = Array(music.queue.indices.dropFirst(music.index + 1))
                if upcoming.isEmpty { Text("Nothing after this").font(.system(size: 15)).foregroundStyle(HomeStyle.secondary).padding(.vertical, 8) }
                ForEach(upcoming, id: \.self) { position in
                    let track = music.queue[position]
                    Button { music.jump(to: position) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.Name ?? "Song").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            if let artist = JellyMusic.artist(track) { Text(artist).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.scrollIndicators(.hidden)
    }
    private func control(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                .frame(minWidth: 52, minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
