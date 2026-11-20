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
    /// The version of a film (when it has more than one); nil plays the first.
    var source: String? = nil
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
    // Settings → JellySpace.
    @AppStorage(JellyPrefs.skipIntroKey) private var skipIntro = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipRecapKey) private var skipRecap = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipCreditsKey) private var skipCredits = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.introDBKey) private var introDB = true
    @AppStorage(JellyPrefs.skipSecondsKey) private var skipSeconds = 15
    @AppStorage(JellyPrefs.autoplayKey) private var autoplay = true
    @AppStorage(JellyPrefs.countdownKey) private var countdownSeconds = 5
    @AppStorage(JellyPrefs.resumeKey) private var resumeOn = true
    @AppStorage(JellyPrefs.diaryKey) private var diaryOn = true
    @AppStorage(JellyPrefs.rememberTracksKey) private var rememberTracks = true
    @AppStorage(JellyPrefs.swipeSeekKey) private var swipeSeekOn = true
    @AppStorage(JellyPrefs.swipeLevelsKey) private var swipeLevelsOn = true
    @AppStorage(JellyPrefs.holdKey) private var holdOn = true
    @AppStorage(JellyPrefs.skipDelayKey) private var skipDelay = 0
    @AppStorage(JellyPrefs.batteryKey) private var batteryOn = true
    @AppStorage(JellyPrefs.timeModeKey) private var timeMode = "left"
    @AppStorage(JellyPrefs.subtitleLanguageKey) private var subtitleLanguage = "eng"
    /// Upscaling, for every video (it only acts on SDR below 1080p, and on iOS 26 GPUs that can).
    @AppStorage("jellyspace.upscale") private var upscaleOn = false
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
    @State private var buffering = false
    @State private var buffered: Double = 0
    /// The time on the right: left (with when it ends) or the whole length.
    /// An automatic skip waiting out its delay: which stretch, and when it goes.
    @State private var pendingSkip: (start: Int64, at: Date)?
    /// Subtitle search (Jellyfin's providers): the results, and what's going on.
    @State private var foundSubtitles: [JellyfinClient.RemoteSubtitle] = []
    @State private var searchingSubtitles = false
    @State private var downloadingSubtitle: String?
    @State private var subtitleNotice: String?
    /// The separate subtitle files the video had (a downloaded one is the new index).
    @State private var knownSubtitles: Set<Int> = []
    /// Sleep timer: a time to stop at, or the end of this episode; the sound fades before it pauses.
    @State private var sleepAt: Date?
    @State private var sleepAtEnd = false
    @State private var fadingOut = false
    /// "1080p HEVC", from the file's video stream.
    @State private var quality: String?
    /// The subtitle the CC button turns back on.
    @State private var lastSubtitle: Int?
    /// What a one-finger swipe is doing: brightness (left half, up or down), volume (right half), or
    /// moving through the video (sideways).
    @State private var swipeKind: SwipeKind?
    @State private var swipeArea = CGSize.zero
    /// The play or pause sign shown briefly after a two-finger tap.
    @State private var flash: String?
    /// Anime or animation: the line-art upscaler instead of the general one.
    @State private var animated = false
    /// What the upscaler is doing now (nil when it isn't running).
    @State private var upscale: UpscaleStatus?
    /// Stretches already skipped on their own (each once, so going back into one plays it).
    @State private var skipped: Set<Int64> = []
    /// The chosen subtitle's styles, when it's an ASS/SSA track.
    @State private var assSheet: JellyASSSheet?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Panel { case tracks, episodes, chapters, settings, subtitleSearch }
    private enum SwipeKind { case brightness, volume, seek }

    init(playback: JellyPlayback) {
        _current = State(initialValue: playback)
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
                               fill: fill, originalSize: CGSize(width: videoSize.width / displayScale, height: videoSize.height / displayScale), sheet: assSheet)
                    .ignoresSafeArea()
            }.allowsHitTesting(false)
            // One finger: tap for the controls, double tap 15 seconds back (left) or on (right), hold
            // for 2x, swipe sideways to move through the video, up or down for brightness (left) or
            // volume (right). Two fingers: tap to pause or play, pinch for Fill or Fit.
            JellyGestureLayer(
                tap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                    if showsControls { scheduleHide() }
                },
                doubleTap: { left in skip(Double(left ? -skipSeconds : skipSeconds)) },
                twoFingerTap: { togglePlay() },
                hold: { began in if began { startHold() } else { endHold() } },
                pan: { phase in panned(phase) },
                pinch: { scale in
                    if scale > 1.15, fill != .fill { setFill(.fill) }
                    else if scale < 0.87, fill != .fit { setFill(.fit) }
                }
            )
            .ignoresSafeArea().allowsHitTesting(!screenLocked)
            if swipeKind == .seek, let scrub { seekCard(scrub).transition(.opacity).allowsHitTesting(false) }
            if let flash, !showsControls {
                Image(systemName: flash).font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 84, height: 84).background(.black.opacity(0.45), in: Circle())
                    .transition(.opacity.combined(with: .scale(scale: 0.85))).allowsHitTesting(false)
            }
            if buffering, !showsControls, failure == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            JellyVolumeView(volume: volume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            if let level { levelHUD(level).transition(.opacity).allowsHitTesting(false) }
            if holding {
                Label("2x", systemImage: "forward.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 38).background(.black.opacity(0.6), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 18).transition(.opacity).allowsHitTesting(false)
            }
            if let skipFlash {
                Text((skipFlash < 0 ? "−" : "+") + "\(Int(abs(skipFlash)))s").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
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
            if let segment = activeSegment, panel == nil, countdown == nil, failure == nil, !screenLocked {
                if skipMode(segment.kind) == .button { skipButton(segment).transition(.opacity) }
                else if let pendingSkip, pendingSkip.start == segment.StartTicks { autoSkipButton(segment, at: pendingSkip.at).transition(.opacity) }
            }
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
        .onChange(of: speed) { _, _ in updateActivity() }
        .onDisappear {
            if let brightnessAtOpen { JellyScreen.brightness = brightnessAtOpen }
            countdownTask?.cancel()
            JellyLiveActivity.end()
            report("stop")
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
                report("progress")
            }
        }
        .onChange(of: state) { _, now in
            if now == .playing { scheduleHide() }
            if now == .paused || now == .playing { report("progress"); updateActivity() }
            if now == .ended, autoplay, nextEpisode != nil, countdown == nil { startCountdown() }
        }
    }

    @ViewBuilder private func picture(_ engine: AetherEngine) -> some View {
        let surface = AetherPlayerSurface(engine: engine)
            .onReceive(engine.$state) { state = $0; if $0 == .playing { pip.rebuildIfNeeded() } }
            .onReceive(engine.clock.$currentTime) { seconds in time = seconds; reachedEnd(seconds); autoSkip(); checkSleep() }
            .onReceive(engine.$duration) { duration = $0 }
            .onReceive(engine.$audioTracks) { tracks in audioTracks = tracks; pickRememberedAudio(tracks) }
            .onReceive(engine.$subtitleTracks) { tracks in
                subtitleTracks = tracks
                assSheet = JellyASSSheet(tracks.first { $0.id == activeSubtitle }?.assHeader)
                pickDefaultSubtitle(tracks)
            }
            .onReceive(engine.$activeAudioTrackIndex) { activeAudio = $0 }
            .onReceive(engine.$activeSubtitleTrackIndex) { index in
                activeSubtitle = index
                assSheet = JellyASSSheet(subtitleTracks.first { $0.id == index }?.assHeader)
            }
            .onReceive(engine.$subtitleCues) { cues = $0 }
            .onReceive(engine.$softwarePiPSource) { _ in pip.rebuild() }
            .onReceive(engine.$sourceVideoWidth) { videoSize.width = CGFloat($0) }
            .onReceive(engine.$sourceVideoHeight) { videoSize.height = CGFloat($0) }
            .onReceive(engine.$isBuffering) { buffering = $0 }
            .onReceive(engine.$activeUpscale) { status in
                if status?.disabledReason != nil, upscale?.disabledReason == nil { show("Upscaling paused for this video") }
                upscale = status
            }
            .onReceive(engine.clock.$bufferedPosition) { buffered = $0 }
        if fill == .original, videoSize.width > 0, videoSize.height > 0 {
            // Its own pixel size: one video pixel per screen pixel, cropped if it's bigger than the screen.
            surface.frame(width: videoSize.width / displayScale, height: videoSize.height / displayScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().ignoresSafeArea()
        } else {
            surface.ignoresSafeArea()
        }
    }

    /// Double tap: 15 seconds back or on, with the sign on that side.
    private func skip(_ seconds: Double) {
        jump(seconds)
        withAnimation(.easeOut(duration: 0.15)) { skipFlash = seconds }
        Task { try? await Task.sleep(for: .milliseconds(700)); withAnimation { if skipFlash == seconds { skipFlash = nil } } }
    }
    /// Two-finger tap: pause or play, with a sign in the middle.
    private func togglePlay() {
        guard state == .playing || state == .paused else { return }
        let pausing = state == .playing
        if pausing { engine?.pause() } else { engine?.play() }
        let sign = pausing ? "pause.fill" : "play.fill"
        withAnimation(.easeOut(duration: 0.15)) { flash = sign }
        Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation { if flash == sign { flash = nil } } }
    }
    /// Hold: 2x while the finger stays down.
    private func startHold() {
        guard holdOn, !holding, state == .playing, swipeKind == nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { holding = true }
        engine?.setRate(2)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func endHold() {
        guard holding else { return }
        withAnimation(.easeOut(duration: 0.15)) { holding = false }
        engine?.setRate(speed)
    }

    /// A one-finger swipe. Sideways: through the video (the whole width is three minutes, so a short
    /// swipe is a fine move), shown on a card and played from where you let go. Up or down: brightness
    /// on the left, volume on the right (the whole height is 0 to full; swipes from the very top or
    /// bottom edge are the system's).
    private func panned(_ phase: JellyPan) {
        switch phase {
        case .began(let at, let velocity, let area):
            guard !holding else { return }
            swipeArea = area
            if abs(velocity.x) > abs(velocity.y) {
                guard swipeSeekOn, duration > 0, state != .loading, state != .idle else { return }
                swipeKind = .seek
                swipeStart = time
                scrub = time
            } else {
                guard swipeLevelsOn, at.y > 44, at.y < area.height - 44 else { return }
                let brightness = at.x < area.width / 2
                if brightness, brightnessAtOpen == nil { brightnessAtOpen = JellyScreen.brightness }
                swipeKind = brightness ? .brightness : .volume
                swipeStart = brightness ? Double(JellyScreen.brightness) : Double(volume.level)
            }
        case .changed(let move):
            guard let kind = swipeKind, let start = swipeStart else { return }
            if kind == .seek {
                scrub = min(max(0, start + Double(move.x) * 180 / Double(max(1, swipeArea.width))), duration)
            } else {
                let value = min(1, max(0, start - Double(move.y / max(1, swipeArea.height * 0.85))))
                if kind == .brightness { JellyScreen.brightness = CGFloat(value) } else { volume.set(Float(value)) }
                levelTask?.cancel()
                level = (kind == .brightness ? "sun.max.fill" : value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", value)
            }
        case .ended:
            if swipeKind == .seek, let target = scrub {
                Task { await seek(target); scrub = nil; scheduleHide() }
            } else if swipeKind != nil {
                levelTask?.cancel()
                levelTask = Task { try? await Task.sleep(for: .milliseconds(900)); if !Task.isCancelled { withAnimation { level = nil } } }
            }
            withAnimation(.easeOut(duration: 0.2)) { swipeKind = nil }
            swipeStart = nil
        }
    }
    /// While swiping sideways: the thumbnail there (when the server has them), how far, and where.
    private func seekCard(_ target: Double) -> some View {
        let change = target - (swipeStart ?? target)
        return VStack(spacing: 6) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: thumbnailHeight * 200 / 160).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text((change < 0 ? "−" : "+") + Self.clock(abs(change))).font(.system(size: 26, weight: .bold)).monospacedDigit()
            Text(Self.clock(target) + " / " + Self.clock(duration)).font(.system(size: 13, weight: .medium)).monospacedDigit().opacity(0.8)
        }
        .foregroundStyle(.white).padding(16).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
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
        if engine == nil { engine = try? AetherEngine() }
        guard let engine else { failure = "The player couldn’t start."; return }
        JellyMusic.shared.pause()
        skipped = []
        pip.engine = engine
        finished = false; failure = nil; resumedAt = nil; countdown = nil; pickedSubtitle = false; pickedAudio = false; time = 0
        segments = []; chapters = []; trickplay = nil; thumbnail = nil; sheet = nil; following = nil; quality = nil; buffered = 0
        let client = current.client, id = current.id
        // The user Jellyfin keeps your places for (the administrator, else the first), found once.
        let user = await JellyfinUser.id(client)
        userID = user
        if let seasonID = current.item.SeasonId, season.first?.SeasonId != seasonID {
            season = ((try? await client.children(of: seasonID, user: user)) ?? []).filter { $0.kind == "Episode" }
        }
        var startAt: Double?
        if resumeOn, let user, let data = try? await client.userData(current.id, user: user), let ticks = data.PlaybackPositionTicks, ticks > 0 {
            startAt = Double(ticks) / 10_000_000
        }
        // Chapters, scrubbing thumbnails and separate subtitle files first (the files load with the
        // video); the intro and credits stretches while it loads.
        let extras = try? await client.playerInfo(id, user: user)
        async let stretches = try? client.segments(id)
        var options = LoadOptions()
        // ASS/SSA lines arrive with their styling, drawn by JellyASSLayer.
        options.preserveASSMarkup = true
        options.externalSubtitles = Self.subtitleFiles(extras, source: current.source, item: id, client: client)
        knownSubtitles = Set(Self.subtitleStreams(extras, source: current.source, item: id, client: client).map { $0.index })
        pendingSkip = nil; foundSubtitles = []
        quality = Self.qualityName(extras, source: current.source)
        // The upscaler: the line-art one for anime and animation, the general one for the rest.
        var genres = extras?.Genres ?? []
        if current.item.kind == "Episode", let series = current.item.SeriesId { genres = (try? await client.genres(series, user: user)) ?? genres }
        animated = genres.contains { ["anime", "animation"].contains($0.lowercased()) }
        options.upscalesLowResolutionVideo = upscaleOn
        options.upscaleScaler = animated ? .lineArt : .automatic
        upscale = nil
        engine.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
        // The lock screen and Control Center: the title, its poster, play/pause and skipping.
        engine.ownsSoftwareNowPlaying = true
        engine.ownsVideoNowPlayingSession = true
        engine.ownsVideoNowPlayingCommands = true
        engine.remoteSkipInterval = Double(skipSeconds)
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
            report("start")
            updateActivity()
            if speed != 1 { engine.setRate(speed) }
            if audioDelay != 0 { engine.setAudioDelay(audioDelay) }
        } catch {
            guard !Task.isCancelled else { return }
            failure = await Self.unavailable(current.url) ? "This file isn’t available on the server right now. Its drive may be unplugged."
                : error.localizedDescription
            return
        }
        segments = Self.merged((await stretches) ?? [])
        if segments.isEmpty, introDB { segments = Self.merged(await introDBSegments(client: client, user: user)) }
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

    /// True when Jellyfin answers "not found" for the file itself (a missing or unplugged drive).
    static func unavailable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let answer = try? await URLSession.shared.data(for: request) else { return false }
        return (answer.1 as? HTTPURLResponse)?.statusCode == 404
    }
    /// Overlapping stretches of one kind (two plugins timing the same intro) as one.
    static func merged(_ segments: [JellyfinClient.Segment]) -> [JellyfinClient.Segment] {
        var out: [JellyfinClient.Segment] = []
        for segment in segments.sorted(by: { $0.StartTicks < $1.StartTicks }) {
            if let last = out.last, last.kind == segment.kind, segment.StartTicks <= last.EndTicks {
                out[out.count - 1] = JellyfinClient.Segment(kind: last.kind, start: Double(last.StartTicks) / 10_000_000,
                                                            end: Double(max(last.EndTicks, segment.EndTicks)) / 10_000_000)
            } else {
                out.append(segment)
            }
        }
        return out
    }

    /// "4K HEVC", "1080p H.264": the file's picture size and codec.
    static func qualityName(_ info: JellyfinClient.PlayerInfo?, source: String?) -> String? {
        let sources = info?.MediaSources ?? []
        guard let video = (sources.first { $0.Id == source } ?? sources.first)?.MediaStreams?.first(where: { $0.kind == "Video" }) else { return nil }
        let width = video.Width ?? 0, height = video.Height ?? 0
        let size: String? = width >= 3800 || height >= 2100 ? "4K" : width >= 1900 || height >= 1000 ? "1080p"
            : width >= 1260 || height >= 700 ? "720p" : height > 0 ? "\(height)p" : nil
        let codec = video.Codec.map { $0.lowercased() == "h264" ? "H.264" : $0.uppercased() }
        let name = [size, codec].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// The video's separate subtitle files (.srt, .ass, .vtt and the like next to it), as tracks the
    /// player loads with the video. Picture subtitles in a separate file (.sup) are left out.
    static func subtitleFiles(_ info: JellyfinClient.PlayerInfo?, source chosen: String?, item: String, client: JellyfinClient) -> [ExternalSubtitleTrack] {
        subtitleStreams(info, source: chosen, item: item, client: client).map { $0.track }
    }
    static func subtitleStreams(_ info: JellyfinClient.PlayerInfo?, source chosen: String?, item: String,
                                client: JellyfinClient) -> [(index: Int, track: ExternalSubtitleTrack)] {
        let sources = info?.MediaSources ?? []
        guard let source = sources.first(where: { $0.Id == chosen }) ?? sources.first, let sourceID = source.Id else { return [] }
        return (source.MediaStreams ?? []).compactMap { stream -> (index: Int, track: ExternalSubtitleTrack)? in
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
            return (stream.Index, ExternalSubtitleTrack(url: url, name: stream.DisplayTitle, language: stream.Language,
                                                        isForced: stream.IsForced == true, isDefault: stream.IsDefault == true, formatHint: format))
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
        return segments.first {
            ["Intro", "Recap", "Outro", "Preview", "Commercial"].contains($0.kind) && skipMode($0.kind) != .off
                && $0.StartTicks <= ticks && ticks < $0.EndTicks - 10_000_000
        }
    }
    /// Off, a button, or skipped on its own (Settings → JellySpace); previews and ads get the button.
    private func skipMode(_ kind: String) -> JellySkipMode {
        let raw: String = switch kind {
        case "Intro": skipIntro
        case "Recap": skipRecap
        case "Outro": skipCredits
        default: JellySkipMode.button.rawValue
        }
        return JellySkipMode(rawValue: raw) ?? .button
    }
    /// Automatic: past the stretch as it starts (the credits go to the next episode when that's on).
    private func autoSkip() {
        guard scrub == nil, state == .playing, let segment = activeSegment, skipMode(segment.kind) == .auto,
              !skipped.contains(segment.StartTicks) else {
            if pendingSkip != nil, activeSegment?.StartTicks != pendingSkip?.start { pendingSkip = nil }
            return
        }
        // With a delay (Settings → JellySpace), a countdown button first, which can skip now or cancel.
        if skipDelay > 0 {
            if pendingSkip?.start != segment.StartTicks {
                withAnimation { pendingSkip = (segment.StartTicks, Date.now.addingTimeInterval(Double(skipDelay))) }
                return
            }
            guard let pendingSkip, Date.now >= pendingSkip.at else { return }
        }
        skipNow(segment, automatic: true)
    }
    /// Past the stretch (the credits go to the next episode when that's on).
    private func skipNow(_ segment: JellyfinClient.Segment, automatic: Bool) {
        skipped.insert(segment.StartTicks)
        withAnimation { pendingSkip = nil }
        if segment.kind == "Outro", automatic ? autoplay : true, let next = nextEpisode { play(next); return }
        Task { await seek(Double(segment.EndTicks) / 10_000_000) }
        if automatic { show(segment.kind == "Intro" ? "Skipped intro" : segment.kind == "Recap" ? "Skipped recap" : "Skipped credits") }
    }
    /// "Skipping intro in 2": a tap skips now; Cancel lets it play.
    private func autoSkipButton(_ segment: JellyfinClient.Segment, at moment: Date) -> some View {
        let left = max(1, Int(ceil(moment.timeIntervalSinceNow)))
        let what = segment.kind == "Intro" ? "intro" : segment.kind == "Recap" ? "recap" : "credits"
        return HStack(spacing: 10) {
            Button { skipped.insert(segment.StartTicks); withAnimation { pendingSkip = nil } } label: {
                Text("Cancel").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 44).background(.black.opacity(0.55), in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-skip-cancel")
            Button { skipNow(segment, automatic: true) } label: {
                Label("Skipping \(what) in \(left)", systemImage: "forward.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 18).frame(height: 44).background(.white, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-skip-auto")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 28).padding(.bottom, showsControls ? 124 : 36)
    }
    /// IntroDB's times (by the show's IMDb id and the episode, or the film's) when Jellyfin has none.
    private func introDBSegments(client: JellyfinClient, user: String?) async -> [JellyfinClient.Segment] {
        let item = current.item
        if item.kind == "Episode", let series = item.SeriesId, let season = item.ParentIndexNumber, let number = item.IndexNumber {
            guard let imdb = (try? await client.item(series))?.ProviderIds?["Imdb"] else { return [] }
            return await IntroDB.segments(imdb: imdb, season: season, episode: number)
        }
        if item.kind == "Movie", let imdb = item.ProviderIds?["Imdb"] { return await IntroDB.segments(imdb: imdb, season: nil, episode: nil) }
        return []
    }
    /// Skip Intro (Recap, Preview); in the credits, Next Episode when there is one, else Skip Credits.
    private func skipButton(_ segment: JellyfinClient.Segment) -> some View {
        let next = segment.kind == "Outro" ? nextEpisode : nil
        return Button { skipNow(segment, automatic: false) } label: {
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
        guard rememberTracks else { return }
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: "jellyspace.\(kind)")
        if let show = current.item.SeriesId { defaults.set(value, forKey: "jellyspace.\(kind).\(show)") }
    }
    private func pickRememberedAudio(_ tracks: [TrackInfo]) {
        guard !pickedAudio, !tracks.isEmpty else { return }
        pickedAudio = true
        guard rememberTracks else { return }
        guard let language = remembered("audioLanguage"),
              let track = tracks.first(where: { $0.language == language && !$0.isCommentary }),
              track.id != engine?.activeAudioTrackIndex else { return }
        engine?.selectAudioTrack(index: track.id)
    }

    /// Another episode in the same player: your place in this one is kept first.
    private func play(_ item: JellyfinClient.Item) {
        report("stop")
        savePlace()
        countdown = nil; panel = nil
        guard let next = JellySpace.playback(item, client: current.client) else { return }
        current = next
    }

    private func startCountdown() {
        countdown = countdownSeconds
        updateActivity()
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

    /// The Live Activity's state now (the bar runs on from these times by itself).
    private func updateActivity(at position: Double? = nil) {
        guard duration > 0, state != .idle, state != .loading else { return }
        let at = position ?? time, rate = Double(max(0.1, speed)), now = Date.now
        let item = current.item
        var next: (String, Date)?
        if let countdown, let episode = nextEpisode {
            next = ([episode.IndexNumber.map { "E\($0)" }, episode.Name].compactMap { $0 }.joined(separator: " · "), now.addingTimeInterval(Double(countdown)))
        }
        let detail = item.kind == "Episode" ? JellySpace.detail(item) : (item.ProductionYear.map(String.init) ?? "")
        JellyLiveActivity.show(JellyPlaybackAttributes.ContentState(
            title: heading, detail: detail, startedAt: now.addingTimeInterval(-at / rate), endsAt: now.addingTimeInterval(max(0, duration - at) / rate),
            paused: state == .paused, position: at, duration: duration, nextTitle: next?.0, nextAt: next?.1), item: current.id)
    }

    // MARK: Sleep timer

    /// The fade starts eight seconds before the time (or before the credits, or the last ten seconds,
    /// at the end of an episode).
    private func checkSleep() {
        guard !fadingOut, state == .playing, sleepAt != nil || sleepAtEnd else { return }
        if let sleepAt, Date.now >= sleepAt.addingTimeInterval(-8) { fadeOut(); return }
        if sleepAtEnd, duration > 0 {
            let credits = segments.first { $0.kind == "Outro" }.map { Double($0.StartTicks) / 10_000_000 }
            if time >= min(credits ?? .infinity, duration - 10) - 8 { fadeOut() }
        }
    }
    /// The sound down to nothing over eight seconds, then paused (and the sound put back).
    private func fadeOut() {
        fadingOut = true
        Task {
            for step in 1...16 {
                try? await Task.sleep(for: .milliseconds(500))
                guard fadingOut else { engine?.volume = 1; return }
                engine?.volume = max(0, 1 - Float(step) / 16)
            }
            engine?.pause()
            engine?.volume = 1
            countdown = nil
            fadingOut = false; sleepAt = nil; sleepAtEnd = false
            show("Sleep timer: paused")
        }
    }
    private func setSleep(_ minutes: Int?) {
        fadingOut = false
        engine?.volume = 1
        sleepAtEnd = minutes == 0
        sleepAt = minutes.flatMap { $0 > 0 ? Date.now.addingTimeInterval(Double($0) * 60) : nil }
        show(minutes == nil ? "Sleep timer off" : minutes == 0 ? "Sleeps at the end of this episode" : "Sleeps in \(minutes ?? 0) min")
    }
    /// The moon and time left, by the battery, while a sleep timer is on.
    @ViewBuilder private var sleepBadge: some View {
        if sleepAtEnd || sleepAt != nil {
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                if let sleepAt { Text(timerInterval: Date.now...max(Date.now, sleepAt), countsDown: true).monospacedDigit() }
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            .accessibilityElement(children: .ignore).accessibilityLabel("Sleep timer on")
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
        let client = current.client, id = current.id, user = userID, item = current.item
        Task {
            if let user {
                try? await client.markPlayed(id, user: user)
                try? await client.savePosition(id, user: user, seconds: 0)
            }
            if diaryOn { await markInDiary(item, client: client) }
        }
    }

    private func markInDiary(_ item: JellyfinClient.Item, client: JellyfinClient) async {
        let note = await JellyDiary.mark(item, client: client, store: store)
        if !note.isEmpty { show(note) }
    }
    /// Tells Jellyfin what's playing (signed in only: the server's API key has no user to report as).
    private func report(_ event: String) {
        guard JellyAccount.token != nil else { return }
        let client = current.client, id = current.id, source = current.source, at = time, paused = state == .paused
        Task { await client.report(event, item: id, source: source, seconds: at, paused: paused) }
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
        if rememberTracks, let saved = remembered("subtitleLanguage") {
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
            topBar
            if let resumedAt {
                // Under the title, out of the way of the bar.
                Button { Task { await seek(0) }; withAnimation { self.resumedAt = nil } } label: {
                    Text("Resumed at \(Self.clock(resumedAt)) · Start over").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30).background(.black.opacity(0.55), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 76).padding(.top, 4)
                .accessibilityIdentifier("jellyspace-start-over").transition(.opacity)
            }
            Spacer(minLength: 0)
            if let failure {
                Text(failure).font(.system(size: 14)).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 24)
            } else if state == .loading || state == .idle {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                HStack(spacing: verticalSizeClass == .compact ? 64 : 28) {
                    transport("gobackward.\(skipSeconds)", label: "Back \(skipSeconds) seconds") { jump(Double(-skipSeconds)) }
                    Button {
                        if state == .ended { Task { await start() } }
                        else if playingNow { engine?.pause() } else { engine?.play() }
                        scheduleHide()
                    } label: {
                        ZStack {
                            Circle().fill(.white.opacity(0.18))
                            if buffering {
                                ProgressView().controlSize(.large).tint(.white)
                            } else {
                                Image(systemName: playingNow ? "pause.fill" : state == .ended ? "arrow.counterclockwise" : "play.fill").font(.system(size: 34, weight: .semibold))
                                    .foregroundStyle(.white).offset(x: playingNow ? 0 : 2)
                            }
                        }.frame(width: 78, height: 78).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel(playingNow ? "Pause" : "Play")
                    transport("goforward.\(skipSeconds)", label: "Forward \(skipSeconds) seconds") { jump(Double(skipSeconds)) }
                }
            }
            Spacer(minLength: 0)
            // The time gone; the time left with when it ends (a tap shows the whole length instead).
            HStack {
                Text(Self.clock(scrub ?? time))
                Spacer(minLength: 8)
                Button { timeMode = timeMode == "total" ? "left" : "total"; scheduleHide() } label: {
                    Text(timeMode == "total" ? Self.clock(duration) : "-" + Self.clock(max(0, duration - (scrub ?? time))) + endsText)
                        .frame(minHeight: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-time-left")
            }
            .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 30)
            JellyScrubber(time: time, duration: duration, buffered: buffered, marks: chapterMarks, stretches: coloredStretches,
                          tint: theme.accent, scrub: $scrub) { target in
                Task { await seek(target); scrub = nil; scheduleHide() }
            }
            .overlay(alignment: .topLeading) { scrubPreview }
            .padding(.horizontal, 28)
            .disabled(duration <= 0)
            ViewThatFits(in: .horizontal) {
                actionRow(labels: true)
                actionRow(labels: false)
                ScrollView(.horizontal) { actionRow(labels: false).padding(.horizontal, 20) }.scrollIndicators(.hidden)
            }.padding(.top, 2).padding(.bottom, 12)
        }
        .background {
            LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
    }

    /// Back; the title with the episode (or the year, genre and quality) under it; AirPlay, subtitles
    /// on or off, and the playback settings.
    private var topBar: some View {
        HStack(spacing: 10) {
            round("chevron.left", label: "Close player") { dismiss() }.accessibilityIdentifier("jellyspace-close")
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                if !infoLine.isEmpty { Text(infoLine).font(.system(size: 12, weight: .medium)).opacity(0.75).lineLimit(1) }
            }
            .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 4)
            Spacer(minLength: 8)
            sleepBadge
            if batteryOn { JellyBattery() }
            JellyAirPlayButton().frame(width: 40, height: 40).accessibilityLabel("AirPlay")
            if !subtitleTracks.isEmpty {
                topButton(activeSubtitle == nil ? "captions.bubble" : "captions.bubble.fill", label: activeSubtitle == nil ? "Subtitles on" : "Subtitles off") {
                    toggleSubtitles()
                }.accessibilityIdentifier("jellyspace-cc")
            }
            topButton("slider.horizontal.3", label: "Playback settings") { withAnimation { panel = .settings } }
                .accessibilityIdentifier("jellyspace-settings")
        }.padding(.horizontal, 20).padding(.top, 10)
    }
    private func topButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private var heading: String {
        current.item.kind == "Episode" ? (current.item.SeriesName ?? current.title) : (current.item.Name ?? current.title)
    }
    /// "S1:E3 - Name" for an episode; "2000 · Drama · 1080p HEVC" for a film.
    private var infoLine: String {
        let item = current.item
        let base = item.kind == "Episode" ? JellySpace.detail(item)
            : [item.ProductionYear.map(String.init), item.Genres?.first, quality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return [base, upscaleLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// "Upscaled from 720p", only while the upscaler is running.
    private var upscaleLabel: String? {
        guard let upscale, upscale.disabledReason == nil, upscale.sourceSize.height > 0 else { return nil }
        return "Upscaled from \(Int(upscale.sourceSize.height))p"
    }
    /// Turned on or off mid-video: the video reloads where it is with the new setting.
    private func setUpscale(_ on: Bool) {
        guard on != upscaleOn else { return }
        upscaleOn = on
        show(on ? "Upscaling on" : "Upscaling off")
        guard let engine, state != .idle, state != .loading else { return }
        let scaler: UpscaleScaler = animated ? .lineArt : .automatic
        Task {
            _ = try? await engine.reloadAtCurrentPosition { options in
                options.upscalesLowResolutionVideo = on
                options.upscaleScaler = scaler
            }
        }
    }
    /// " · ends 11:42 PM", at the speed it plays.
    private var endsText: String {
        guard duration > 0 else { return "" }
        let left = max(0, duration - (scrub ?? time)) / Double(max(0.1, speed))
        return " · ends " + Date.now.addingTimeInterval(left).formatted(date: .omitted, time: .shortened)
    }
    private var chapterMarks: [Double] {
        chapters.map { Double($0.StartPositionTicks) / 10_000_000 }.filter { $0 > 1 && $0 < duration - 1 }
    }
    /// The intro (green), recap (purple) and credits (orange) on the bar.
    private var coloredStretches: [JellyStretch] {
        segments.compactMap { segment in
            let color: Color
            switch segment.kind {
            case "Intro": color = Color(red: 0.25, green: 0.8, blue: 0.55)
            case "Recap": color = Color(red: 0.65, green: 0.45, blue: 0.95)
            case "Outro": color = .orange
            default: return nil
            }
            let from = Double(segment.StartTicks) / 10_000_000, to = Double(segment.EndTicks) / 10_000_000
            return to > from ? JellyStretch(range: from...to, color: color) : nil
        }
    }
    /// The thumbnail and time over the bar while you drag it.
    @ViewBuilder private var scrubPreview: some View {
        if let scrub, duration > 0, swipeKind != .seek {
            GeometryReader { proxy in
                let x = min(max(80, proxy.size.width * scrub / duration), max(80, proxy.size.width - 80))
                VStack(spacing: 4) {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 160, height: thumbnailHeight).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.85), lineWidth: 1.5))
                    }
                    Text(Self.clock(scrub)).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.6), in: Capsule())
                }
                .position(x: x, y: -((thumbnail == nil ? 22 : thumbnailHeight + 26) / 2 + 6))
            }.allowsHitTesting(false)
        }
    }
    /// CC: off, or back on with the subtitle you had (else the first one).
    private func toggleSubtitles() {
        if let on = activeSubtitle {
            lastSubtitle = on
            engine?.clearSubtitle()
            remember("subtitleLanguage", "off")
        } else if let track = subtitleTracks.first(where: { $0.id == lastSubtitle }) ?? subtitleTracks.first(where: { !$0.isForced }) ?? subtitleTracks.first {
            engine?.selectSubtitleTrack(index: track.id)
            if let language = track.language { remember("subtitleLanguage", language) }
        }
    }

    private func actionRow(labels: Bool) -> some View {
        HStack(spacing: labels ? 20 : 30) {
            if current.item.kind == "Episode", season.count > 1 {
                action("rectangle.stack", "Episodes", labels: labels) { withAnimation { panel = .episodes } }
            }
            if chapters.count > 1 {
                action("list.bullet.rectangle", "Chapters", labels: labels) { withAnimation { panel = .chapters } }.accessibilityIdentifier("jellyspace-chapters")
            }
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button { speed = Float(value); engine?.setRate(Float(value)) } label: {
                        if speed == Float(value) { Label(Self.speedName(Float(value)), systemImage: "checkmark") } else { Text(Self.speedName(Float(value))) }
                    }
                }
            } label: { actionFace("gauge.with.needle", Self.speedName(speed), labels: labels) }
                .accessibilityLabel("Speed").accessibilityIdentifier("jellyspace-speed")
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
        setFill(all[(all.firstIndex(of: fill).map { $0 + 1 } ?? 0) % all.count])
    }
    private func setFill(_ next: JellyFill) {
        fillRaw = next.rawValue
        engine?.videoGravity = next == .fill ? .resizeAspectFill : .resizeAspect
        show(next.rawValue)
        scheduleHide()
    }

    private func action(_ symbol: String, _ title: String, labels: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { actionFace(symbol, title, labels: labels) }.buttonStyle(.plain)
    }
    private func actionFace(_ symbol: String, _ title: String, labels: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: labels ? 15 : 18, weight: .semibold))
            if labels { Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize() }
        }.foregroundStyle(.white.opacity(0.92)).frame(minWidth: 44, minHeight: 40).contentShape(Rectangle()).accessibilityLabel(title)
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
                Button { countdown = nil; updateActivity() } label: {
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
                case .settings: settingsContent
                case .subtitleSearch: subtitleSearchContent
                }
                Button { withAnimation { self.panel = nil } } label: {
                    Text("Close").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(height: 38).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 40).padding(.vertical, 20)
        }
    }

    /// Audio and Subtitles side by side, the chosen one of each ticked.
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
        }
        Button { withAnimation { panel = .subtitleSearch } } label: {
            Label("Download subtitles", systemImage: "arrow.down.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 36).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-download-subtitles")
      }
    }

    /// Subtitles from the server's providers (OpenSubtitles), in a language; a tap saves one on the
    /// server and turns it on.
    private var subtitleSearchContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Download subtitles").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Spacer(minLength: 12)
                Menu {
                    Picker("Language", selection: $subtitleLanguage) {
                        ForEach(Self.subtitleLanguages, id: \.1) { Text($0.0).tag($0.1) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.subtitleLanguages.first { $0.1 == subtitleLanguage }?.0 ?? subtitleLanguage)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    }.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32).background(.white.opacity(0.15), in: Capsule())
                }.accessibilityIdentifier("jellyspace-subtitle-language")
            }
            if searchingSubtitles {
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 80)
            } else if foundSubtitles.isEmpty {
                Text(subtitleNotice ?? "None found").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(foundSubtitles) { found in
                            Button { Task { await download(found) } } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(found.Name ?? "Subtitle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                        Text([found.ProviderName, found.Format?.uppercased(), found.DownloadCount.map { "\($0) downloads" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if downloadingSubtitle == found.Id { ProgressView().tint(.white) }
                                    else if found.IsHashMatch == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).accessibilityLabel("Matches this file") }
                                }.frame(minHeight: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(downloadingSubtitle != nil)
                        }
                    }
                }.frame(maxHeight: 200)
                if let subtitleNotice { Text(subtitleNotice).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .frame(maxWidth: 560)
        .task(id: subtitleLanguage) { await searchSubtitles() }
    }
    static let subtitleLanguages: [(String, String)] = [
        ("English", "eng"), ("Hindi", "hin"), ("Spanish", "spa"), ("French", "fre"), ("German", "ger"), ("Italian", "ita"),
        ("Portuguese", "por"), ("Russian", "rus"), ("Japanese", "jpn"), ("Korean", "kor"), ("Chinese", "chi"), ("Arabic", "ara"),
        ("Turkish", "tur"), ("Indonesian", "ind"), ("Thai", "tha"), ("Vietnamese", "vie"), ("Dutch", "dut"), ("Polish", "pol")
    ]
    private func searchSubtitles() async {
        searchingSubtitles = true; subtitleNotice = nil
        defer { searchingSubtitles = false }
        do {
            foundSubtitles = try await current.client.searchSubtitles(current.id, language: subtitleLanguage)
                .sorted { ($0.IsHashMatch == true ? 1 : 0, $0.DownloadCount ?? 0) > ($1.IsHashMatch == true ? 1 : 0, $1.DownloadCount ?? 0) }
        } catch {
            foundSubtitles = []
            if !Task.isCancelled { subtitleNotice = error.localizedDescription }
        }
    }
    /// Saved on the server, then (once Jellyfin lists it with the video) added here and turned on.
    private func download(_ found: JellyfinClient.RemoteSubtitle) async {
        downloadingSubtitle = found.Id; subtitleNotice = nil
        defer { downloadingSubtitle = nil }
        let client = current.client, id = current.id
        do {
            try await client.downloadSubtitle(id, subtitle: found.Id)
        } catch {
            subtitleNotice = error.localizedDescription
            return
        }
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            let info = try? await client.playerInfo(id, user: userID)
            let files = Self.subtitleStreams(info, source: current.source, item: id, client: client)
            if let fresh = files.first(where: { !knownSubtitles.contains($0.index) }) {
                knownSubtitles = Set(files.map { $0.index })
                if let added = engine?.addExternalSubtitleTrack(fresh.track) {
                    engine?.selectSubtitleTrack(index: added.id)
                    if let language = added.language { remember("subtitleLanguage", language) }
                }
                withAnimation { panel = nil }
                show("Subtitles added")
                return
            }
        }
        subtitleNotice = "Saved on the server. It shows next time you open the video."
    }

    /// Speed, subtitle size, and the subtitle and audio delays.
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Playback").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            HStack(spacing: 8) {
                Text("Sleep timer").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).frame(width: 104, alignment: .leading)
                ForEach([("Off", Int?.none), ("15m", 15), ("30m", 30), ("60m", 60), ("Episode end", 0)], id: \.0) { option in
                    let on = option.1 == nil ? (sleepAt == nil && !sleepAtEnd) : option.1 == 0 ? sleepAtEnd : false
                    Button { setSleep(option.1) } label: {
                        Text(option.0).font(.system(size: 13, weight: .bold)).foregroundStyle(on ? .black : .white)
                            .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 30).background(on ? Color.white : Color.white.opacity(0.15), in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-sleep-" + option.0)
                }
            }
            optionRow("Speed", options: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { (Self.speedName(Float($0)), $0) }, chosen: Double(speed)) { value in
                speed = Float(value)
                engine?.setRate(Float(value))
            }
            HStack(spacing: 8) {
                Text("Upscaling").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).frame(width: 104, alignment: .leading)
                ForEach([("Off", false), ("On", true)], id: \.1) { option in
                    let on = upscaleOn == option.1
                    Button { setUpscale(option.1) } label: {
                        Text(option.0).font(.system(size: 13, weight: .bold)).foregroundStyle(on ? .black : .white)
                            .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 30).background(on ? Color.white : Color.white.opacity(0.15), in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-upscale-" + option.0.lowercased())
                }
            }
            if !subtitleTracks.isEmpty {
                optionRow("Subtitle size", options: [("S", 0.8), ("M", 1.0), ("L", 1.3), ("XL", 1.6)], chosen: subtitleSize) { subtitleSize = $0 }
            }
            HStack(spacing: 32) {
                if !subtitleTracks.isEmpty {
                    delayControl("Subtitle delay", value: subtitleDelay) { subtitleDelay = $0; engine?.setSoftwareSubtitleDelay($0) }
                }
                delayControl("Audio delay", value: audioDelay) { audioDelay = $0; engine?.setAudioDelay($0) }
            }
        }.frame(maxWidth: 600, alignment: .leading)
    }
    private func optionRow(_ title: String, options: [(String, Double)], chosen: Double, pick: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).frame(width: 104, alignment: .leading)
            ForEach(options, id: \.1) { option in
                let on = abs(chosen - option.1) < 0.001
                Button { pick(option.1) } label: {
                    Text(option.0).font(.system(size: 13, weight: .bold)).foregroundStyle(on ? .black : .white)
                        .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 30).background(on ? Color.white : Color.white.opacity(0.15), in: Capsule())
                }.buttonStyle(.plain)
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
    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 56, height: 56).background(.black.opacity(0.35), in: Circle()).contentShape(Circle())
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
        updateActivity(at: seconds)
    }
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let whole = Int(seconds)
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The progress bar: a thin line with a dot (both grow while you drag), the part already loaded in
/// a lighter band, small ticks at the chapters, and the credits in orange.
private struct JellyScrubber: View {
    let time: Double
    let duration: Double
    let buffered: Double
    let marks: [Double]
    let stretches: [JellyStretch]
    let tint: Color
    @Binding var scrub: Double?
    let commit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width), total = max(duration, 1)
            let shown = scrub ?? time, dragging = scrub != nil
            let at = width * min(1, max(0, shown / total))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Rectangle().fill(.white.opacity(0.38)).frame(width: width * min(1, max(0, buffered / total)))
                ForEach(stretches.indices, id: \.self) { index in
                    let stretch = stretches[index]
                    Rectangle().fill(stretch.color.opacity(0.85))
                        .frame(width: max(2, width * (stretch.range.upperBound - stretch.range.lowerBound) / total))
                        .offset(x: width * stretch.range.lowerBound / total)
                }
                Rectangle().fill(tint).frame(width: at)
                ForEach(marks.indices, id: \.self) { index in
                    Rectangle().fill(.black.opacity(0.6)).frame(width: 2).offset(x: width * marks[index] / total - 1)
                }
            }
            .frame(height: dragging ? 8 : 4).clipShape(Capsule())
            .overlay(alignment: .leading) {
                Circle().fill(.white).frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12).offset(x: at - (dragging ? 9 : 6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        scrub = min(max(0, drag.location.x / width), 1) * duration
                    }
                    .onEnded { _ in if let target = scrub { commit(target) } }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(JellyPlayerView.clock(time))
        .accessibilityAdjustableAction { direction in
            if direction == .increment { commit(min(duration, time + 10)) } else if direction == .decrement { commit(max(0, time - 10)) }
        }
    }
}

/// A one-finger swipe as the touch layer reports it: where it started, which way it was going and
/// the area's size; then how far it has moved; then the end.
private enum JellyPan {
    case began(CGPoint, CGPoint, CGSize)
    case changed(CGPoint)
    case ended
}

/// The player's touches, read by UIKit's recognizers (SwiftUI has no two-finger tap, and these sort
/// out taps, double taps, holds, swipes and pinches between them reliably).
private struct JellyGestureLayer: UIViewRepresentable {
    let tap: () -> Void
    let doubleTap: (_ leftHalf: Bool) -> Void
    let twoFingerTap: () -> Void
    let hold: (_ began: Bool) -> Void
    let pan: (JellyPan) -> Void
    let pinch: (_ scale: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        single.require(toFail: double)
        let twoFingers = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFingerTapped))
        twoFingers.numberOfTouchesRequired = 2
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement = 24
        let swipe = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        swipe.maximumNumberOfTouches = 1
        let squeeze = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        for recognizer in [double, single, twoFingers, press, swipe, squeeze] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.layer = self }

    @MainActor final class Coordinator: NSObject {
        var layer: JellyGestureLayer
        init(_ layer: JellyGestureLayer) { self.layer = layer }
        @objc func tapped() { layer.tap() }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            layer.doubleTap(gesture.location(in: view).x < view.bounds.midX)
        }
        @objc func twoFingerTapped() { layer.twoFingerTap() }
        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: layer.hold(true)
            case .ended, .cancelled, .failed: layer.hold(false)
            default: break
            }
        }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                let now = gesture.location(in: view), moved = gesture.translation(in: view)
                layer.pan(.began(CGPoint(x: now.x - moved.x, y: now.y - moved.y), gesture.velocity(in: view), view.bounds.size))
            case .changed: layer.pan(.changed(gesture.translation(in: view)))
            case .ended, .cancelled, .failed: layer.pan(.ended)
            default: break
            }
        }
        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .ended { layer.pinch(gesture.scale) }
        }
    }
}

/// An intro, recap or credits stretch on the bar, in its colour.
struct JellyStretch {
    let range: ClosedRange<Double>
    let color: Color
}

/// The phone's battery, by the player's top buttons.
private struct JellyBattery: View {
    @State private var level = UIDevice.current.batteryLevel
    @State private var charging = false
    var body: some View {
        Group {
            if level >= 0 {
                HStack(spacing: 4) {
                    Text("\(Int((level * 100).rounded()))%").monospacedDigit()
                    Image(systemName: symbol)
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .accessibilityElement(children: .ignore).accessibilityLabel("Battery \(Int((level * 100).rounded())) percent")
            }
        }
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true; read() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in read() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in read() }
    }
    private var symbol: String {
        if charging { return "battery.100.bolt" }
        return level > 0.87 ? "battery.100" : level > 0.62 ? "battery.75" : level > 0.37 ? "battery.50" : level > 0.12 ? "battery.25" : "battery.0"
    }
    private func read() {
        level = UIDevice.current.batteryLevel
        charging = [.charging, .full].contains(UIDevice.current.batteryState)
    }
}

/// The system's AirPlay button.
private struct JellyAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        return picker
    }
    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
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
    var sheet: JellyASSSheet? = nil
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
                if let sheet {
                    let events = now.compactMap { cue -> String? in
                        if case .image = cue.body { return nil }
                        return cue.text
                    }
                    if !events.isEmpty {
                        JellyASSLayer(events: events, sheet: sheet, size: proxy.size, safe: safe, fill: fill, originalSize: originalSize, userScale: scale)
                    }
                }
                let lines = sheet != nil ? [] : now.compactMap { cue -> String? in
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
    lazy var view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
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
    /// Watch as this user (Settings → JellySpace, with the server's API key).
    static func choose(_ id: String, server: String) {
        UserDefaults.standard.set(id, forKey: key)
        UserDefaults.standard.set(server, forKey: serverKey)
    }
    static func id(_ client: JellyfinClient) async -> String? {
        // Signed in as a user: that user.
        if let signedIn = JellyAccount.userID { return signedIn }
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
