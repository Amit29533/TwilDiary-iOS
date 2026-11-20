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
    @ObservationIgnored private var engine: AetherEngine?
    @ObservationIgnored private var watchers: Set<AnyCancellable> = []

    var current: JellyfinClient.Item? { queue.indices.contains(index) ? queue[index] : nil }
    var playing: Bool { state == .playing }

    func play(_ tracks: [JellyfinClient.Item], from start: Int) {
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
        guard index + 1 < queue.count else { return }
        index += 1
        Task { await load() }
    }
    /// Back to the start of the song, or (in its first seconds) the one before.
    func previous() {
        if time > 3 || index == 0 { Task { await seek(0) }; return }
        index -= 1
        Task { await load() }
    }
    func seek(_ seconds: Double) async { _ = await engine?.seek(to: seconds) }
    func stop() {
        engine?.stop()
        queue = []; index = 0; state = .idle; time = 0; duration = 0
    }

    private func load() async {
        guard let client = JellySpace.client, let track = current, let url = client.audioURL(track.Id) else { return }
        if engine == nil { start() }
        guard let engine else { return }
        engine.ownsAudioNowPlaying = true
        engine.setNowPlayingInfo(nowPlaying(track, artwork: nil))
        engine.setNowPlayingTrackCommands(next: index + 1 < queue.count ? { [weak self] in self?.next() } : nil,
                                          previous: { [weak self] in self?.previous() })
        time = 0; duration = 0
        do {
            try await engine.load(url: url)
            engine.play()
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
                self?.state = value
                if value == .ended { self?.next() }
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
    var body: some View {
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
    var body: some View {
        let music = JellyMusic.shared
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            if let track = music.current, let client = JellySpace.client {
                ZStack {
                    Rectangle().fill(HomeStyle.card)
                    Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(HomeStyle.secondary)
                    JellyImage(url: JellyMusic.artwork(track, base: client.base))
                }
                .aspectRatio(1, contentMode: .fit).frame(maxWidth: 320).clipShape(RoundedRectangle(cornerRadius: 18))
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
                Button("Stop") { music.stop(); dismiss() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.secondary).accessibilityIdentifier("jellyspace-music-stop")
            }
            Spacer(minLength: 10)
        }
        .padding(24)
        .diaryScreenBackground()
    }
    private func control(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                .frame(minWidth: 52, minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
