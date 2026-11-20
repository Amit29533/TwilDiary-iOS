import SwiftUI
import AVKit
import MediaPlayer
import AetherEngine
import TwilDiaryCore

/// What the player opens: the stream, its title, and the Jellyfin item behind it (resume point,
/// progress, the next episode, and the diary match when it's finished).
struct JellyPlayback: Identifiable {
    let id: String
    let url: URL
    let title: String
    let item: JellyfinClient.Item
    let client: JellyfinClient
}

/// How the picture fills the screen: the whole picture, cropped to fill, or at its own pixel size.
enum JellyFill: String, CaseIterable {
    case fit = "Fit", fill = "Fill", original = "Original"
    var symbol: String { switch self { case .fit: "rectangle.arrowtriangle.2.inward"; case .fill: "rectangle.arrowtriangle.2.outward"; case .original: "1.square" } }
}

/// JellySpace's player: AetherEngine's picture, sideways, with the streaming-app layout. Back and the
/// title on top; back 10, play/pause and on 10 in the middle (or a double tap on either side); the bar
/// with the time gone and left; then Episodes, Speed, Audio & Subtitles, the fill, Picture in Picture
/// and Next Episode. It resumes where Jellyfin says you stopped, saves your place there as you watch,
/// and at 90% marks it played in Jellyfin and watched in your diary. At an episode's end the next
/// one starts after a short countdown.
struct JellyPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("jellyspace.subtitleSize") private var subtitleSize = 1.0
    @AppStorage("jellyspace.fill") private var fillRaw = JellyFill.fit.rawValue
    @State private var current: JellyPlayback
    @State private var engine: AetherEngine?
    @State private var pip = JellyPiP()
    @State private var state: PlaybackState = .idle
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var videoSize = CGSize.zero
    @State private var scrub: Double?
    @State private var showsControls = true
    @State private var failure: String?
    @State private var audioTracks: [TrackInfo] = []
    @State private var subtitleTracks: [TrackInfo] = []
    @State private var activeAudio: Int?
    @State private var activeSubtitle: Int?
    @State private var cues: [SubtitleCue] = []
    @State private var resumedAt: Double?
    @State private var finished = false
    @State private var notice: String?
    @State private var userID: String?
    @State private var pickedSubtitle = false
    @State private var speed: Float = 1
    @State private var panel: Panel?
    @State private var season: [JellyfinClient.Item] = []
    @State private var countdown: Int?
    @State private var skipFlash: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var pickedAudio = false
    @State private var segments: [JellyfinClient.Segment] = []
    @State private var chapters: [JellyfinClient.PlayerInfo.Chapter] = []
    @State private var trickplay: (info: JellyfinClient.PlayerInfo.TrickplayInfo, source: String)?
    @State private var thumbnail: UIImage?
    /// The one sheet of scrubbing thumbnails in use (each is a big picture, so only one is kept).
    @State private var sheet: (index: Int, image: UIImage)?
    /// The next episode beyond this season (the first of the next one).
    @State private var following: JellyfinClient.Item?
    @State private var countdownTask: Task<Void, Never>?
    @State private var subtitleDelay: Double = 0
    @State private var audioDelay: Double = 0
    @State private var volume = JellyVolume()
    @State private var swipeStart: Double?
    @State private var level: (symbol: String, value: Double)?
    @State private var levelTask: Task<Void, Never>?
    @State private var brightnessAtOpen: CGFloat?
    @State private var holding = false
    /// Rotation locked (the default): the picture's own way up, sideways or upright; unlocked: it
    /// turns with the phone.
    @State private var rotationLocked = true
    /// Screen locked: no controls and no touches until it's unlocked.
    @State private var screenLocked = false
    @State private var unlockShown = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Panel { case tracks, episodes, chapters }

    init(playback: JellyPlayback) {
        _current = State(initialValue: playback)
        _engine = State(initialValue: try? AetherEngine())
    }

    private var fill: JellyFill { JellyFill(rawValue: fillRaw) ?? .fit }
    private var nextEpisode: JellyfinClient.Item? {
        guard current.item.kind == "Episode" else { return nil }
        if let number = current.item.IndexNumber,
           let inSeason = season.filter({ ($0.IndexNumber ?? 0) > number }).min(by: { ($0.IndexNumber ?? 0) < ($1.IndexNumber ?? 0) }) {
            return inSeason
        }
        return following
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine {
                picture(engine)
            }
            GeometryReader { safe in
                JellySubtitles(cues: cues, time: time - subtitleDelay, scale: subtitleSize, insets: safe.safeAreaInsets,
                               fill: fill, originalSize: CGSize(width: videoSize.width / displayScale, height: videoSize.height / displayScale))
                    .ignoresSafeArea()
            }.allowsHitTesting(false)
            // Single tap: the controls; a double tap on the left or right half: 10 seconds back or on;
            // a swipe up or down on the left: brightness, on the right: volume.
            GeometryReader { area in
                HStack(spacing: 0) {
                    tapZone(seconds: -10, height: area.size.height)
                    tapZone(seconds: 10, height: area.size.height)
                }
            }.ignoresSafeArea().allowsHitTesting(!screenLocked)
            JellyVolumeView(volume: volume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            if let level { levelHUD(level).transition(.opacity).allowsHitTesting(false) }
            if holding {
                Label("2x", systemImage: "forward.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 38).background(.black.opacity(0.6), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 18).transition(.opacity).allowsHitTesting(false)
            }
            if let skipFlash {
                Text(skipFlash < 0 ? "−10s" : "+10s").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .padding(18).background(.black.opacity(0.45), in: Circle())
                    .frame(maxWidth: .infinity, alignment: skipFlash < 0 ? .leading : .trailing).padding(.horizontal, 90)
                    .transition(.opacity).allowsHitTesting(false)
            }
            if screenLocked {
                lockedLayer
            } else {
                if showsControls || failure != nil { controls.transition(.opacity) }
                if showsControls, failure == nil, panel == nil { lockPill.transition(.opacity) }
            }
            if let segment = activeSegment, panel == nil, countdown == nil, failure == nil, !screenLocked { skipButton(segment).transition(.opacity) }
            if let countdown, let next = nextEpisode { upNext(next, in: countdown) }
            if let panel { panelView(panel).transition(.opacity) }
            if let notice {
                Text(notice).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34).background(.black.opacity(0.7), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14).transition(.opacity).allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if let width = current.item.Width, let height = current.item.Height, width > 0, height > 0 {
                turnToPicture(CGSize(width: width, height: height))
            }
        }
        .onChange(of: videoSize) { _, size in turnToPicture(size) }
        .onDisappear {
            if let brightnessAtOpen { JellyScreen.brightness = brightnessAtOpen }
            countdownTask?.cancel()
            savePlace()
            engine?.stop()
            OrientationLock.set(.portrait, turnTo: .portrait)
        }
        .task(id: current.id) { await start() }
        .task(id: thumbnailIndex) { await loadThumbnail(thumbnailIndex) }
        .task(id: state == .playing) {
            // Your place, saved every 15 seconds while it plays.
            guard state == .playing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, state == .playing else { return }
                savePlace()
            }
        }
        .onChange(of: state) { _, now in
            if now == .playing { scheduleHide() }
            if now == .ended, nextEpisode != nil, countdown == nil { startCountdown() }
        }
    }

    @ViewBuilder private func picture(_ engine: AetherEngine) -> some View {
        let surface = AetherPlayerSurface(engine: engine)
            .onReceive(engine.$state) { state = $0; if $0 == .playing { pip.rebuildIfNeeded() } }
            .onReceive(engine.clock.$currentTime) { seconds in time = seconds; reachedEnd(seconds) }
            .onReceive(engine.$duration) { duration = $0 }
            .onReceive(engine.$audioTracks) { tracks in audioTracks = tracks; pickRememberedAudio(tracks) }
            .onReceive(engine.$subtitleTracks) { tracks in subtitleTracks = tracks; pickDefaultSubtitle(tracks) }
            .onReceive(engine.$activeAudioTrackIndex) { activeAudio = $0 }
            .onReceive(engine.$activeSubtitleTrackIndex) { activeSubtitle = $0 }
            .onReceive(engine.$subtitleCues) { cues = $0 }
            .onReceive(engine.$softwarePiPSource) { _ in pip.rebuild() }
            .onReceive(engine.$sourceVideoWidth) { videoSize.width = CGFloat($0) }
            .onReceive(engine.$sourceVideoHeight) { videoSize.height = CGFloat($0) }
        if fill == .original, videoSize.width > 0, videoSize.height > 0 {
            // Its own pixel size: one video pixel per screen pixel, cropped if it's bigger than the screen.
            surface.frame(width: videoSize.width / displayScale, height: videoSize.height / displayScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().ignoresSafeArea()
        } else {
            surface.ignoresSafeArea()
        }
    }

    private func tapZone(seconds: Double, height: CGFloat) -> some View {
        Color.clear.contentShape(Rectangle())
            // Hold anywhere: 2x while the finger stays down, back to the chosen speed on release.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        if case .second(true, _) = value, !holding, state == .playing, swipeStart == nil {
                            withAnimation(.easeOut(duration: 0.15)) { holding = true }
                            engine?.setRate(2)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in endHold() }
            )
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { drag in swiped(drag, brightness: seconds < 0, height: height) }
                    .onEnded { _ in
                        swipeStart = nil
                        levelTask?.cancel()
                        levelTask = Task { try? await Task.sleep(for: .milliseconds(900)); if !Task.isCancelled { withAnimation { level = nil } } }
                    }
            )
            .onTapGesture(count: 2) {
                jump(seconds)
                withAnimation(.easeOut(duration: 0.15)) { skipFlash = seconds }
                Task { try? await Task.sleep(for: .milliseconds(700)); withAnimation { if skipFlash == seconds { skipFlash = nil } } }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                if showsControls { scheduleHide() }
            }
    }

    private func endHold() {
        guard holding else { return }
        withAnimation(.easeOut(duration: 0.15)) { holding = false }
        engine?.setRate(speed)
    }

    /// Up raises, down lowers: the whole height of the screen goes from 0 to full. Swipes that start at
    /// the very top or bottom are the system's, and mostly-sideways ones are ignored.
    private func swiped(_ drag: DragGesture.Value, brightness: Bool, height: CGFloat) {
        if swipeStart == nil {
            guard !holding, abs(drag.translation.height) > abs(drag.translation.width) * 1.4,
                  drag.startLocation.y > 44, drag.startLocation.y < height - 44 else { return }
            if brightness, brightnessAtOpen == nil { brightnessAtOpen = JellyScreen.brightness }
            swipeStart = brightness ? Double(JellyScreen.brightness) : Double(volume.level)
        }
        guard let start = swipeStart else { return }
        let value = min(1, max(0, start - Double(drag.translation.height / max(1, height * 0.85))))
        if brightness { JellyScreen.brightness = CGFloat(value) } else { volume.set(Float(value)) }
        levelTask?.cancel()
        level = (brightness ? "sun.max.fill" : value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", value)
    }
    private func levelHUD(_ level: (symbol: String, value: Double)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: level.symbol).font(.system(size: 16, weight: .semibold)).frame(width: 22)
            Capsule().fill(.white.opacity(0.25)).frame(width: 140, height: 6)
                .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 140 * level.value, height: 6) }
        }
        .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 40).background(.black.opacity(0.6), in: Capsule())
        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 18)
    }

    // MARK: Orientation and locks

    /// With rotation locked, the picture's own way up: upright for a tall video, sideways otherwise.
    private func turnToPicture(_ size: CGSize) {
        guard rotationLocked, size.width > 0, size.height > 0 else { return }
        let upright = size.height > size.width * 1.05
        OrientationLock.set(upright ? .portrait : .landscape, turnTo: upright ? .portrait : .landscape)
    }
    /// Lock: stays as it is now. Unlock: turns with the phone.
    private func toggleRotation() {
        rotationLocked.toggle()
        if rotationLocked {
            let now = OrientationLock.current
            OrientationLock.set(now, turnTo: now)
            show("Rotation locked")
        } else {
            OrientationLock.set(.allButUpsideDown, turnTo: .allButUpsideDown)
            show("Rotation unlocked")
        }
        scheduleHide()
    }
    private func lockScreen() {
        withAnimation(.easeInOut(duration: 0.2)) { screenLocked = true; showsControls = false; panel = nil }
        flashUnlock()
    }
    private func flashUnlock() {
        withAnimation { unlockShown = true }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { unlockShown = false }
        }
    }

    /// Screen lock and rotation lock, one above the other, at the side.
    private var lockPill: some View {
        VStack(spacing: 4) {
            pillButton(screenLocked ? "lock.fill" : "lock.open", label: "Lock screen") { lockScreen() }
                .accessibilityIdentifier("jellyspace-lock-screen")
            pillButton(rotationLocked ? "lock.rotation" : "lock.rotation.open", label: rotationLocked ? "Unlock rotation" : "Lock rotation") { toggleRotation() }
                .accessibilityIdentifier("jellyspace-lock-rotation")
        }
        .padding(.vertical, 6).frame(width: 54).background(.black.opacity(0.55), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: verticalSizeClass == .compact ? .trailing : .topTrailing)
        .padding(.trailing, 16).padding(.top, verticalSizeClass == .compact ? 0 : 90)
    }
    private func pillButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    /// Locked: a tap anywhere shows the unlock button for a few seconds.
    private var lockedLayer: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture { flashUnlock() }
            if unlockShown {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { screenLocked = false; unlockShown = false; showsControls = true }
                    scheduleHide()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 22, weight: .semibold))
                        Text("Tap to unlock").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("jellyspace-unlock").transition(.opacity)
            }
        }
    }

    /// The controls fade on their own after a few seconds of playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, state == .playing, panel == nil, scrub == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
        }
    }

    // MARK: Starting, switching and finishing

    private func start() async {
        guard let engine else { failure = "The player couldn’t start."; return }
        pip.engine = engine
        finished = false; failure = nil; resumedAt = nil; countdown = nil; pickedSubtitle = false; pickedAudio = false; time = 0
        segments = []; chapters = []; trickplay = nil; thumbnail = nil; sheet = nil; following = nil
        let client = current.client, id = current.id
        // The user Jellyfin keeps your places for (the administrator, else the first), found once.
        let user = await JellyfinUser.id(client)
        userID = user
        if let seasonID = current.item.SeasonId, season.first?.SeasonId != seasonID {
            season = ((try? await client.children(of: seasonID, user: user)) ?? []).filter { $0.kind == "Episode" }
        }
        var startAt: Double?
        if let user, let data = try? await client.userData(current.id, user: user), let ticks = data.PlaybackPositionTicks, ticks > 0 {
            startAt = Double(ticks) / 10_000_000
        }
        // Chapters, scrubbing thumbnails and separate subtitle files first (the files load with the
        // video); the intro and credits stretches while it loads.
        let extras = try? await client.playerInfo(id, user: user)
        async let stretches = try? client.segments(id)
        var options = LoadOptions()
        options.externalSubtitles = Self.subtitleFiles(extras, item: id, client: client)
        engine.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
        // The lock screen and Control Center: the title, its poster, play/pause and skipping.
        engine.ownsSoftwareNowPlaying = true
        engine.ownsVideoNowPlayingSession = true
        engine.ownsVideoNowPlayingCommands = true
        engine.setNowPlayingInfo(nowPlayingInfo(nil))
        do {
            if let startAt, startAt > 30 {
                try await engine.load(url: current.url, startPosition: startAt, options: options)
                resumedAt = startAt
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation { resumedAt = nil } }
            } else {
                try await engine.load(url: current.url, options: options)
            }
            engine.play()
            if speed != 1 { engine.setRate(speed) }
            if audioDelay != 0 { engine.setAudioDelay(audioDelay) }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
            return
        }
        segments = (await stretches) ?? []
        chapters = (extras?.Chapters ?? []).sorted { $0.StartPositionTicks < $1.StartPositionTicks }
        if let entry = extras?.Trickplay?.first {
            let sorted = entry.value.values.sorted { $0.Width < $1.Width }
            if let pick = sorted.first(where: { $0.Width >= 240 }) ?? sorted.last { trickplay = (pick, entry.key) }
        }
        if current.item.kind == "Episode", let series = current.item.SeriesId {
            following = try? await client.episode(after: id, series: series, user: user)
        }
        if let url = JellySpace.poster(current.item, base: client.base), let art = await JellyfinPosterCache.shared.image(url), !Task.isCancelled {
            engine.setNowPlayingInfo(nowPlayingInfo(art))
        }
    }

    /// The video's separate subtitle files (.srt, .ass, .vtt and the like next to it), as tracks the
    /// player loads with the video. Picture subtitles in a separate file (.sup) are left out.
    static func subtitleFiles(_ info: JellyfinClient.PlayerInfo?, item: String, client: JellyfinClient) -> [ExternalSubtitleTrack] {
        guard let source = info?.MediaSources?.first, let sourceID = source.Id else { return [] }
        return (source.MediaStreams ?? []).compactMap { stream in
            guard stream.kind == "Subtitle", stream.IsExternal == true else { return nil }
            let codec = (stream.Codec ?? "").lowercased()
            let format: String
            switch codec {
            case "ass", "ssa": format = "ass"
            case "webvtt", "vtt": format = "vtt"
            case "pgssub", "pgs", "sup", "dvdsub", "dvd_subtitle", "vobsub": return nil
            default: format = "srt"
            }
            guard let url = client.subtitleURL(item, source: sourceID, index: stream.Index, format: format) else { return nil }
            return ExternalSubtitleTrack(url: url, name: stream.DisplayTitle, language: stream.Language,
                                         isForced: stream.IsForced == true, isDefault: stream.IsDefault == true, formatHint: format)
        }
    }

    private func nowPlayingInfo(_ artwork: UIImage?) -> [String: Any] {
        let item = current.item
        var info: [String: Any] = [MPMediaItemPropertyTitle: item.Name ?? current.title]
        if item.kind == "Episode" {
            if let show = item.SeriesName { info[MPMediaItemPropertyArtist] = show }
            let place = [item.ParentIndexNumber.map { "Season \($0)" }, item.IndexNumber.map { "Episode \($0)" }].compactMap { $0 }.joined(separator: " · ")
            if !place.isEmpty { info[MPMediaItemPropertyAlbumTitle] = place }
        }
        if let artwork {
            let picture = artwork
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: picture.size) { @Sendable _ in picture }
        }
        return info
    }

    // MARK: Intro and credits, chapters, thumbnails

    /// The intro, recap, preview or credits stretch playing now (not in its last second).
    private var activeSegment: JellyfinClient.Segment? {
        let ticks = Int64(time * 10_000_000)
        return segments.first { ["Intro", "Recap", "Outro", "Preview", "Commercial"].contains($0.kind) && $0.StartTicks <= ticks && ticks < $0.EndTicks - 10_000_000 }
    }
    /// Skip Intro (Recap, Preview); in the credits, Next Episode when there is one, else Skip Credits.
    private func skipButton(_ segment: JellyfinClient.Segment) -> some View {
        let next = segment.kind == "Outro" ? nextEpisode : nil
        return Button {
            if let next { play(next) } else { Task { await seek(Double(segment.EndTicks) / 10_000_000) } }
        } label: {
            Label(next != nil ? "Next Episode" : Self.skipName(segment.kind), systemImage: next != nil ? "forward.end.fill" : "forward.fill")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 18).frame(height: 44).background(.white, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("jellyspace-skip")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 28).padding(.bottom, showsControls ? 124 : 36)
    }
    private static func skipName(_ kind: String) -> String {
        switch kind { case "Intro": "Skip Intro"; case "Recap": "Skip Recap"; case "Outro": "Skip Credits"; case "Preview": "Skip Preview"; default: "Skip" }
    }
    private var currentChapter: Int { chapters.lastIndex { Double($0.StartPositionTicks) / 10_000_000 <= time } ?? 0 }

    /// Which scrubbing thumbnail the bar is on while you drag it.
    private var thumbnailIndex: Int? {
        guard let scrub, let trickplay else { return nil }
        return min(Int(scrub * 1000) / max(1, trickplay.info.Interval), max(0, trickplay.info.ThumbnailCount - 1))
    }
    private var thumbnailHeight: CGFloat {
        guard let info = trickplay?.info, info.Width > 0 else { return 90 }
        return 160 * CGFloat(info.Height) / CGFloat(info.Width)
    }
    /// The thumbnail cut from its sheet (each sheet holds TileWidth x TileHeight of them).
    private func loadThumbnail(_ index: Int?) async {
        guard let index, let trickplay else { thumbnail = nil; return }
        let info = trickplay.info, perSheet = max(1, info.TileWidth * info.TileHeight)
        let number = index / perSheet
        if sheet?.index != number {
            guard let url = current.client.trickplayURL(current.id, width: info.Width, sheet: number, source: trickplay.source),
                  let fetched = try? await URLSession.shared.data(from: url), (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
                  let loaded = UIImage(data: fetched.0), !Task.isCancelled else { return }
            sheet = (number, loaded)
        }
        guard let picture = sheet?.image.cgImage else { return }
        let spot = index % perSheet
        let rect = CGRect(x: (spot % max(1, info.TileWidth)) * info.Width, y: (spot / max(1, info.TileWidth)) * info.Height, width: info.Width, height: info.Height)
        if let cut = picture.cropping(to: rect) { thumbnail = UIImage(cgImage: cut) }
    }

    // MARK: Remembered audio and subtitles

    /// Your last audio and subtitle language: for this show if you chose one in it, else from anything.
    private func remembered(_ kind: String) -> String? {
        let defaults = UserDefaults.standard
        if let show = current.item.SeriesId, let value = defaults.string(forKey: "jellyspace.\(kind).\(show)") { return value }
        return defaults.string(forKey: "jellyspace.\(kind)")
    }
    private func remember(_ kind: String, _ value: String) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: "jellyspace.\(kind)")
        if let show = current.item.SeriesId { defaults.set(value, forKey: "jellyspace.\(kind).\(show)") }
    }
    private func pickRememberedAudio(_ tracks: [TrackInfo]) {
        guard !pickedAudio, !tracks.isEmpty else { return }
        pickedAudio = true
        guard let language = remembered("audioLanguage"),
              let track = tracks.first(where: { $0.language == language && !$0.isCommentary }),
              track.id != engine?.activeAudioTrackIndex else { return }
        engine?.selectAudioTrack(index: track.id)
    }

    /// Another episode in the same player: your place in this one is kept first.
    private func play(_ item: JellyfinClient.Item) {
        savePlace()
        countdown = nil; panel = nil
        guard let next = JellySpace.playback(item, client: current.client) else { return }
        current = next
    }

    private func startCountdown() {
        countdown = 5
        countdownTask?.cancel()
        countdownTask = Task {
            while let left = countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, countdown != nil else { return }
                countdown = left - 1
            }
            if countdown == 0, let next = nextEpisode { play(next) }
        }
    }

    /// Where you are, to Jellyfin (not in the last 10% once it's marked watched: it starts over then).
    private func savePlace() {
        guard let user = userID, time > 5, !(finished && time >= duration * 0.9) else { return }
        let client = current.client, id = current.id, at = time
        Task { try? await client.savePosition(id, user: user, seconds: at) }
    }

    /// At 90%: played in Jellyfin, watched in the diary, once.
    private func reachedEnd(_ seconds: Double) {
        guard !finished, duration > 60, seconds >= duration * 0.9 else { return }
        finished = true
        let client = current.client, id = current.id, user = userID
        Task {
            if let user {
                try? await client.markPlayed(id, user: user)
                try? await client.savePosition(id, user: user, seconds: 0)
            }
            await markInDiary()
        }
    }

    private func markInDiary() async {
        let item = current.item
        let episode = item.kind == "Episode"
        var ids = item.ProviderIds
        if episode, let series = item.SeriesId { ids = (try? await current.client.item(series))?.ProviderIds }
        guard let tmdb = ids?["Tmdb"].flatMap(Int.init),
              let titleID = store.libraryIdentity(CatalogItem(id: tmdb, mediaType: episode ? .tv : .movie, name: item.SeriesName ?? item.Name ?? "")),
              let title = store.title(titleID) else { show("Not in your diary, so not marked"); return }
        if episode {
            guard let seasonNumber = item.ParentIndexNumber, let number = item.IndexNumber,
                  let match = store.episodesForSeason(title.id, season: seasonNumber).first(where: { $0.number == number }) else {
                show("Episode not found in your diary"); return
            }
            if await store.recordViewing(title, episode: match, watchedAt: store.now) { show("Marked S\(seasonNumber) E\(number) in your diary") }
        } else {
            let seen = store.titleScope(title.id).activeEvents.contains { $0.titleId == title.id && $0.episodeId == nil }
            if await store.recordViewing(title, rewatch: seen, watchedAt: store.now) { show("Marked in your diary") }
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task { try? await Task.sleep(for: .seconds(4)); withAnimation { if notice == text { notice = nil } } }
    }

    /// Your remembered subtitle language (or off); else the file's default (or forced) subtitle, once
    /// when the tracks first arrive.
    private func pickDefaultSubtitle(_ tracks: [TrackInfo]) {
        guard !pickedSubtitle, !tracks.isEmpty else { return }
        pickedSubtitle = true
        if let saved = remembered("subtitleLanguage") {
            if saved == "off" { return }
            if let track = tracks.first(where: { $0.language == saved && !$0.isForced }) ?? tracks.first(where: { $0.language == saved }) {
                engine?.selectSubtitleTrack(index: track.id)
                return
            }
        }
        if let track = tracks.first(where: { $0.isDefault }) ?? tracks.first(where: { $0.isForced }) {
            engine?.selectSubtitleTrack(index: track.id)
        }
    }

    // MARK: Controls

    private var playingNow: Bool { state == .playing }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                round("chevron.left", label: "Close player") { dismiss() }.accessibilityIdentifier("jellyspace-close")
                Spacer(minLength: 0)
                Text(current.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 44)
            }.padding(.horizontal, 20).padding(.top, 10)
            Spacer(minLength: 0)
            if let failure {
                Text(failure).font(.system(size: 14)).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 24)
            } else if state == .loading || state == .idle {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                HStack(spacing: verticalSizeClass == .compact ? 84 : 30) {
                    transport("gobackward.10", label: "Back 10 seconds", size: 34) { jump(-10) }
                    transport(playingNow ? "pause.fill" : "play.fill", label: playingNow ? "Pause" : "Play", size: 50) {
                        if playingNow { engine?.pause() } else { engine?.play() }
                        scheduleHide()
                    }
                    transport("goforward.10", label: "Forward 10 seconds", size: 34) { jump(10) }
                }
            }
            Spacer(minLength: 0)
            if let resumedAt {
                Button { Task { await seek(0) }; withAnimation { self.resumedAt = nil } } label: {
                    Text("Resumed at \(Self.clock(resumedAt)) · Start over").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34).background(.black.opacity(0.6), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).padding(.bottom, 8).accessibilityIdentifier("jellyspace-start-over")
            }
            HStack(spacing: 12) {
                Text(Self.clock(scrub ?? time)).frame(minWidth: 52, alignment: .leading)
                Slider(value: Binding(get: { scrub ?? time }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
                    guard !editing, let target = scrub else { return }
                    Task { await seek(target); scrub = nil; scheduleHide() }
                }.tint(theme.accent).disabled(duration <= 0)
                .overlay(alignment: .topLeading) {
                    if let scrub, let thumbnail, duration > 0 {
                        GeometryReader { proxy in
                            let x = min(max(80, proxy.size.width * scrub / duration), max(80, proxy.size.width - 80))
                            Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 160, height: thumbnailHeight).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.85), lineWidth: 1.5))
                                .position(x: x, y: -(thumbnailHeight / 2 + 10))
                        }.allowsHitTesting(false)
                    }
                }
                Text("-" + Self.clock(max(0, duration - (scrub ?? time)))).frame(minWidth: 56, alignment: .trailing)
            }.font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white).padding(.horizontal, 28)
            ViewThatFits(in: .horizontal) {
                actionRow(labels: true)
                actionRow(labels: false)
                ScrollView(.horizontal) { actionRow(labels: false).padding(.horizontal, 20) }.scrollIndicators(.hidden)
            }.padding(.top, 6).padding(.bottom, 14)
        }
        .background {
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
    }

    private func actionRow(labels: Bool) -> some View {
        HStack(spacing: labels ? 22 : 34) {
            if current.item.kind == "Episode", season.count > 1 {
                action("rectangle.stack", "Episodes", labels: labels) { withAnimation { panel = .episodes } }
            }
            if chapters.count > 1 {
                action("list.bullet.rectangle", "Chapters", labels: labels) { withAnimation { panel = .chapters } }.accessibilityIdentifier("jellyspace-chapters")
            }
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button { speed = Float(value); engine?.setRate(Float(value)) } label: {
                        Label(Self.speedName(Float(value)), systemImage: speed == Float(value) ? "checkmark" : "")
                    }
                }
            } label: { actionFace("gauge.with.needle", "Speed (\(Self.speedName(speed)))", labels: labels) }
                .accessibilityIdentifier("jellyspace-speed")
            action("captions.bubble", "Audio & Subtitles", labels: labels) { withAnimation { panel = .tracks } }.accessibilityIdentifier("jellyspace-tracks")
            action(fill.symbol, fill.rawValue, labels: labels) { cycleFill() }.accessibilityIdentifier("jellyspace-fill")
            if pip.available { action("pip.enter", "PiP", labels: labels) { pip.start() } }
            if let next = nextEpisode {
                action("forward.end", "Next Episode", labels: labels) { play(next) }.accessibilityIdentifier("jellyspace-next")
            }
        }
    }

    private func cycleFill() {
        let all = JellyFill.allCases
        let next = all[(all.firstIndex(of: fill).map { $0 + 1 } ?? 0) % all.count]
        fillRaw = next.rawValue
        engine?.videoGravity = next == .fill ? .resizeAspectFill : .resizeAspect
        show(next.rawValue)
        scheduleHide()
    }

    private func action(_ symbol: String, _ title: String, labels: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { actionFace(symbol, title, labels: labels) }.buttonStyle(.plain)
    }
    private func actionFace(_ symbol: String, _ title: String, labels: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: labels ? 16 : 19, weight: .semibold))
            if labels { Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize() }
        }.foregroundStyle(.white).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).accessibilityLabel(title)
    }

    /// "Up next" over the end of an episode: it plays after the countdown unless you cancel.
    private func upNext(_ next: JellyfinClient.Item, in seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up next in \(seconds)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.75))
            Text([next.IndexNumber.map { "E\($0)" }, next.Name].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 10) {
                Button { play(next) } label: {
                    Label("Play now", systemImage: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 34).background(.white, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
                Button { countdown = nil } label: {
                    Text("Cancel").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34).background(.white.opacity(0.18), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(16).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 28).padding(.bottom, 90)
    }

    // MARK: Panels

    @ViewBuilder private func panelView(_ panel: Panel) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea().onTapGesture { withAnimation { self.panel = nil } }
            VStack(spacing: 16) {
                switch panel {
                case .tracks: tracksContent
                case .episodes: episodesContent
                case .chapters: chaptersContent
                }
                Button { withAnimation { self.panel = nil } } label: {
                    Text("Close").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(height: 38).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 40).padding(.vertical, 20)
        }
    }

    /// Audio and Subtitles side by side, the chosen one of each ticked, and the subtitle size.
    private var tracksContent: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 40) {
            if audioTracks.count > 1 {
                trackColumn("Audio", rows: audioTracks.map { ($0.id, Self.label($0, audio: true)) }, chosen: activeAudio) { id in
                    guard let id, let track = audioTracks.first(where: { $0.id == id }) else { return }
                    engine?.selectAudioTrack(index: id)
                    if let language = track.language { remember("audioLanguage", language) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if !subtitleTracks.isEmpty {
                    trackColumn("Subtitles", rows: [(-1, "Off")] + subtitleTracks.map { ($0.id, Self.label($0, audio: false)) },
                                chosen: activeSubtitle ?? -1) { id in
                        if let id, id >= 0 {
                            engine?.selectSubtitleTrack(index: id)
                            if let language = subtitleTracks.first(where: { $0.id == id })?.language { remember("subtitleLanguage", language) }
                        } else {
                            engine?.clearSubtitle()
                            remember("subtitleLanguage", "off")
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Size").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    ForEach([("S", 0.8), ("M", 1.0), ("L", 1.3), ("XL", 1.6)], id: \.1) { option in
                        Button { subtitleSize = option.1 } label: {
                            Text(option.0).font(.system(size: 13, weight: .bold)).foregroundStyle(subtitleSize == option.1 ? .black : .white)
                                .frame(width: 40, height: 30).background(subtitleSize == option.1 ? Color.white : Color.white.opacity(0.15), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        HStack(spacing: 32) {
            if !subtitleTracks.isEmpty {
                delayControl("Subtitle delay", value: subtitleDelay) { subtitleDelay = $0; engine?.setSoftwareSubtitleDelay($0) }
            }
            delayControl("Audio delay", value: audioDelay) { audioDelay = $0; engine?.setAudioDelay($0) }
        }
      }
    }

    /// −0.1 s, the delay (a tap puts it back to 0), +0.1 s.
    private func delayControl(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            delayStep("minus", label: title + " earlier") { set(((value - 0.1) * 10).rounded() / 10) }
            Button { set(0) } label: {
                Text(value == 0 ? "0.0s" : String(format: "%+.1fs", value)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white).frame(minWidth: 54, minHeight: 30)
            }.buttonStyle(.plain)
            delayStep("plus", label: title + " later") { set(((value + 0.1) * 10).rounded() / 10) }
        }
    }
    private func delayStep(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 30).background(Color.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    /// The chapters as pictures; the one playing outlined, a tap jumps there.
    private var chaptersContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            let start = Double(chapter.StartPositionTicks) / 10_000_000
                            let here = index == currentChapter
                            Button { Task { await seek(start) }; withAnimation { panel = nil } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ZStack {
                                        Rectangle().fill(.white.opacity(0.1))
                                        JellyImage(url: chapter.ImageTag.flatMap { JellyfinClient.imageURL(base: current.client.base, item: current.id, type: "Chapter/\(index)", tag: $0, width: 400) })
                                    }
                                    .frame(width: 176, height: 99).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(here ? theme.accent : .clear, lineWidth: 2.5))
                                    Text(chapter.Name ?? "Chapter \(index + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(Self.clock(start)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                                }.frame(width: 176, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                        }
                    }
                }.scrollIndicators(.hidden).onAppear { reader.scrollTo(currentChapter, anchor: .center) }
            }
        }
    }

    /// The season's episodes: the one playing marked, a tap plays another.
    private var episodesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current.item.ParentIndexNumber.map { "Season \($0)" } ?? "Episodes").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(season, id: \.Id) { episode in
                        let playingThis = episode.Id == current.id
                        Button { if !playingThis { play(episode) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: playingThis ? "play.fill" : episode.UserData?.Played == true ? "checkmark" : "circle")
                                    .font(.system(size: 12, weight: .bold)).frame(width: 18)
                                Text([episode.IndexNumber.map(String.init), episode.Name].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 15, weight: playingThis ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 0)
                                if let minutes = episode.RunTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 {
                                    Text(DiaryDate.duration(minutes)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                                }
                            }.foregroundStyle(playingThis ? .white : .white.opacity(0.8)).frame(minHeight: 40).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 230)
        }.frame(maxWidth: 520)
    }

    private func trackColumn(_ heading: String, rows: [(Int, String)], chosen: Int?, pick: @escaping (Int?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.0) { row in
                        Button { pick(row.0) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).opacity(row.0 == chosen ? 1 : 0)
                                Text(row.1).font(.system(size: 15, weight: row.0 == chosen ? .semibold : .regular)).lineLimit(1)
                            }.foregroundStyle(row.0 == chosen ? .white : .white.opacity(0.7)).frame(minHeight: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 150)
        }.frame(maxWidth: 300, alignment: .leading)
    }

    /// "English · AC3 5.1", "Japanese (Forced)", or the track's own name.
    static func label(_ track: TrackInfo, audio: Bool) -> String {
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        var parts = [language ?? (track.name.isEmpty ? "Track \(track.id)" : track.name)]
        if audio {
            parts.append([track.codec.uppercased(), track.channels > 0 ? Self.channels(track.channels) : nil].compactMap { $0 }.joined(separator: " "))
        } else if language != nil, !track.name.isEmpty, track.name.lowercased() != language?.lowercased() {
            parts.append(track.name)
        }
        var text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        if track.isForced { text += " (Forced)" }
        if track.isCommentary { text += " (Commentary)" }
        return text
    }
    private static func channels(_ count: Int) -> String {
        switch count { case 1: "Mono"; case 2: "Stereo"; case 6: "5.1"; case 8: "7.1"; default: "\(count)ch" }
    }
    static func speedName(_ rate: Float) -> String {
        rate == 1 ? "1x" : String(format: rate == rate.rounded() ? "%.0fx" : "%gx", rate)
    }

    /// The round back button: the whole circle takes the tap (a bare chevron was too small to hit).
    private func round(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func transport(_ symbol: String, label: String, size: CGFloat = 26, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 72, height: 72).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func jump(_ seconds: Double) {
        let target = min(max(0, time + seconds), max(duration, 0))
        Task { await seek(target) }
        scheduleHide()
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

/// The subtitles on screen now: text cues at the bottom, picture cues (PGS, DVD) where the file
/// places them on its canvas. ASS styling is shown as plain text.
private struct JellySubtitles: View {
    let cues: [SubtitleCue]
    let time: Double
    var scale: Double = 1
    var insets = EdgeInsets()
    var fill = JellyFill.fit
    var originalSize = CGSize.zero
    var body: some View {
        let now = cues.filter { $0.startTime <= time && time < $0.endTime }
        GeometryReader { proxy in
            let safe = CGRect(x: insets.leading + 8, y: insets.top + 8, width: proxy.size.width - insets.leading - insets.trailing - 16,
                              height: proxy.size.height - insets.top - insets.bottom - 16)
            ZStack {
                ForEach(now) { cue in
                    if case .image(let picture) = cue.body {
                        let frame = Self.keep(Self.place(picture, in: proxy.size, fill: fill, originalSize: originalSize), inside: safe)
                        Image(decorative: picture.cgImage, scale: 1).resizable()
                            .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                    }
                }
                let lines = now.compactMap { cue -> String? in
                    if case .image = cue.body { return nil }
                    return cue.text.map(Self.plain)
                }.filter { !$0.isEmpty }
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n")).font(.system(size: max(14, proxy.size.height * 0.05 * scale), weight: .semibold))
                        .foregroundStyle(.white).multilineTextAlignment(.center)
                        .shadow(color: .black, radius: 2).shadow(color: .black.opacity(0.8), radius: 4)
                        .padding(.leading, max(40, insets.leading + 16)).padding(.trailing, max(40, insets.trailing + 16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, max(proxy.size.height * 0.07, insets.bottom + 12))
                }
            }
        }
    }
    /// A picture cue's rectangle: its canvas laid over the picture as it is shown (fitted, filled or
    /// at its own size), so the cue sits where the film puts it.
    static func place(_ picture: SubtitleImage, in size: CGSize, fill: JellyFill, originalSize: CGSize) -> CGRect {
        let canvas = picture.canvasSize
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale: CGFloat = switch fill {
        case .fit: min(size.width / canvas.width, size.height / canvas.height)
        case .fill: max(size.width / canvas.width, size.height / canvas.height)
        case .original: originalSize.width > 0 ? originalSize.width / canvas.width : min(size.width / canvas.width, size.height / canvas.height)
        }
        let origin = CGPoint(x: (size.width - canvas.width * scale) / 2, y: (size.height - canvas.height * scale) / 2)
        let spot = picture.position
        return CGRect(x: origin.x + spot.minX * scale, y: origin.y + spot.minY * scale, width: spot.width * scale, height: spot.height * scale)
    }
    /// Moved (and if need be shrunk) to lie within the screen's safe area: never cut off by the edges,
    /// the camera or a zoomed picture.
    static func keep(_ rect: CGRect, inside safe: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0, safe.width > 0, safe.height > 0 else { return rect }
        let shrink = min(1, safe.width / rect.width, safe.height / rect.height)
        var out = CGRect(x: rect.midX - rect.width * shrink / 2, y: rect.midY - rect.height * shrink / 2, width: rect.width * shrink, height: rect.height * shrink)
        out.origin.x = min(max(out.minX, safe.minX), safe.maxX - out.width)
        out.origin.y = min(max(out.minY, safe.minY), safe.maxY - out.height)
        return out
    }
    /// ASS override tags ({\i1}) out, its line breaks (\N) in.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The screen's brightness (put back when the player closes).
@MainActor enum JellyScreen {
    static var brightness: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = newValue }
    }
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}

/// The phone's volume, changed through a hidden system volume view (iOS has no other way to set it;
/// while that view is on screen the system's own volume badge stays away).
@MainActor final class JellyVolume {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    var level: Float { slider?.value ?? AVAudioSession.sharedInstance().outputVolume }
    func set(_ value: Float) { slider?.value = value }
    private var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }
}
private struct JellyVolumeView: UIViewRepresentable {
    let volume: JellyVolume
    func makeUIView(context: Context) -> MPVolumeView { volume.view }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// The Jellyfin user whose places and plays JellySpace keeps: the administrator (else the first
/// user), found once and remembered.
@MainActor enum JellyfinUser {
    private static let key = "jellyspace.userID"
    private static let serverKey = "jellyspace.userServer"
    static func id(_ client: JellyfinClient) async -> String? {
        let defaults = UserDefaults.standard, server = client.base.absoluteString
        // Kept for one server: connecting another finds that server's user afresh.
        if let saved = defaults.string(forKey: key), !saved.isEmpty, defaults.string(forKey: serverKey) == server { return saved }
        guard let users = try? await client.users(), let user = users.first(where: { $0.Policy?.IsAdministrator == true }) ?? users.first else { return nil }
        defaults.set(user.Id, forKey: key)
        defaults.set(server, forKey: serverKey)
        return user.Id
    }
}

/// Picture in Picture for whichever path AetherEngine plays on: its own player layer (native) or
/// the software path's sample-buffer source. Starts on its own when you leave the app mid-film.
@MainActor final class JellyPiP: NSObject, AVPictureInPictureControllerDelegate {
    weak var engine: AetherEngine?
    private var controller: AVPictureInPictureController?
    var available: Bool { controller != nil }

    func rebuildIfNeeded() { if controller == nil { rebuild() } }
    func rebuild() {
        guard let engine, AVPictureInPictureController.isPictureInPictureSupported() else { controller = nil; return }
        if let software = engine.softwarePiPSource {
            controller = software.makePictureInPictureController()
        } else if let layer = engine.nativePlayerLayer {
            controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        } else {
            controller = nil
        }
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    func start() { controller?.startPictureInPicture() }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { engine?.pictureInPictureActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { engine?.pictureInPictureActive = false }
    }
}
