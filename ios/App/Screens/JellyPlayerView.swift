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

/// JellySpace's player: AetherEngine's picture, laid out as Netflix's is. The title at the top left with
/// Picture in Picture, AirPlay, Cast, the lock and close at the right; brightness up the left side; back,
/// play/pause and on in the middle (or a double tap on either side); the red bar with the time left; then More,
/// Speed, Episodes (a film's Chapters), Audio & Subtitles and Next Episode. It resumes where Jellyfin says you stopped, saves your place there as you watch,
/// and at 90% marks it played in Jellyfin and watched in your diary. At an episode's end the next
/// one starts after a short countdown.
struct JellyPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(DiaryStore.self) private var store
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
    /// Upscaling: Off, Auto (not 50/60 fps) or Always. It only acts on SDR below 1080p, on iOS 26 GPUs
    /// that can, with Apple's super resolution and MetalFX (as Infuse does).
    @AppStorage(JellyPrefs.upscaleModeKey) private var upscaleMode = JellyUpscale.initial
    // Sound (Settings → JellySpace, and the gear menu): kept for every video.
    @AppStorage(JellyPrefs.dialogueKey) private var dialogueBoost = 0
    @AppStorage(JellyPrefs.nightKey) private var nightMode = false
    @AppStorage(JellyPrefs.boostKey) private var volumeBoost = 0
    /// Subtitles' look (Settings → JellySpace → Subtitles), read as the player opens; the size can be
    /// changed in the player too (Advanced options).
    private var subtitleLook: JellySubtitleLook { get { heavy.subtitleLook } nonmutating set { heavy.subtitleLook = newValue } }
    /// Live subtitle translation (Advanced options → Translate).
    @StateObject private var translator = JellyTranslator()
    /// mpv's subtitle line now (translated, it's drawn by the player instead).
    @State private var mpvLine = ""
    /// "Translated from Korean", for a moment as translating starts.
    @State private var translatedTag = false
    /// The cast remote closing the player (see body).
    @State private var castClosing = false
    /// GPU Enabled Zoom (Settings → JellySpace → Engines): mpv's Fill on its GPU output, or instant on AVFoundation.
    /// Off unless turned on, as Streamyfin fills: the GPU output drew in part of the screen when the
    /// phone turned as it started (fixed in JellyMPV.fitGPUOutput, kept off as the safer default).
    @AppStorage(JellyPrefs.gpuZoomKey) private var gpuZoom = false
    /// The rating card (Netflix's): the rating and IMDb's warnings, a moment after a video starts.
    private var ratingInfo: JellyRatingInfo? { get { heavy.ratingInfo } nonmutating set { heavy.ratingInfo = newValue } }
    @State private var showsRating = false
    @AppStorage(JellyPrefs.stillWatchingKey) private var stillWatchingAfter = 3
    /// Episodes started on their own in a row, with no touch between (for "Are you still watching?").
    @State private var autoplayStreak = 0
    /// The episode waiting behind "Are you still watching?".
    private var stillWatching: JellyfinClient.Item? { get { heavy.stillWatching } nonmutating set { heavy.stillWatching = newValue } }
    private var current: JellyPlayback { get { heavy.current } nonmutating set { heavy.current = newValue } }
    @State private var engine: AetherEngine?
    @State private var pip = JellyPiP()
    @State private var state: PlaybackState = .idle
    @State private var time: Double = 0
    /// The source time of the frame on screen: what subtitle cues are timed against.
    /// The file's details as fetched for the video playing, kept for a switch to the other engine.
    private var loadedInfo: (id: String, info: JellyfinClient.PlayerInfo?)? { get { heavy.loadedInfo } nonmutating set { heavy.loadedInfo = newValue } }
    /// The audio and subtitle language ("off": none) to pick on the other engine after a switch.
    private var carriedTracks: (audio: String?, subtitle: String?, subtitleName: String)? { get { heavy.carriedTracks } nonmutating set { heavy.carriedTracks = newValue } }
    /// The clock the subtitles follow, ten times a second: only the subtitles read it, so its ticks
    /// don't redraw the player.
    @State private var subtitleClock = JellySubtitleClock()
    /// The progress bar's clock (and the time beside it): ten times a second while the controls show,
    /// read only by them, so only they redraw that often.
    @State private var barClock = JellyPlayClock()
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
    @State private var noticeID = 0
    @State private var userID: String?
    /// The next episode's file details and resume point, fetched during Up Next so it opens at once.
    private var prefetch: JellyPrefetch? { get { heavy.prefetch } nonmutating set { heavy.prefetch = newValue } }
    @State private var pickedSubtitle = false
    /// The file's own subtitles (or your languages) already put on while waiting for the one you
    /// picked last time, which may be a separate file mpv adds after the video opens.
    @State private var subtitleFallbackShown = false
    /// How many separate subtitle files this video has (they arrive late on mpv).
    @State private var expectedSubtitleFiles = 0
    @State private var speed: Float = 1
    @State private var panel: Panel?
    @State private var season: [JellyfinClient.Item] = []
    /// The Episodes panel: the show's seasons, the one shown and its episodes (the playing one's at first).
    @State private var panelSeasons: [JellyfinClient.Item] = []
    @State private var panelSeasonID: String?
    @State private var panelEpisodes: [JellyfinClient.Item] = []
    @State private var panelLoading = false
    /// The brightness bar at the left (the screen's own brightness, kept in step with swipes).
    @State private var brightnessLevel: Double = 0.5
    @State private var countdown: Int?
    @State private var skipFlash: Double?
    /// Counts double taps, so each one runs the arrows again.
    @State private var skipTaps = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var pickedAudio = false
    @State private var segments: [JellyfinClient.Segment] = []
    @State private var chapters: [JellyfinClient.PlayerInfo.Chapter] = []
    private var trickplay: (info: JellyfinClient.PlayerInfo.TrickplayInfo, source: String)? { get { heavy.trickplay } nonmutating set { heavy.trickplay = newValue } }
    @State private var thumbnail: UIImage?
    /// The one sheet of scrubbing thumbnails in use (each is a big picture, so only one is kept).
    private var sheet: (index: Int, image: UIImage)? { get { heavy.sheet } nonmutating set { heavy.sheet = newValue } }
    /// The next episode beyond this season (the first of the next one).
    private var following: JellyfinClient.Item? { get { heavy.following } nonmutating set { heavy.following = newValue } }
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
    /// A control's menu is open: the controls stay up until it's used or the screen is tapped.
    /// How many menu items are on screen: above zero while a menu is open.
    @State private var menuItems = 0
    /// What an open menu shows, kept as it was when it opened: the track lists are published again as
    /// the video plays, and a menu redrawn while open jumped back to its top under your finger.
    private var openMenus: JellyMenuState? { get { heavy.openMenus } nonmutating set { heavy.openMenus = newValue } }
    private var menuOpen: Bool { menuItems > 0 }
    /// The sleep timer's choice in its menu: -1 off, 0 the end of this video, else minutes.
    @State private var sleepChoice = -1
    /// What a one-finger swipe is doing: brightness (left half, up or down), volume (right half), or
    /// moving through the video (sideways).
    @State private var swipeKind: SwipeKind?
    @State private var swipeArea = CGSize.zero
    /// The video's frame rate, from the server (0 when it doesn't say): Auto upscaling skips 50/60 fps.
    @State private var frameRate: Double = 0
    /// Playback info over the corner (More → Playback info).
    @State private var showsInfo = false
    /// Who decodes the video (More → Decoder): the engine's choice, or the app's own decoder.
    @State private var decodePath: DecodePath = .automatic
    /// What the upscaler is doing now (nil when it isn't running).
    @State private var upscale: UpscaleStatus?
    /// Stretches already skipped on their own (each once, so going back into one plays it).
    @State private var skipped: Set<Int64> = []
    /// The chosen subtitle's styles, when it's an ASS/SSA track.
    @State private var assSheet: JellyASSSheet?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Panel { case episodes, chapters, advanced, subtitleSearch }
    private enum SwipeKind { case brightness, volume, seek }

    /// mpv, the second engine (More → Decoder → mpv), and whether this video plays on it.
    @StateObject private var mpv = JellyMPV()
    @State private var usesMPV: Bool
    /// The video the engine has opened. Between a switch and the next video opening, the last one
    /// is still playing: its time mustn't mark the new one watched or be saved as its place.
    @State private var openedID: String?
    /// Hold for 2x's tap, made and readied before it's needed: making it at the moment of the speed
    /// change held up the main thread then, which on the app's own decoder costs frames.
    @State private var holdTap = UIImpactFeedbackGenerator(style: .light)
    /// The show's own aspect ratio (Preferences → Remember aspect ratio per show), nil for your default.
    @State private var showFill: JellyFill?
    /// Counts the starts again: mpv on a new output (its view follows this), or the video opened once more.
    @State private var startRun = 0
    /// The video mpv was started again for after it didn't start (see watchMPVStart).
    @State private var mpvRetriedFor: String?
    /// Where the other engine was when you switched (the next start begins there).
    @State private var switchAt: Double?
    /// mpv's smooth motion: 0 (off), 60 or 120 Hz, kept for every video.
    @AppStorage(JellyPrefs.mpvSmoothKey) private var smoothRate = 0
    /// mpv's Super Resolution: "off", "fsr" or "anime" (More → Super resolution), kept for every video.
    @AppStorage(JellyPrefs.mpvSuperResolutionKey) private var superResolution = "off"
    @State private var refresh = JellyRefreshRate()
    @Environment(\.scenePhase) private var scenePhase

    /// The player's larger values (a whole Jellyfin item is hundreds of bytes, and there were several),
    /// kept out of the view's own storage: SwiftUI copies the view as it draws (each menu action took a
    /// copy), and with them inside, the copies ran past the main thread's stack: a crash on opening a
    /// video. The names above read and write them here.
    @State private var heavy: JellyPlayerStore
    init(playback: JellyPlayback) {
        _heavy = State(initialValue: JellyPlayerStore(current: playback))
        _usesMPV = State(initialValue: JellyMPVChoice.isOn(playback.id))
        // AetherEngine's own decoder when that's the default engine (Settings → JellySpace → Engines).
        _decodePath = State(initialValue: JellyDecoder.preferred.path)
        _showFill = State(initialValue: Self.savedFill(playback.item))
    }

    /// The aspect ratio: this show's (Preferences → Remember aspect ratio per show), else your default.
    private var fill: JellyFill { showFill ?? JellyFill(rawValue: fillRaw) ?? .fit }
    /// The aspect ratio kept for the show playing, when Preferences keeps one per show.
    static func savedFill(_ item: JellyfinClient.Item) -> JellyFill? {
        guard JellyPreferences.fillPerShow, let show = item.SeriesId,
              let saved = UserDefaults.standard.string(forKey: JellyPreferences.fillKey(show: show)) else { return nil }
        return JellyFill(rawValue: saved)
    }
    private var nextEpisode: JellyfinClient.Item? {
        guard current.item.kind == "Episode" else { return nil }
        if let number = current.item.IndexNumber,
           let inSeason = season.filter({ ($0.IndexNumber ?? 0) > number }).min(by: { ($0.IndexNumber ?? 0) < ($1.IndexNumber ?? 0) }) {
            return inSeason
        }
        return following
    }

    /// The player, with live translation and the rating card added on (kept apart from the player's
    /// own long body, which the compiler checks in one go).
    var body: some View {
        // Casting to a Chromecast: the player is a remote for the TV (the phone plays nothing).
        // (Kept while the remote closes: the TV lets go a moment later, and the phone mustn't start
        // playing meanwhile.)
        Group {
            if JellyCast.shared.connected || castClosing {
                JellyCastRemote(playback: current) { castClosing = true; dismiss() }
            } else {
                AnyView(localPlayer)
            }
        }
        .jellyFaceLock()
    }
    private var localPlayer: some View {
        AnyView(player)
            // The rating card, once per video (not again on a decoder switch or a seek).
            .task(id: current.id) { await showRatingCard() }
            // Live subtitle translation (the translator runs itself, with languages already on the phone).
            .onChange(of: activeSubtitle) { _, id in translator.reset(language: subtitleTracks.first { $0.id == id }?.language) }
            .onChange(of: current.id) { _, _ in translator.reset(language: nil) }
            .onChange(of: translator.translating) { _, on in translationChanged(on) }
            .onChange(of: appDrawsMPVSubtitles, initial: true) { _, drawn in mpv.setTextHidden(drawn, look: subtitleLook) }
            .onChange(of: translator.problem) { _, text in if let text { show(text) } }
            // mpv reads its lines out as text only while a translation language is chosen.
            .onChange(of: wantsMPVText, initial: true) { _, wanted in mpv.watchesText = wanted }
    }
    /// Translating started or stopped: mpv's own text hidden or back, and the tag for a moment.
    private func translationChanged(_ on: Bool) {
        withAnimation { translatedTag = on }
        if on { Task { try? await Task.sleep(for: .seconds(3)); withAnimation { translatedTag = false } } }
    }
    /// The subtitles (the player's own, translated ones, mpv's translated line) and the Translated tag.
    private var subtitleLayer: some View {
        GeometryReader { safe in
            // Above the bar and the title while the controls show.
            let lift: CGFloat = showsControls && failure == nil ? (verticalSizeClass == .compact ? 72 : 96) : 0
            ZStack {
                JellySubtitles(cues: cues, clock: subtitleClock, delay: subtitleDelay, look: subtitleLook, insets: safe.safeAreaInsets,
                               fill: fill, videoPixels: videoSize, pixelAspect: usesMPV ? 1 : CGFloat(engine?.sourceVideoPixelAspectRatio ?? 1),
                               originalSize: CGSize(width: videoSize.width / displayScale, height: videoSize.height / displayScale),
                               sheet: subtitleLook.styled == "mine" ? nil : assSheet, lift: lift,
                               translated: translator.translating ? translator.lines : nil)
                // mpv's line, translated (mpv draws its own see-through meanwhile).
                if appDrawsMPVSubtitles, !mpvLine.isEmpty {
                    JellyTranslatedLine(text: translator.translating ? (translator.lines[mpvLine] ?? mpvLine) : mpvLine,
                                        look: subtitleLook, insets: safe.safeAreaInsets, lift: lift)
                }
                if translatedTag { translatedLabel(bottom: safe.safeAreaInsets.bottom) }
            }
            .animation(.smooth(duration: 0.25), value: showsControls)
            .ignoresSafeArea()
        }.allowsHitTesting(false)
    }
    private func translatedLabel(bottom: CGFloat) -> some View {
        Label("Translated from " + translator.sourceName, systemImage: "translate")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10).frame(height: 24).background(.black.opacity(0.5), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, max(bottom, 10)).transition(.opacity)
    }
    /// The rating card at the top corner, while it shows.
    @ViewBuilder private var ratingLayer: some View {
        if showsRating, let ratingInfo, !showsControls, !screenLocked, failure == nil {
            JellyRatingCardView(info: ratingInfo)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 16).padding(.leading, verticalSizeClass == .compact ? 8 : 20).padding(.trailing, 60)
                .transition(.opacity).allowsHitTesting(false)
        }
    }

    /// The player: its layers, then what it does as it opens, plays and closes. Its parts are wrapped
    /// (AnyView) so the player's type stays shallow: written out whole it was hundreds of levels deep,
    /// and Swift working it out on the first frame ran an iPhone's 1 MB main-thread stack out (the
    /// crash on opening a video; the Simulator's 8 MB hid it).
    private var player: some View {
        AnyView(playerTasks)
            .task(id: thumbnailIndex) { await loadThumbnail(thumbnailIndex) }
            .task(id: state == .playing) {
                // Your place, saved every 15 seconds while it plays.
                guard state == .playing else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, state == .playing else { return }
                    if heavy.movedItself { JellyMPVChoice.set(current.id, usesMPV) }
                    savePlace()
                    report("progress")
                }
            }
            .onChange(of: state) { _, now in
                if now == .playing { scheduleHide() }
                if now == .paused || now == .playing { report("progress") }
                updateSystem()
                // Not while the sleep timer is ending this episode.
                if now == .ended, autoplay, !fadingOut, !sleepAtEnd, nextEpisode != nil, countdown == nil { startCountdown() }
            }
    }
    private var playerLayers: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if usesMPV {
                AnyView(mpvPicture)
            } else if let engine {
                AnyView(picture(engine))
            }
            AnyView(subtitleLayer)
            // One finger: tap for the controls, double tap 15 seconds back (left) or on (right), hold
            // for 2x, swipe sideways to move through the video, up or down for brightness (left) or
            // volume (right). Two fingers: tap to pause or play, pinch for Fill or Fit.
            JellyGestureLayer(
                tap: {
                    touched()
                    closeMenus()
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
            if swipeKind == .seek, let scrub {
                seekCard(scrub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, showsControls ? (verticalSizeClass == .compact ? 150 : 190) : 34)
                    .animation(.smooth(duration: 0.25), value: showsControls)
                    .transition(.opacity).allowsHitTesting(false)
            }
            // A two-finger tap pauses or plays without a sign over the picture (the controls' own play
            // button shows which, when they're up).
            if buffering, !showsControls, failure == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            JellyVolumeView(volume: volume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            // With the controls up, the brightness bar at the left already shows a brightness swipe.
            if let level, !(showsControls && level.symbol == "sun.max.fill") {
                levelHUD(level).transition(.opacity).allowsHitTesting(false)
            }
            if showsInfo, !usesMPV, let engine, failure == nil, !screenLocked {
                JellyPlaybackInfo(engine: engine, serverFrameRate: frameRate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, verticalSizeClass == .compact ? 64 : 110).padding(.trailing, 16)
                    .allowsHitTesting(false)
            }
            // Holding plays at 2x either way; the badge shows only with the controls up.
            if holding, showsControls {
                Label("2x", systemImage: "forward.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 38).glassEffect(.regular, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 18).transition(.opacity).allowsHitTesting(false)
            }
            AnyView(ratingLayer)
            if let skipFlash {
                JellySeekArrows(forward: skipFlash > 0, tap: skipTaps)
                    .frame(maxWidth: .infinity, alignment: skipFlash < 0 ? .leading : .trailing)
                    .padding(.horizontal, verticalSizeClass == .compact ? 130 : 44)
                    .allowsHitTesting(false)
            }
            if screenLocked {
                AnyView(lockedLayer)
            } else {
                // The controls stay built and only fade: building them again on every tap (their glass
                // included) held up the picture for a moment as they came back.
                let controlsUp = showsControls || failure != nil
                let barUp = showsControls && failure == nil && panel == nil
                Group { AnyView(controls); AnyView(centerControls) }
                    .opacity(controlsUp ? 1 : 0).allowsHitTesting(controlsUp).accessibilityHidden(!controlsUp)
                AnyView(brightnessBar).opacity(barUp ? 1 : 0).allowsHitTesting(barUp).accessibilityHidden(!barUp)
            }
            if let segment = activeSegment, panel == nil, countdown == nil, failure == nil, !screenLocked {
                if skipMode(segment.kind) == .button { AnyView(skipButton(segment)).transition(.opacity) }
                else if let pendingSkip, pendingSkip.start == segment.StartTicks { AnyView(autoSkipButton(segment, at: pendingSkip.at)).transition(.opacity) }
            }
            // Locked, they show but take no touches (the lock's own button is under them).
            if let countdown, let next = nextEpisode { AnyView(upNext(next, in: countdown)).allowsHitTesting(!screenLocked) }
            if let next = stillWatching { AnyView(stillWatchingCard(next)).allowsHitTesting(!screenLocked).transition(.opacity) }
            if let panel {
                if panel == .advanced { AnyView(advancedCard).transition(.opacity) }
                else if panel == .episodes { AnyView(episodesPanel).transition(.opacity) }
                else { AnyView(panelView(panel)).transition(.opacity) }
            }
            if let notice {
                Text(notice).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34).background(.black.opacity(0.7), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14).transition(.opacity).allowsHitTesting(false)
            }
        }
    }
    /// The layers with how the player opens and closes, and what follows the decoder's settings.
    private var playerTasks: some View {
        AnyView(playerLayers)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // The menus (Liquid Glass) dark over the picture, as the controls are.
        .preferredColorScheme(.dark)
        .onAppear {
            holdTap.prepare()
            brightnessLevel = Double(JellyScreen.brightness)
            if let width = current.item.Width, let height = current.item.Height, width > 0, height > 0 {
                turnToPicture(CGSize(width: width, height: height))
            }
        }
        .onChange(of: videoSize) { _, size in turnToPicture(size) }
        .onDisappear {
            if let brightnessAtOpen { JellyScreen.brightness = brightnessAtOpen }
            countdownTask?.cancel()
            report("stop")
            savePlace()
            // Where it was, so a Chromecast taking over starts there.
            JellyCast.shared.handoff = (current.id, exactTime)
            engine?.stop()
            mpv.stop()
            heavy.system.end()
            // The sound let go, so music that was playing before carries on (not while JellySpace's
            // own music plays).
            if !JellyMusic.shared.playing { JellyAudioSession.release() }
            refresh.hold(0)
            OrientationLock.set(.portrait, turnTo: .portrait)
        }
        .task(id: current.id + (usesMPV ? "|mpv" : "|") + "\(startRun)") { await start() }
        // mpv's output follows smooth motion and Super Resolution (AVFoundation without them, the
        // GPU with either).
        .onChange(of: mpvOnGPU) { _, _ in moveMPVOutput() }
        // mpv's smooth motion holds the screen at its rate while it plays.
        // Set again when it's changed, and when the phone gets hot or goes into Low Power Mode (off
        // then, back after).
        .task(id: usesMPV ? "\(activeSmooth)|\(activeSuperResolution)" : "") {
            refresh.hold(usesMPV ? activeSmooth : 0)
            if usesMPV {
                mpv.setSmooth(activeSmooth, fps: frameRate)
                mpv.setSuperResolution(activeSuperResolution)
            }
        }
        .onChange(of: JellyPower.shared.constrained) { _, constrained in easeOff(constrained) }
        .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
    }
    /// Leaving the app and coming back to it.
    private func sceneChanged(_ phase: ScenePhase) {
        if phase != .active, !heavy.dimmedAway, let brightnessAtOpen {
            // Your own brightness back while you're away: iOS keeps what an app sets until the phone locks, and
            // takes no change once the app is in the background (so as it leaves, not after).
            heavy.dimmedAway = true
            JellyScreen.brightness = brightnessAtOpen
        }
        switch phase {
        case .background:
            // mpv's Metal layer can't draw in the background: the picture goes off there (the sound plays on).
            if usesMPV { mpv.showVideo(false) }
        case .active:
            if heavy.dimmedAway {
                heavy.dimmedAway = false
                let now = JellyScreen.brightness
                if let brightnessAtOpen, abs(now - brightnessAtOpen) < 0.02 {
                    JellyScreen.brightness = CGFloat(brightnessLevel)
                } else {
                    // Changed meanwhile (in Control Center): yours stays.
                    brightnessAtOpen = nil
                    brightnessLevel = Double(now)
                }
            }
            if usesMPV { mpv.showVideo(true) } else { restoreVideo() }
        default:
            break
        }
    }
    /// AetherEngine lets go of a video left paused in the background (fifteen seconds on, so nothing of it
    /// crosses a suspension) and has to open it again before it can play: until then Play did nothing. Opened
    /// where it was, still paused, as Sodalite does; a play pressed meanwhile counts (the engine keeps it).
    private func restoreVideo(playing: Bool = false) {
        guard !usesMPV, let engine, engine.needsForegroundVideoRestore, !heavy.restoring else { return }
        heavy.restoring = true
        Task {
            // A failure is said by the engine's own state (see engineState).
            _ = try? await engine.reloadAtCurrentPosition { $0.autoplay = playing }
            heavy.restoring = false
        }
    }
    /// AetherEngine's state as the player shows it. A seek on its way keeps the play or pause it was in, as
    /// Sodalite has it (the button turned to Play during every seek); a failure mid-video says why.
    private func engineState(_ now: PlaybackState) {
        guard now != .seeking else { return }
        took(now)
        if now == .playing { pip.rebuildIfNeeded() }
        if case .error(let reason) = now, heavy.loading == 0, openedID == current.id { stopped(reason) }
    }
    /// AetherEngine gave up mid-video (it stayed on its last picture, with a Play that did nothing): its reason,
    /// unless the server turns out to be gone, or the file.
    private func stopped(_ reason: String) {
        failure = "The video stopped: " + reason
        let id = current.id, run = startRun, url = current.url
        Task {
            let served = await Self.served(url)
            guard current.id == id, startRun == run, failure != nil else { return }
            if served == .unreachable { failure = Self.lostConnection }
            if served == .missing { failure = Self.missingFile }
        }
    }
    static let lostConnection = "The connection to your server was lost."
    static let missingFile = "This file isn’t available on the server right now. Its drive may be unplugged."
    /// The engine playing is in another state. A sleep timer that ran out while it was paused is over (it
    /// paused the video again eight seconds after you played it).
    private func took(_ now: PlaybackState) {
        if state == .paused, now == .playing, let sleepAt, sleepAt <= .now, !fadingOut { setSleep(nil) }
        // It plays after all (a failure another decoder got past).
        if now == .playing, failure != nil { failure = nil }
        state = now
    }

    @ViewBuilder private func picture(_ engine: AetherEngine) -> some View {
        let surface = AetherPlayerSurface(engine: engine)
            .onReceive(engine.$state) { engineState($0) }
            .onReceive(engine.clock.$currentTime) { seconds in tick(seconds) }
            // The subtitles' clock only while some show (it redrew them ten times a second for nothing).
            .onReceive(engine.clock.$sourceTime) { seconds in if activeSubtitle != nil { subtitleClock.time = seconds } }
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
            // How far it's loaded: on the bar's clock (it came about ten times a second and redrew the
            // whole player with it), and only as it moves by half a second.
            .onReceive(engine.clock.$bufferedPosition) { value in
                if abs(value - barClock.buffered) >= 0.5 || value < barClock.buffered { barClock.buffered = value }
            }
            .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume).receive(on: DispatchQueue.main)) { volumeChanged($0) }
        if fill == .original, videoSize.width > 0, videoSize.height > 0 {
            // Its own pixel size: one video pixel per screen pixel, cropped if it's bigger than the screen.
            surface.frame(width: videoSize.width / displayScale, height: videoSize.height / displayScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().ignoresSafeArea()
        } else {
            surface.ignoresSafeArea()
        }
    }

    /// mpv's picture, with its clock, tracks and size fed into the same state as AetherEngine's (mpv
    /// draws the subtitles itself, so none come through for the player's own).
    private var mpvPicture: some View {
        JellyMPVSurface(player: mpv, smooth: activeSmooth, gpu: mpvOnGPU, fill: fill)
            .id(startRun)
            .onReceive(mpv.$state) { took($0) }
            // mpv draws its own subtitles (and the app's, translated or filled, follow its line), so the
            // player's subtitle clock isn't needed here.
            .onReceive(mpv.$time) { seconds in tick(seconds) }
            .onReceive(mpv.$duration) { seconds in duration = seconds; updateSystem(duration: seconds) }
            .onReceive(mpv.$buffering) { buffering = $0; updateSystem(stalled: $0) }
            .onReceive(mpv.$audioTracks) { tracks in audioTracks = tracks; pickRememberedAudio(tracks) }
            .onReceive(mpv.$subtitleTracks) { tracks in subtitleTracks = tracks; pickDefaultSubtitle(tracks) }
            .onReceive(mpv.$audioID) { activeAudio = $0 }
            .onReceive(mpv.$subtitleID) { activeSubtitle = $0 }
            .onReceive(mpv.$subtitleText) { text in
                mpvLine = JellyPlainLines.plain(text)
                if translator.wanted { translator.want([mpvLine]) }
            }
            .onReceive(mpv.$videoSize) { size in if size.width > 0, size.height > 0 { videoSize = size } }
            .onReceive(mpv.$failure) { reason in if let reason { mpvFailed(reason) } }
            .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume).receive(on: DispatchQueue.main)) { volumeChanged($0) }
            .ignoresSafeArea()
    }

    /// The engine's clock, ten times a second. The progress bar follows it on its own clock, ten times
    /// a second while the controls show (once with them hidden, so the screen can rest at the video's
    /// own rate); the player's `time` once a second, for what reads it (the skip buttons, the end, the
    /// sleep timer). The whole player redrawing ten times a second rebuilt every button and menu with
    /// it, so a menu tapped while a video played often didn't open, or closed again.
    private func tick(_ seconds: Double) {
        let barStep = showsControls || scrub != nil ? 0.1 : 1
        if abs(seconds - barClock.time) >= barStep - 0.01 || seconds < barClock.time { barClock.time = seconds }
        if abs(seconds - time) >= 0.99 || seconds < time { time = seconds }
        reachedEnd(seconds); autoSkip(); checkSleep()
        if !usesMPV, translator.due(at: subtitleClock.time, count: cues.count) { feedTranslator() }
    }
    /// The rating card: read as the video opens; shown a second after it starts playing (waiting up to
    /// a minute for that), for six seconds. Off in Settings → JellySpace → Playback.
    private func showRatingCard() async {
        showsRating = false
        ratingInfo = nil
        guard UserDefaults.standard.object(forKey: JellyPrefs.ratingCardKey) as? Bool ?? true else { return }
        let item = current.item
        guard ["Movie", "Episode", "Video", "MusicVideo"].contains(item.kind),
              let info = await JellyRatingCard.load(item, client: current.client) else { return }
        var waited = 0
        while state != .playing, waited < 240, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        guard !Task.isCancelled, state == .playing else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        ratingInfo = info
        withAnimation(.easeInOut(duration: 0.4)) { showsRating = true }
        try? await Task.sleep(for: .seconds(6))
        withAnimation(.easeInOut(duration: 0.6)) { showsRating = false }
    }
    /// The next text lines (from a second ago on) handed to the translator, the soonest first.
    private func feedTranslator() {
        let from = subtitleClock.time - subtitleDelay - 1
        let texts = cues.filter { $0.endTime >= from }.sorted { $0.startTime < $1.startTime }.prefix(40).compactMap { cue -> String? in
            if case .image = cue.body { return nil }
            return cue.text.map(JellyPlainLines.plain)
        }
        translator.want(texts)
    }

    // The engine playing now: AetherEngine, or mpv.
    private func enginePlay() {
        if usesMPV { mpv.play() }
        else if engine?.needsForegroundVideoRestore == true { restoreVideo(playing: true) }
        else { engine?.play() }
    }
    private func enginePause() { if usesMPV { mpv.pause() } else { engine?.pause() } }
    private func engineRate(_ rate: Float) {
        guard usesMPV else { engine?.setRate(rate); return }
        mpv.setRate(rate)
        updateSystem(rate: rate)
    }
    /// mpv's lock-screen card (AetherEngine keeps its own), as it plays, pauses, moves or changes speed.
    private func updateSystem(position: Double? = nil, duration length: Double? = nil, rate: Float? = nil, stalled: Bool? = nil) {
        guard usesMPV else { return }
        // Waiting for the network, the card's time stands still too.
        heavy.system.update(playing: state == .playing, position: position ?? exactTime, duration: length ?? duration,
                            rate: (stalled ?? buffering) ? 0 : Double(rate ?? (holding ? 2 : speed)))
    }
    private func engineVolume(_ value: Float) { if usesMPV { mpv.setVolume(value) } else { engine?.volume = value } }
    private func engineAudio(_ id: Int) { if usesMPV { mpv.selectAudio(id) } else { engine?.selectAudioTrack(index: id) } }
    private func engineSubtitle(_ id: Int?) {
        if usesMPV { mpv.selectSubtitle(id) } else if let id { engine?.selectSubtitleTrack(index: id) } else { engine?.clearSubtitle() }
    }
    private func engineSubtitleDelay(_ seconds: Double) { if usesMPV { mpv.setSubtitleDelay(seconds) } else { engine?.setSoftwareSubtitleDelay(seconds) } }
    private func engineAudioDelay(_ seconds: Double) { if usesMPV { mpv.setAudioDelay(seconds) } else { engine?.setAudioDelay(seconds) } }

    /// Double tap: 15 seconds back or on, with three arrows running that way on that side (each tap
    /// runs them again; they go a moment after the last).
    private func skip(_ seconds: Double) {
        guard canSkip else { touched(); return }
        jump(seconds)
        skipTaps += 1
        let tap = skipTaps
        skipFlash = seconds
        Task { try? await Task.sleep(for: .milliseconds(900)); if skipTaps == tap { skipFlash = nil } }
    }
    /// Two-finger tap: pause or play, quietly (no sign over the picture).
    private func togglePlay() {
        touched()
        guard state == .playing || state == .paused else { return }
        if state == .playing { enginePause() } else { enginePlay() }
    }
    /// Hold: 2x while the finger stays down.
    private func startHold() {
        touched()
        guard holdOn, !holding, state == .playing, swipeKind == nil else { return }
        // The speed first, then the tap and the "2x" badge on the next turn of the main thread, so
        // nothing else runs at the moment the engine re-times its frames (the engine's own re-sync
        // is a tiny hitch on AetherEngine's routes; mpv paces frames itself and has none).
        engineRate(2)
        holding = true
        DispatchQueue.main.async {
            holdTap.impactOccurred()
            holdTap.prepare()
        }
    }
    private func endHold() {
        guard holding else { return }
        engineRate(speed)
        holding = false
    }

    /// A one-finger swipe. Sideways: through the video (the whole width is three minutes, so a short
    /// swipe is a fine move), shown on a card and played from where you let go. Up or down: brightness
    /// on the left, volume on the right (the whole height is 0 to full; swipes from the very top or
    /// bottom edge are the system's).
    private func panned(_ phase: JellyPan) {
        switch phase {
        case .began(let at, let velocity, let area):
            touched()
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
                if kind == .brightness { JellyScreen.brightness = CGFloat(value); brightnessLevel = value } else { volume.set(Float(value)) }
                levelTask?.cancel()
                level = (kind == .brightness ? "sun.max.fill" : Self.speaker(value), value)
            }
        case .ended, .cancelled:
            if swipeKind == .seek {
                if case .cancelled = phase {
                    // iOS took the touch (a swipe home, a call's banner): the video stays where it was.
                    scrub = nil
                    scheduleHide()
                } else if let target = scrub {
                    Task { await seek(target); if scrub == target { scrub = nil }; scheduleHide() }
                }
            } else if swipeKind != nil {
                hideLevel()
            }
            withAnimation(.easeOut(duration: 0.2)) { swipeKind = nil }
            swipeStart = nil
        }
    }
    /// While swiping sideways: the thumbnail there (when the server has them), where you are of how
    /// long, and how far you've moved, on a glass capsule.
    private func seekCard(_ target: Double) -> some View {
        let change = target - (swipeStart ?? target)
        return VStack(spacing: 8) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: thumbnailHeight * 200 / 160).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(spacing: 1) {
                Text(Self.clock(target) + " / " + Self.clock(duration)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text((change < 0 ? "−" : "+") + Self.offset(abs(change))).font(.system(size: 15, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
        }
    }
    /// How far a swipe moves: "01:10", "1:02:05".
    static func offset(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let whole = Int(seconds.rounded())
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60) : String(format: "%02d:%02d", whole / 60, whole % 60)
    }
    /// The level goes a moment after its last change.
    private func hideLevel() {
        levelTask?.cancel()
        levelTask = Task { try? await Task.sleep(for: .milliseconds(900)); if !Task.isCancelled { withAnimation { level = nil } } }
    }
    private static func speaker(_ level: Double) -> String { level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill" }
    /// The phone's volume buttons: the bar at the right, as a swipe's (the player's hidden volume view keeps
    /// the system's own away, so pressing them showed nothing).
    private func volumeChanged(_ value: Float) {
        let before = heavy.volumeSeen
        heavy.volumeSeen = value
        // Not as the video opens (the phone says its volume again as the sound starts), nor a swipe's own.
        guard let before, abs(before - value) > 0.001, swipeKind != .volume, openedID == current.id, state == .playing || state == .paused else { return }
        level = (Self.speaker(Double(value)), Double(value))
        hideLevel()
    }
    /// The level as a standing bar at the middle of its side: brightness on the left, volume on the
    /// right (the side the swipe is on), the icon above it.
    private func levelHUD(_ level: (symbol: String, value: Double)) -> some View {
        let brightness = level.symbol.hasPrefix("sun")
        let height: CGFloat = verticalSizeClass == .compact ? 130 : 170
        return VStack(spacing: 12) {
            Image(systemName: level.symbol).font(.system(size: 17, weight: .semibold)).frame(height: 22)
            Capsule().fill(.white.opacity(0.25)).frame(width: 6, height: height)
                .overlay(alignment: .bottom) { Capsule().fill(.white).frame(width: 6, height: height * level.value) }
        }
        .foregroundStyle(.white).padding(.vertical, 16).frame(width: 44).glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: brightness ? .leading : .trailing)
        .padding(.horizontal, 24)
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
        closeMenus()
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

    /// Brightness, as Netflix has it: the sun over a thin upright bar at the left; drag it, or swipe up
    /// and down on the left half as before.
    private var brightnessBar: some View {
        let compact = verticalSizeClass == .compact
        let length: CGFloat = compact ? 130 : 180
        return VStack(spacing: 10) {
            Image(systemName: "sun.max").font(.system(size: 18, weight: .medium))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 4)
                Capsule().fill(.white).frame(width: 4, height: length * brightnessLevel)
            }
            .frame(width: 40, height: length)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in setBrightness(1 - Double(drag.location.y / length)) }
                    .onEnded { _ in scheduleHide() }
            )
        }
        .foregroundStyle(.white).shadow(color: .black.opacity(0.45), radius: 6)
        .accessibilityElement().accessibilityLabel("Brightness").accessibilityValue("\(Int(brightnessLevel * 100)) percent")
        .accessibilityAdjustableAction { direction in
            if direction == .increment { setBrightness(brightnessLevel + 0.1) } else if direction == .decrement { setBrightness(brightnessLevel - 0.1) }
            scheduleHide()
        }
        .accessibilityIdentifier("jellyspace-brightness")
        // Sideways it's centred on the left; upright that's where back sits, so it goes up under the
        // top row instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
        .padding(.leading, compact ? 30 : 14).padding(.top, compact ? 0 : 100)
    }
    private func setBrightness(_ value: Double) {
        let level = min(1, max(0, value))
        if brightnessAtOpen == nil { brightnessAtOpen = JellyScreen.brightness }
        brightnessLevel = level
        JellyScreen.brightness = CGFloat(level)
        touched()
        // Four seconds from the last move (a drag iOS takes away has no end to start them).
        scheduleHide()
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
                // A tap shows the closed lock where the lock button always is (top right, left of
                // the close button's place), at its size; tapping it unlocks.
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { screenLocked = false; unlockShown = false; showsControls = true }
                        scheduleHide()
                    } label: {
                        Image(systemName: "lock.fill").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Unlock screen").accessibilityIdentifier("jellyspace-unlock")
                    Color.clear.frame(width: 44, height: 44)
                }
                .shadow(color: .black.opacity(0.45), radius: 6)
                .padding(.horizontal, verticalSizeClass == .compact ? 28 : 16).padding(.top, 10)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            }
        }
    }

    /// The controls fade on their own after a few seconds of playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, state == .playing, panel == nil, scrub == nil, !menuOpen else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
        }
    }

    // MARK: Starting, switching and finishing

    private func start() async {
        if !usesMPV, engine == nil { engine = try? AetherEngine() }
        if !usesMPV, engine == nil { failure = "The player couldn’t start."; return }
        // A paused song's engine would answer the lock screen's buttons together with mpv.
        if usesMPV { JellyMusic.shared.stepAside() } else { JellyMusic.shared.pause(); heavy.system.end() }
        pip.engine = engine
        // The same video moving to the other engine keeps what was found for it (the skip stretches,
        // chapters, thumbnails, the next episode and the file's details): only the engine changes.
        let handingOver = switchAt != nil && loadedInfo?.id == current.id
        failure = nil; resumedAt = nil; countdown = nil; pickedSubtitle = false; pickedAudio = false
        quality = nil; barClock.buffered = 0; heavy.seekTarget = nil
        if !handingOver {
            // Only a video's own start: a switch of engine in its last tenth logged it as watched again.
            finished = false
            openedID = nil; duration = 0
            showFill = Self.savedFill(current.item)
            skipped = []; time = 0; barClock.time = 0
            segments = []; chapters = []; trickplay = nil; thumbnail = nil; sheet = nil; following = nil
        }
        let client = current.client, id = current.id
        // The user Jellyfin keeps your places for (the administrator, else the first), found once.
        let user = await JellyfinUser.id(client)
        userID = user
        // Asked together (they went one after another): the file's details and where you stopped,
        // unless Up Next fetched them ahead. The season's episodes come after (only Next Episode and the
        // episode list need them).
        let ready = prefetch?.id == id ? prefetch : nil
        prefetch = nil
        let keptInfo = handingOver ? loadedInfo : nil
        let askInfo = keptInfo == nil && ready == nil, askPlace = switchAt == nil && resumeOn && ready == nil
        async let infoAsked = Self.fileInfo(client, id: id, user: user, wanted: askInfo)
        async let placeAsked = Self.savedSeconds(client, id: id, user: user, wanted: askPlace)
        var startAt: Double?
        var handedOver = false
        if let switchAt {
            self.switchAt = nil
            startAt = switchAt; handedOver = true
        } else if resumeOn {
            if let ready { startAt = ready.seconds } else { startAt = await placeAsked }
        }
        // Chapters, scrubbing thumbnails and separate subtitle files first (the files load with the
        // video); the intro and credits stretches while it loads.
        let extras: JellyfinClient.PlayerInfo?
        if let keptInfo { extras = keptInfo.info } else {
            if let ready { extras = ready.info } else { extras = await infoAsked }
            loadedInfo = (id, extras)
        }
        if let seasonID = current.item.SeasonId, season.first?.SeasonId != seasonID {
            Task { season = ((try? await client.children(of: seasonID, user: user)) ?? []).filter { $0.kind == "Episode" } }
        }
        // (Read already for a video only changing engine, unless it changed before they had all come.)
        let stretches: Task<[JellyfinClient.Segment]?, Never>? = handingOver && heavy.detailsFor == id ? nil
            : Task { try? await client.segments(id) }
        // The subtitle delay you last set in this show (Settings → Subtitles → Timing).
        if Self.remembersDelay, let show = current.item.SeriesId {
            subtitleDelay = UserDefaults.standard.double(forKey: Self.delayKey(show))
        }
        var options = LoadOptions()
        // ASS/SSA lines arrive with their styling, drawn by JellyASSLayer.
        options.preserveASSMarkup = true
        options.externalSubtitles = Self.subtitleFiles(extras, source: current.source, item: id, client: client)
        knownSubtitles = Set(Self.subtitleStreams(extras, source: current.source, item: id, client: client).map { $0.index })
        expectedSubtitleFiles = options.externalSubtitles.count
        subtitleFallbackShown = false
        // The fonts the styled subtitles are drawn in, from inside the video (mpv reads them itself).
        if !usesMPV {
            let fonts = Self.fontFiles(extras, source: current.source, item: id, client: client)
            if !fonts.isEmpty { Task { await JellyASSFonts.shared.load(fonts) } }
        }
        pendingSkip = nil; foundSubtitles = []
        quality = Self.qualityName(extras, source: current.source)
        // Upscaling as Infuse does it: Apple's super resolution and MetalFX for every kind of video (no
        // separate network for anime: on a 1080p episode it cost about a third of each frame and a few
        // hundred megabytes), and on Auto not for 50/60 fps.
        frameRate = Self.frameRate(extras, source: current.source)
        if usesMPV {
            // mpv: the file through its own reader, with the picture, subtitle look, speed and audio
            // delay set as it opens. The sound plays as a film's should (on with the ringer off, on in
            // the background), which AetherEngine otherwise sets up.
            // Off the main thread (it can take seconds there); the file opens once it's set.
            await JellyAudioSession.activate()
            // Closed (or moved on) while it was being set: nothing opens.
            guard !Task.isCancelled else { return }
            var settings = JellyMPV.fillSettings(fill)
                + subtitleLook.mpvSettings
            settings += [("speed", String(speed)), ("audio-delay", String(audioDelay)), ("sub-delay", String(subtitleDelay)), ("sid", "no")]
            // The next episodes played on mpv open on it too (one AetherEngine couldn't open: once it plays).
            if !heavy.movedItself { JellyMPVChoice.set(current.id, true) }
            let resume = startAt.flatMap { $0 > (handedOver ? 1 : 30) ? $0 : nil }
            mpv.open(current.url, start: resume, subtitles: options.externalSubtitles, settings: settings)
            openedID = current.id
            let mpvPlayer = mpv
            heavy.system.begin(nowPlayingInfo(nil), skip: Double(skipSeconds),
                               actions: .init(play: { mpvPlayer.play() }, pause: { mpvPlayer.pause() },
                                              seek: { mpvPlayer.seek(to: $0) }, position: { mpvPlayer.time }))
            // Now the frame rate is known: blend only where the refresh isn't a multiple of it.
            mpv.setSmooth(activeSmooth, fps: frameRate)
            mpv.setSuperResolution(activeSuperResolution)
            if let resume, !handedOver {
                resumedAt = resume
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation { resumedAt = nil } }
            }
            report("start")
            watchMPVStart(run: startRun, from: resume)
        } else {
            // Closed, or moved on, while its details came: nothing opens (as on mpv above).
            guard let engine, !Task.isCancelled else { return }
            // An anime's MKV carries its subtitle fonts as attachments, tens of megabytes read before the
            // first frame. The fonts come from Jellyfin instead (JellyASSFonts, fetched alongside and
            // kept), so the file opens without them: a quicker start and less memory (as Swiftly does).
            options.skipsContainerAttachments = true
            // The scrub bar's pictures come from Jellyfin's trickplay: AetherEngine's own (a second
            // reader downloading and decoding frames in the background) went unused.
            options.generatesBackgroundScrubPreviews = false
            // As Sodalite (AetherEngine's own Jellyfin app) opens a file on the server: the first read
            // capped at 16 MB and 10 seconds (the engine reads up to 50 MB and 60 s, slow where a file
            // ends in sparse picture subtitles or cover art); not for a link to elsewhere (.strm).
            if current.item.Path?.hasPrefix("http") != true {
                options.probesize = 16 * 1024 * 1024
                options.maxAnalyzeDuration = 10 * 1_000_000
            }
            // Closing the player keeps what this video fetched, so Resume plays it from the phone
            // (Sodalite; AetherEngine deletes it on any other load, or after an hour).
            options.retainsSessionCacheAfterStop = true
            // Subtitles in Picture in Picture, AirPlay and on a screen by cable, where the player's own
            // can't draw: the engine serves them as a track iOS draws, chosen while the video is away
            // (JellyPiP). As Sodalite: eager readers, the default track in your subtitle language.
            options.prepareNativeSubtitles = true
            options.eagerNativeSubtitleReaders = true
            if let language = UserDefaults.standard.string(forKey: JellySubtitlePrefs.languageKey), !language.isEmpty {
                options.nativeSubtitlePreferredLanguages = JellySubtitlePick.forms(language)
            }
            // Audio in your language from the first frame, chosen as mpv's is (carried over from the
            // other player, else what you picked in this show or anywhere, then Preferences). Picked
            // after the load instead, AetherEngine reloads the video to switch (a re-buffer at the start).
            let audioWanted = audioLanguagesWanted()
            if !audioWanted.isEmpty {
                // Each in all its forms ("ger", "deu", "de"): files tag languages either way.
                options.preferredAudioLanguages = audioWanted.flatMap(JellySubtitlePick.forms)
                pickedAudio = true
                carriedTracks?.audio = nil
            }
            options.upscalesLowResolutionVideo = upscaleWanted
            options.upscaleScaler = .automatic
            options.preferredDecodePath = decodePath
            options.audioShaping = Self.shaping(dialogue: dialogueBoost, night: nightMode, boost: volumeBoost)
            upscale = nil
            engine.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
            // Picture subtitles (PGS) are kept decoded either side of the playhead as far as a subtitle
            // delay can reach; the delay control stops at 15 s, so that's all that's kept (the default 60 s
            // of full-colour pictures each way, on a busy track, is enough to run the phone out of memory).
            engine.maximumSubtitleOffsetSeconds = 15
            // The lock screen and Control Center: the title, its poster, play/pause and skipping.
            engine.ownsSoftwareNowPlaying = true
            engine.ownsVideoNowPlayingSession = true
            engine.ownsVideoNowPlayingCommands = true
            engine.remoteSkipInterval = Double(skipSeconds)
            engine.setNowPlayingInfo(nowPlayingInfo(nil))
            let load = heavy.beganLoad()
            defer { heavy.endedLoad(load) }
            do {
                if let startAt, startAt > (handedOver ? 1 : 30) {
                    try await engine.load(url: current.url, startPosition: startAt, options: options)
                    if !handedOver { resumedAt = startAt }
                    Task { try? await Task.sleep(for: .seconds(6)); withAnimation { resumedAt = nil } }
                } else {
                    try await engine.load(url: current.url, options: options)
                }
                heavy.endedLoad(load)
                guard !Task.isCancelled else { return }
                openedID = current.id
                engine.play()
                report("start")
                if speed != 1 { engine.setRate(speed) }
                if audioDelay != 0 { engine.setAudioDelay(audioDelay) }
                if subtitleDelay != 0 { engine.setSoftwareSubtitleDelay(subtitleDelay) }
            } catch {
                let reason = error.localizedDescription
                await couldNotOpen(reason, onMPV: false)
                return
            }
        }
        if let stretches {
            // Each only for the video it was asked for: Next pressed meanwhile brings its own.
            let read = Self.merged((await stretches.value) ?? [])
            guard !Task.isCancelled else { return }
            segments = read
            chapters = (extras?.Chapters ?? []).sorted { $0.StartPositionTicks < $1.StartPositionTicks }
            if let entry = extras?.Trickplay?.first {
                let sorted = entry.value.values.sorted { $0.Width < $1.Width }
                if let pick = sorted.first(where: { $0.Width >= 240 }) ?? sorted.last { trickplay = (pick, entry.key) }
            }
            if segments.isEmpty, introDB {
                let found = Self.merged(await introDBSegments(client: client, user: user))
                guard !Task.isCancelled else { return }
                segments = found
            }
            if current.item.kind == "Episode", let series = current.item.SeriesId {
                let next = try? await client.episode(after: id, series: series, user: user)
                guard !Task.isCancelled else { return }
                following = next
            }
            heavy.detailsFor = id
        }
        if let url = JellySpace.poster(current.item, base: client.base), let art = await JellyfinPosterCache.shared.image(url), !Task.isCancelled {
            if usesMPV { heavy.system.show(nowPlayingInfo(art)) } else { engine?.setNowPlayingInfo(nowPlayingInfo(art)) }
        }
    }

    /// What the server says of the file itself, for a video that didn't open: it's there, it's missing (a
    /// drive unplugged), it isn't given out, or the server can't be reached. Only the answer's head is read.
    enum Served { case here, missing, refused, unreachable }
    static func served(_ url: URL) async -> Served {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let (body, answer) = try? await URLSession.shared.bytes(for: request) else { return .unreachable }
        body.task.cancel()
        return served((answer as? HTTPURLResponse)?.statusCode ?? 0)
    }
    static func served(_ status: Int) -> Served {
        switch status {
        case 200..<300: .here
        case 404: .missing
        default: .refused
        }
    }
    /// The engine couldn't open this video. Where the server has the file and gives it out, it's the engine
    /// that can't play it, and the other one tries (mpv and AetherEngine each play files the other doesn't).
    private func couldNotOpen(_ reason: String, onMPV: Bool) async {
        guard !Task.isCancelled else { return }
        let id = current.id, run = startRun
        let served = await Self.served(current.url)
        guard !Task.isCancelled, current.id == id, startRun == run, usesMPV == onMPV, !onMPV || mpv.failure != nil else { return }
        switch served {
        case .missing: failure = Self.missingFile
        case .unreachable: failure = "Your Jellyfin server can’t be reached right now."
        case .refused: failure = reason
        case .here: if !moveOver(toMPV: !onMPV, because: reason) { failure = reason }
        }
    }
    /// mpv says it failed. A connection it lost isn't a file it can't open.
    private func mpvFailed(_ reason: String) {
        guard mpv.cannotOpen else { failure = reason; return }
        Task { await couldNotOpen(reason, onMPV: true) }
    }
    /// The other engine takes this video by itself, once for each. Kept for it only once it has played
    /// there for a while (see the place saved as it plays).
    private func moveOver(toMPV: Bool, because reason: String) -> Bool {
        guard heavy.movedFor != current.id else { return false }
        heavy.movedFor = current.id
        heavy.movedItself = true
        handOver()
        if toMPV {
            JellyMPV.log.notice("AetherEngine couldn't open a video, so mpv takes it: \(reason, privacy: .private)")
            engine?.stop()
        } else {
            mpv.stop()
            decodePath = JellyDecoder.preferred.path
        }
        usesMPV = toMPV
        show(toMPV ? "AetherEngine couldn't open this video, so it's on mpv now" : "mpv couldn't play this video, so it's on AetherEngine now: " + reason, for: 8)
        return true
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
    /// The fonts inside the video (an anime's MKV carries the ones its subtitles are styled in).
    static func fontFiles(_ info: JellyfinClient.PlayerInfo?, source chosen: String?, item: String, client: JellyfinClient) -> [JellyASSFonts.File] {
        let sources = info?.MediaSources ?? []
        guard let source = sources.first(where: { $0.Id == chosen }) ?? sources.first, let sourceID = source.Id else { return [] }
        return (source.MediaAttachments ?? []).compactMap { attachment -> JellyASSFonts.File? in
            let name = attachment.FileName ?? "font-\(sourceID)-\(attachment.Index)"
            let kind = "\(attachment.MimeType ?? "") \(attachment.Codec ?? "")".lowercased()
            let fileType = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard ["ttf", "otf", "ttc", "otc"].contains(fileType) || kind.contains("font") || kind.contains("truetype") || kind.contains("opentype") else { return nil }
            return client.attachmentURL(item, source: sourceID, index: attachment.Index).map { JellyASSFonts.File(name: name, url: $0) }
        }
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
        // Not while the sleep timer fades out: skipping the credits went on to the next episode first.
        guard scrub == nil, state == .playing, !fadingOut, let segment = activeSegment, skipMode(segment.kind) == .auto,
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
        if segment.kind == "Outro", automatic ? autoplay : true, let next = nextEpisode {
            if automatic { autoAdvance(next) } else { play(next) }
            return
        }
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
        .padding(.trailing, 28).padding(.bottom, showsControls ? 160 : 36)
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
        .padding(.trailing, 28).padding(.bottom, showsControls ? 160 : 36)
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
    /// Your remembered audio or subtitle language. Carried across a show's episodes (Preferences):
    /// what you picked in this show, and nothing for a film or a show you haven't picked in (your
    /// defaults then apply). Otherwise your last choice anywhere.
    private func remembered(_ kind: String) -> String? {
        let defaults = UserDefaults.standard
        if JellyPreferences.perShow {
            guard let show = current.item.SeriesId else { return nil }
            return defaults.string(forKey: "jellyspace.\(kind).\(show)")
        }
        return defaults.string(forKey: "jellyspace.\(kind)")
    }
    private func remember(_ kind: String, _ value: String) {
        guard rememberTracks else { return }
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: "jellyspace.\(kind)")
        if let show = current.item.SeriesId { defaults.set(value, forKey: "jellyspace.\(kind).\(show)") }
    }
    /// The audio languages to start in, best first, as pickRememberedAudio chooses: the one carried
    /// over from the other player alone; else what you picked (in this show, or anywhere), then
    /// Preferences. Empty: the file's own default.
    private func audioLanguagesWanted() -> [String] {
        if let carried = carriedTracks?.audio, !carried.isEmpty { return [carried] }
        var wanted: [String] = []
        if rememberTracks, let language = remembered("audioLanguage") { wanted.append(language) }
        for language in JellyPreferences.audioLanguages where !wanted.contains(language) { wanted.append(language) }
        return wanted
    }
    private func pickRememberedAudio(_ tracks: [TrackInfo]) {
        guard !pickedAudio, !tracks.isEmpty else { return }
        pickedAudio = true
        // Just switched engine: the language that was playing.
        if let carried = carriedTracks?.audio {
            carriedTracks?.audio = nil
            if let track = Self.audio(in: carried, of: tracks), track.id != activeAudio { engineAudio(track.id) }
            return
        }
        // What you picked (in this show, or anywhere), then your default languages (Preferences),
        // else the file's own default, which is already playing.
        var wanted: [String] = []
        if rememberTracks, let language = remembered("audioLanguage") { wanted.append(language) }
        wanted += JellyPreferences.audioLanguages
        for language in wanted {
            guard let track = Self.audio(in: language, of: tracks) else { continue }
            if track.id != activeAudio { engineAudio(track.id) }
            return
        }
    }
    /// The film's own sound in a language: never its commentary or its audio description.
    static func audio(in language: String, of tracks: [TrackInfo]) -> TrackInfo? {
        tracks.first { JellySubtitlePick.same($0.language, language) && !$0.isCommentary && !$0.isVisualImpaired }
    }

    /// The next episode on its own (after the countdown, or past the credits): first "Are you still
    /// watching?" when enough have started like that in a row with no touch between (Settings →
    /// JellySpace).
    private func autoAdvance(_ next: JellyfinClient.Item) {
        if stillWatchingAfter > 0, autoplayStreak >= stillWatchingAfter {
            countdown = nil
            enginePause()
            withAnimation(.easeInOut(duration: 0.25)) { stillWatching = next; showsControls = false }
            return
        }
        let streak = autoplayStreak + 1
        play(next)
        autoplayStreak = streak
    }
    /// Any touch on the player: someone's watching.
    private func touched() { autoplayStreak = 0 }
    /// "Are you still watching?": keep watching (the next episode), or stop (close the player).
    private func stillWatchingCard(_ next: JellyfinClient.Item) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Are you still watching?").font(.system(size: 22, weight: .bold))
                Text([next.IndexNumber.map { "Up next: E\($0)" }, next.Name].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                HStack(spacing: 12) {
                    Button {
                        withAnimation { stillWatching = nil }
                        play(next)
                    } label: {
                        Label("Keep watching", systemImage: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 20).frame(height: 44).background(.white, in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-still-watching")
                    Button { dismiss() } label: {
                        Text("Stop").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 22).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-still-watching-stop")
                }.padding(.top, 8)
            }
            .foregroundStyle(.white).padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
    /// Another episode in the same player: your place in this one is kept first.
    private func play(_ item: JellyfinClient.Item) {
        autoplayStreak = 0
        report("stop")
        savePlace()
        countdown = nil; panel = nil
        guard let next = JellySpace.playback(item, client: current.client) else { return }
        // The last video stops while the next one's details load.
        enginePause()
        // On the engine that episode was set (or moved) to; else the one playing now, unless this video
        // was only there because its own couldn't play it: then your default again.
        let onMPV = JellyMPVChoice.own(item.Id) ?? (heavy.movedItself ? JellyDecoder.preferred == .mpv : usesMPV)
        if onMPV != usesMPV {
            if usesMPV { mpv.stop() } else { engine?.stop() }
            // The old engine's tracks go (a number of theirs could pass for one of the new engine's).
            audioTracks = []; subtitleTracks = []; activeAudio = nil; activeSubtitle = nil
            if !onMPV { decodePath = JellyDecoder.preferred.path }
            usesMPV = onMPV
        }
        heavy.movedItself = false
        current = next
    }

    private func startCountdown() {
        prefetchNext()
        countdown = countdownSeconds
        countdownTask?.cancel()
        // With the phone locked the sound has just stopped, and iOS would put the app to sleep before the
        // next episode starts: it's asked for the time (and a few seconds for the opening).
        let hold = JellyBackgroundTime("JellySpace Up Next")
        countdownTask = Task {
            defer { Task { try? await Task.sleep(for: .seconds(8)); hold.end() } }
            while let left = countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, countdown != nil else { return }
                countdown = left - 1
            }
            if countdown == 0, let next = nextEpisode { autoAdvance(next) }
        }
    }
    /// Moved back from the end (as Streamyfin does it): Up Next goes, and comes again at the end.
    private func stopCountdown() {
        countdownTask?.cancel()
        withAnimation { countdown = nil }
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
                guard fadingOut else { engineVolume(1); return }
                engineVolume(max(0, 1 - Float(step) / 16))
            }
            enginePause()
            engineVolume(1)
            countdown = nil
            fadingOut = false; sleepAt = nil; sleepAtEnd = false; sleepChoice = -1
            show("Sleep timer: paused")
        }
    }
    private func setSleep(_ minutes: Int?) {
        fadingOut = false
        engineVolume(1)
        sleepAtEnd = minutes == 0
        sleepChoice = minutes ?? -1
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
    /// The engine's own clock this moment (the player's `time` follows it only once a second while the
    /// controls are hidden).
    private var exactTime: Double {
        let now = usesMPV ? mpv.time : (engine?.clock.currentTime ?? time)
        return now.isFinite && now > 0 ? now : time
    }
    private func savePlace() {
        let at = exactTime
        guard openedID == current.id, let user = userID, at > 5, !(finished && at >= duration * 0.9) else { return }
        let client = current.client, id = current.id
        Task { try? await client.savePosition(id, user: user, seconds: at) }
    }

    /// At 90%: played in Jellyfin, watched in the diary, once.
    private func reachedEnd(_ seconds: Double) {
        guard openedID == current.id, !finished, duration > 60, seconds >= duration * 0.9 else { return }
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
        guard JellyAccount.token != nil, openedID == current.id else { return }
        let client = current.client, id = current.id, source = current.source, at = exactTime, paused = state == .paused
        Task { await client.report(event, item: id, source: source, seconds: at, paused: paused) }
    }

    private func show(_ text: String, for seconds: Double = 4) {
        noticeID += 1
        let id = noticeID
        withAnimation { notice = text }
        // Only the latest notice clears it, so an earlier one's timer can't cut a newer one short.
        Task { try? await Task.sleep(for: .seconds(seconds)); withAnimation { if noticeID == id { notice = nil } } }
    }

    /// Your remembered subtitle language (or off); else what Settings → Subtitles asks for (your
    /// languages, forced only, or none; else the file's default), once when the tracks first arrive.
    private func pickDefaultSubtitle(_ tracks: [TrackInfo]) {
        guard !pickedSubtitle, !tracks.isEmpty else { return }
        // Just switched player: what was on. Else what you picked last time (in this show, or anywhere).
        let wanted: (key: String, name: String)?
        if let carried = carriedTracks?.subtitle {
            wanted = (carried, carriedTracks?.subtitleName ?? "")
        } else if rememberTracks, let saved = remembered("subtitleLanguage") {
            wanted = (saved, remembered("subtitleName") ?? "")
        } else {
            wanted = nil
        }
        if wanted?.key == "off" {
            settleSubtitle()
            engineSubtitle(nil)
            return
        }
        if let wanted, let track = Self.subtitle(matching: wanted.key, name: wanted.name, in: tracks) {
            settleSubtitle()
            if track.id != activeSubtitle { engineSubtitle(track.id) }
            return
        }
        // Not here yet: on mpv the separate subtitle files come after the video opens. Until they
        // have, the file's own (or your languages) show, and the list is looked at again.
        if wanted != nil, usesMPV, tracks.filter(\.isExternal).count < expectedSubtitleFiles {
            if !subtitleFallbackShown, let track = JellySubtitlePick.choose(tracks) { engineSubtitle(track.id) }
            subtitleFallbackShown = true
            return
        }
        settleSubtitle()
        guard !subtitleFallbackShown else { return }
        // Preferences: your languages, forced only, or none.
        if let track = JellySubtitlePick.choose(tracks) {
            engineSubtitle(track.id)
        }
    }
    /// The subtitles chosen for this video: no more looking (and a switch's carried choice used up).
    private func settleSubtitle() {
        pickedSubtitle = true
        carriedTracks?.subtitle = nil
    }

    // MARK: Controls

    private var playingNow: Bool { state == .playing }
    /// Nothing to control yet: it's opening, or it failed and what to do about it is being worked out.
    private var waiting: Bool {
        switch state {
        case .loading, .idle, .error: true
        default: false
        }
    }

    /// Netflix's arrangement: the title at the top left (Jellyfin's mark, the episode or film, and under
    /// it the show, or the film's year and quality); Picture in Picture, AirPlay, Cast, the lock and close at the top
    /// right; back, play and on in the middle; the red bar with the time left; then More, Speed,
    /// Episodes (a film's Chapters), Audio & Subtitles and Next Episode, each with its name (just the symbols upright,
    /// where the names don't fit).
    private var controls: some View {
        let compact = verticalSizeClass == .compact
        let side: CGFloat = compact ? 28 : 16
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image("jellyfin-mark").resizable().scaledToFit().frame(width: 26, height: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playerTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    if !infoLine.isEmpty {
                        Text(infoLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 10)
                AnyView(sleepBadge)
                if batteryOn { JellyBattery() }
                if pip.available, !usesMPV {
                    topIcon("pip.enter", label: "Picture in Picture") { pip.start() }.accessibilityIdentifier("jellyspace-pip")
                }
                // AirPlay sideways (upright there's no room), and for a picture AVPlayer plays: nothing else can go to a TV.
                JellyTVButtons(airPlay: compact && !usesMPV && engine?.nativePlayerLayer != nil)
                topIcon("lock.open", label: "Lock screen") { lockScreen() }.accessibilityIdentifier("jellyspace-lock-screen")
                topIcon("xmark", label: "Close player") { dismiss() }.accessibilityIdentifier("jellyspace-close")
            }
            .shadow(color: .black.opacity(0.45), radius: 6)
            .padding(.horizontal, side).padding(.top, 10)
            Spacer(minLength: 0)
            if let resumedAt {
                // Sideways it starts clear of the brightness bar's foot.
                resumePill(resumedAt).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, side)
                    .padding(.leading, verticalSizeClass == .compact ? 56 : 0).padding(.bottom, 8)
            }
            // The bar, red as far as you've watched, and the time left beside it (a tap shows the whole
            // length instead).
            HStack(spacing: 14) {
                JellyScrubber(clock: barClock, duration: duration, marks: chapterMarks, stretches: coloredStretches,
                              tint: Self.red, knob: Self.red, scrub: $scrub, released: { scheduleHide() }) { target in
                    // Only its own: a drag begun before this one landed keeps the bar.
                    Task { await seek(target); if scrub == target { scrub = nil }; scheduleHide() }
                }
                .overlay(alignment: .topLeading) { AnyView(scrubPreview) }
                .disabled(duration <= 0)
                Button { timeMode = timeMode == "total" ? "left" : "total"; scheduleHide() } label: {
                    JellyTimeLeft(clock: barClock, duration: duration, scrub: scrub, total: timeMode == "total")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(timeMode == "total" ? "Length" : "Time left").accessibilityValue(endsText)
                .accessibilityIdentifier("jellyspace-time-left")
            }
            .padding(.horizontal, side)
            AnyView(bottomRow).padding(.horizontal, side).padding(.bottom, compact ? 4 : 10)
        }
        .background {
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
    }
    static let red = Color(red: 0.9, green: 0.04, blue: 0.08)
    /// More, Speed, Episodes, Audio & Subtitles and Next Episode, named where they fit.
    private var bottomRow: some View {
        let menus = openMenus ?? menuState
        // Named and spaced out; named and closer together (a longer name, "Speed (1.25x)", no longer
        // squeezes them down to symbols); then just the symbols.
        return ViewThatFits(in: .horizontal) {
            bottomButtons(menus, labelled: true, spacing: 28)
            bottomButtons(menus, labelled: true, spacing: 14)
            bottomButtons(menus, labelled: false, spacing: 4)
        }
        .frame(maxWidth: .infinity)
    }
    private func bottomButtons(_ menus: JellyMenuState, labelled: Bool, spacing: CGFloat) -> some View {
        let actions = menuActions
        return HStack(spacing: spacing) {
            JellyMoreMenu(state: menus, actions: actions, labelled: labelled).equatable()
            JellySpeedMenu(state: menus, actions: actions, labelled: labelled).equatable()
            if current.item.kind == "Episode" {
                barButton("rectangle.stack", title: "Episodes", labelled: labelled) { openEpisodes() }
                    .accessibilityIdentifier("jellyspace-episodes")
            }
            // An episode's row is full: its chapters are in More.
            if current.item.kind != "Episode", chapters.count > 1 {
                barButton("list.bullet", title: "Chapters", labelled: labelled) { openPanel(.chapters) }
                    .accessibilityIdentifier("jellyspace-chapters")
            }
            JellyTracksMenu(state: menus, actions: actions, labelled: labelled).equatable()
            if let next = nextEpisode {
                barButton("forward.end", title: "Next Episode", labelled: labelled) { play(next) }.accessibilityIdentifier("jellyspace-next")
            }
        }
        .fixedSize()
    }
    private func barButton(_ symbol: String, title: String, labelled: Bool, action: @escaping () -> Void) -> some View {
        Button { touched(); action(); scheduleHide() } label: { JellyMenuParts.label(symbol, title, labelled: labelled) }
            .buttonStyle(.plain).accessibilityLabel(title)
    }
    /// One of the top right's symbols.
    private func topIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button { touched(); action(); scheduleHide() } label: {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    /// Back, play and on, in the middle of the whole screen (not of the space between the top and
    /// bottom rows, which aren't the same height); the error or the spinner there instead.
    private var centerControls: some View {
        Group {
            if let failure {
                failureCard(failure)
            } else if waiting {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                // The skip length in the arrows where there's a symbol for it (5, 10, 15, 30, 45, 60, 75, 90).
                let numbered = [5, 10, 15, 30, 45, 60, 75, 90].contains(skipSeconds)
                HStack(spacing: verticalSizeClass == .compact ? 130 : 56) {
                    transport(numbered ? "gobackward.\(skipSeconds)" : "gobackward", label: "Back \(skipSeconds) seconds") { jump(Double(-skipSeconds)) }
                    Button {
                        touched()
                        if state == .ended { replay() }
                        else if playingNow { enginePause() } else { enginePlay() }
                        scheduleHide()
                    } label: {
                        Group {
                            if buffering { ProgressView().controlSize(.large).tint(.white) }
                            else {
                                Image(systemName: playingNow ? "pause.fill" : state == .ended ? "arrow.counterclockwise" : "play.fill")
                                    .font(.system(size: 52, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 84, height: 84).contentShape(Rectangle())
                        .shadow(color: .black.opacity(0.35), radius: 8)
                    }.buttonStyle(.plain).accessibilityLabel(playingNow ? "Pause" : "Play")
                    transport(numbered ? "goforward.\(skipSeconds)" : "goforward", label: "Forward \(skipSeconds) seconds") { jump(Double(skipSeconds)) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// What went wrong, and what to do about it: the video tried again where it was, or on the other decoder.
    private func failureCard(_ text: String) -> some View {
        VStack(spacing: 14) {
            Text(text).font(.system(size: 14)).foregroundStyle(.white).multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { failureButtons }
                VStack(spacing: 10) { failureButtons }
            }
        }
        .padding(18).frame(maxWidth: 520).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 24)
    }
    @ViewBuilder private var failureButtons: some View {
        Button { touched(); retry() } label: {
            Label("Try again", systemImage: "arrow.clockwise").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                .fixedSize().padding(.horizontal, 20).frame(height: 44).background(.white, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-try-again")
        Button { touched(); setDecoder(otherDecoder) } label: {
            Text(usesMPV ? "Play on AetherEngine" : "Play on mpv").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .fixedSize().padding(.horizontal, 20).frame(height: 44).background(.white.opacity(0.18), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-other-decoder")
    }
    /// The decoder to try instead: mpv, or AetherEngine as it's set by default.
    private var otherDecoder: JellyDecoder { usesMPV ? (JellyDecoder.preferred == .app ? .app : .auto) : .mpv }
    /// The video again in this player: where it was, or (it never opened) as it opens by itself.
    private func retry() { reopen(at: openedID == current.id ? exactTime : nil) }

    // MARK: Menus

    /// What the menus show now (they redraw only when this changes, not on every tick of playback).
    private var menuState: JellyMenuState {
        JellyMenuState(subtitles: subtitleTracks.map { JellyTrackChoice(id: $0.id, label: Self.label($0, audio: false)) },
                       audio: audioTracks.count > 1 ? audioTracks.map { JellyTrackChoice(id: $0.id, label: Self.label($0, audio: true)) } : [],
                       subtitle: activeSubtitle ?? -1, audioTrack: activeAudio ?? -1, sleep: sleepChoice, speed: Double(speed),
                       upscale: upscaleMode, episode: current.item.kind == "Episode",
                       dialogue: dialogueBoost, night: nightMode, boost: volumeBoost,
                       fill: fill, pictures: pictureChoices, rotationLocked: rotationLocked, info: showsInfo,
                       chapters: current.item.kind == "Episode" && chapters.count > 1,
                       decoder: usesMPV ? .mpv : (decodePath == .software ? .app : .auto), mpv: usesMPV, smooth: smoothRate,
                       superResolution: superResolution)
    }
    /// What the menus' choices do.
    /// The menus' actions. They reach the player through one shared copy of it (`me`): each of these
    /// closures took its own copy of the whole view before, all at once on the main thread's stack (the
    /// crash on opening a video, with the larger values in the view).
    private var menuActions: JellyMenuActions { Self.menuActions(JellyPlayerRef(self)) }
    private static func menuActions(_ me: JellyPlayerRef) -> JellyMenuActions {
        JellyMenuActions(
            opened: { me.view.menuShown() },
            closed: { me.view.menuGone() },
            sleep: { choice in me.view.menuUsed(); me.view.setSleep(choice < 0 ? nil : choice) },
            speed: { value in me.view.menuUsed(); me.view.speed = Float(value); me.view.engineRate(Float(value)) },
            upscale: { mode in me.view.menuUsed(); me.view.setUpscale(mode) },
            subtitle: { id in me.view.pickSubtitle(id) },
            audio: { id in me.view.pickAudio(id) },
            download: { me.view.openPanel(.subtitleSearch) },
            chapters: { me.view.openPanel(.chapters) },
            advanced: { me.view.openPanel(.advanced) },
            dialogue: { level in
                me.view.menuUsed(); me.view.dialogueBoost = level
                me.view.applySound("Dialogue boost: " + (JellySound.dialogue.first { $0.1 == level }?.0 ?? "Off"))
            },
            night: { on in me.view.menuUsed(); me.view.nightMode = on; me.view.applySound(on ? "Night mode on" : "Night mode off") },
            boost: { percent in
                me.view.menuUsed(); me.view.volumeBoost = percent
                me.view.applySound("Volume boost: " + (JellySound.boost.first { $0.1 == percent }?.0 ?? "Off"))
            },
            fill: { next in me.view.menuUsed(); me.view.setFill(next) },
            rotation: { me.view.menuUsed(); me.view.toggleRotation() },
            info: { on in me.view.menuUsed(); withAnimation(.easeInOut(duration: 0.2)) { me.view.showsInfo = on } },
            decoder: { path in me.view.menuUsed(); me.view.setDecoder(path) },
            superResolution: { mode in
                me.view.menuUsed(); me.view.superResolution = mode
                let power = JellyPower.shared
                let name = JellyPlayerView.superResolutions.first { $0.1 == mode }?.0 ?? mode
                me.view.show(mode == "off" ? "Super Resolution off" : power.constrained ? "Super Resolution: \(name), paused " + power.reason : "Super Resolution: " + name)
            },
            smooth: { rate in
                me.view.menuUsed(); me.view.smoothRate = rate
                let power = JellyPower.shared
                me.view.show(rate == 0 ? "Smooth motion off" : power.constrained ? "Smooth motion: \(rate) Hz, paused " + power.reason : "Smooth motion: \(rate) Hz")
            })
    }
    /// A subtitle picked (-1 for off): turned on, and its language remembered.
    private func pickSubtitle(_ id: Int) {
        menuUsed()
        // Your own pick ends the wait for the remembered one.
        pickedSubtitle = true
        guard id != (activeSubtitle ?? -1) else { return }
        if id >= 0 {
            engineSubtitle(id)
            if let track = subtitleTracks.first(where: { $0.id == id }) {
                // Its language (or, a track with none, its name) and its name: of two English tracks,
                // Full and Signs & Songs, the next episode takes the same one.
                let key = Self.subtitleKey(track)
                if !key.isEmpty { remember("subtitleLanguage", key) }
                remember("subtitleName", track.name)
            }
        } else {
            engineSubtitle(nil)
            remember("subtitleLanguage", "off")
        }
    }
    private func pickAudio(_ id: Int) {
        menuUsed()
        guard id != activeAudio, let track = audioTracks.first(where: { $0.id == id }) else { return }
        engineAudio(id)
        if let language = track.language { remember("audioLanguage", language) }
    }
    /// A menu opened: the controls stay up meanwhile.
    private func menuShown() {
        touched()
        if openMenus == nil { openMenus = menuState }
        menuItems += 1
        hideTask?.cancel()
    }
    /// A menu's items left the screen: once none are left, the controls hide as usual.
    private func menuGone() {
        menuItems = max(0, menuItems - 1)
        if menuItems == 0 { openMenus = nil; scheduleHide() }
    }
    /// A choice made in a menu (which closes it).
    private func menuUsed() {
        closeMenus()
        scheduleHide()
    }
    /// Every menu closed: the next one shows what's true then.
    private func closeMenus() {
        menuItems = 0
        openMenus = nil
    }
    private func openPanel(_ next: Panel) {
        closeMenus()
        withAnimation { panel = next }
    }

    /// Advanced options: the subtitle and audio delays and subtitle downloads, on a glass card over
    /// the corner (a tap anywhere else closes it).
    private var advancedCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { withAnimation { panel = nil }; scheduleHide() }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Advanced options").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 12)
                    Button { withAnimation { panel = nil }; scheduleHide() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(.white.opacity(0.15), in: Circle()).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Close")
                }
                // Whole when there's room; else the rows scroll under the title (sideways it's short).
                ViewThatFits(in: .vertical) {
                    advancedRows
                    ScrollView { advancedRows }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                }
            }
            .padding(18).frame(width: 330)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
            .padding(.trailing, 24).padding(.top, 8).padding(.bottom, verticalSizeClass == .compact ? 64 : 96)
        }
        .accessibilityIdentifier("jellyspace-advanced")
    }

    /// Advanced options' rows: the subtitles' size, height, translation and delay; the sound's delay;
    /// subtitle downloads.
    private var advancedRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !subtitleTracks.isEmpty {
                subtitleSizeControl
                subtitlePositionControl
                translateControl
                delayControl("Subtitle delay", value: subtitleDelay, step: Self.delayStep) { setSubtitleDelay($0) }
            }
            delayControl("Audio delay", value: audioDelay) { audioDelay = $0; engineAudioDelay($0) }
            Button { withAnimation { panel = .subtitleSearch } } label: {
                Label("Download subtitles", systemImage: "arrow.down.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 36).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-download-subtitles")
        }
    }

    /// "Resumed at 10:55 · Start over": a tap plays from the beginning.
    private func resumePill(_ at: Double) -> some View {
        Button { Task { await seek(0) }; withAnimation { resumedAt = nil } } label: {
            Text("Resumed at \(Self.clock(at)) · Start over").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30).contentShape(Capsule())
        }
        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityIdentifier("jellyspace-start-over").transition(.opacity)
    }
    /// "S1:E3 “The Man with the Umbrella”" for an episode; a film's name.
    private var playerTitle: String {
        let item = current.item
        guard item.kind == "Episode" else { return item.Name ?? current.title }
        let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: ":")
        return [place.isEmpty ? nil : place, item.Name.map { "“" + $0 + "”" }].compactMap { $0 }.joined(separator: " ")
    }
    /// The show's name for an episode; "2000 · Drama · 1080p HEVC" for a film; then "Upscaled from
    /// 720p" while the upscaler runs.
    private var infoLine: String {
        let item = current.item
        let base = item.kind == "Episode" ? (item.SeriesName ?? "")
            : [item.ProductionYear.map(String.init), item.Genres?.first, quality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return [base, upscaleLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// "Upscaled from 720p", only while the upscaler is running.
    private var upscaleLabel: String? {
        guard let upscale, upscale.disabledReason == nil, upscale.sourceSize.height > 0 else { return nil }
        return "Upscaled from \(Int(upscale.sourceSize.height))p"
    }
    /// Where the video is and which audio and subtitles are on, for the player that takes it over
    /// (the other engine, or mpv on its other output): it opens there, in the same languages (the
    /// tracks number differently on each).
    private func handOver() {
        let now = exactTime
        switchAt = now > 1 ? now : nil
        // Subtitles as they're remembered: the language (a track with none, its name) and the name.
        let subtitle = activeSubtitle.flatMap { id in subtitleTracks.first { $0.id == id } }
        // Not made yet (a video that never opened), it isn't "off": the other player chooses as it would
        // have, or takes what was carried to this one.
        let before = carriedTracks
        let audio: String? = audioTracks.first { $0.id == activeAudio }?.language ?? before?.audio
        if pickedSubtitle {
            carriedTracks = (audio: audio, subtitle: subtitle.map(Self.subtitleKey) ?? "off", subtitleName: subtitle?.name ?? "")
        } else {
            carriedTracks = (audio: audio, subtitle: before?.subtitle, subtitleName: before?.subtitleName ?? "")
        }
        // The old player's tracks and choices go: the new one's arrive with the video (left, a track
        // number of the old could pass for the new one's and a switch be skipped).
        audioTracks = []; subtitleTracks = []; activeAudio = nil; activeSubtitle = nil
    }
    /// How a subtitle track is remembered: its language, or (none, or "und") its name.
    static func subtitleKey(_ track: TrackInfo) -> String {
        if let language = track.language, !language.isEmpty, language != "und" { return language }
        return track.name.isEmpty ? "" : "name:" + track.name
    }
    /// The track that matches a remembered or carried one: by language (or name), and of several the
    /// one with the same name, else a full one before a forced one.
    static func subtitle(matching key: String, name: String, in tracks: [TrackInfo]) -> TrackInfo? {
        guard !key.isEmpty else { return nil }
        let matching = key.hasPrefix("name:") ? tracks.filter { "name:" + $0.name == key } : tracks.filter { JellySubtitlePick.same($0.language, key) }
        return matching.first { !name.isEmpty && $0.name == name } ?? matching.first { !$0.isForced } ?? matching.first
    }
    /// Smooth motion turned on or off (by you, or by the phone getting hot): mpv moves between its
    /// AVFoundation output and the GPU one, which only the GPU can blend frames on. That's a new
    /// view and a new mpv, opened where the video was.
    /// mpv opened but nothing came for 20 seconds (no picture, no error: the Simulator QA run caught it
    /// once in ten opens, a spinner for good): mpv starts again where it was, once; then the error.
    private func watchMPVStart(run: Int, from start: Double?) {
        let id = current.id
        Task {
            try? await Task.sleep(for: .seconds(20))
            // mpv opened the file but the picture hasn't moved from where it started (a file it can't
            // play here, though AetherEngine can): the video moves to AetherEngine at that place. A
            // network wait (buffering) gets twenty seconds more first. Not after you paused it.
            for wait in [0, 20] {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard usesMPV, startRun == run, current.id == id, mpv.hasLoaded, mpv.failure == nil, failure == nil,
                      mpv.state != .paused, mpv.state != .ended, mpv.time < (start ?? 0) + 1 else { break }
                if mpv.buffering && wait == 0 { continue }
                JellyMPV.log.error("mpv opened but didn't play in \(20 + wait, privacy: .public) s: \(mpv.diagnosis, privacy: .public)")
                let reason = mpv.lastMessage ?? "nothing played"
                if !moveOver(toMPV: false, because: reason) { failure = "This video couldn’t be played: " + reason }
                return
            }
            // mpv's own state: once the player has closed, mpv has stopped (idle), so nothing happens.
            guard usesMPV, startRun == run, current.id == id, !mpv.hasLoaded, mpv.failure == nil, failure == nil, mpv.state == .loading else { return }
            JellyMPV.log.error("mpv didn't start in 20 s (run \(run, privacy: .public)): \(mpv.diagnosis, privacy: .public)")
            // Once a video: the next episode gets its own try.
            if mpvRetriedFor == id {
                failure = "The video didn't start."
                return
            }
            mpvRetriedFor = id
            switchAt = start ?? 0
            mpv.stop()
            startRun += 1
        }
    }
    private func moveMPVOutput() {
        guard usesMPV, mpv.running || state != .idle else { return }
        handOver()
        mpv.stop()
        startRun += 1
    }

    /// Auto or the app's own decoder: the video reloads where it is on the new one. mpv: the video
    /// moves to the mpv player where it is (and opens there from then on).
    private func setDecoder(_ choice: JellyDecoder) {
        heavy.movedItself = false
        if (choice == .mpv) != usesMPV {
            // The other engine takes over where this one is, and this video opens on it from now on.
            handOver()
            JellyMPVChoice.set(current.id, choice == .mpv)
            if choice == .mpv { engine?.stop() } else { mpv.stop() }
            decodePath = choice.path
            show("Decoder: " + choice.title)
            usesMPV = choice == .mpv
            return
        }
        guard choice != .mpv else { return }
        let path = choice.path
        guard path != decodePath else { return }
        decodePath = path
        show("Decoder: " + choice.title)
        guard let engine, state != .idle, state != .loading else { return }
        Task { _ = try? await engine.reloadAtCurrentPosition { $0.preferredDecodePath = path } }
    }
    /// Turned on or off mid-video: the video reloads where it is with the new setting.
    /// mpv's smooth motion as it runs now: off while the phone is hot or in Low Power Mode.
    private var activeSmooth: Int { JellyPower.shared.constrained ? 0 : smoothRate }
    /// mpv's Super Resolution as it runs now: off while the phone is hot or in Low Power Mode.
    private var activeSuperResolution: String { JellyPower.shared.constrained ? "off" : superResolution }
    /// The Picture choices: all of them on both players (on mpv, Fill and Original use the GPU output).
    private var pictureChoices: [JellyFill] { JellyFill.allCases }
    /// Whether mpv needs its GPU output: smooth motion or Super Resolution on, or the picture filled
    /// or at its own size. Through AVFoundation the subtitles are composited into the frames, which
    /// Fill would crop (and the layer has no pixel-for-pixel size); on the GPU they're placed on what's
    /// shown. So AVFoundation, the coolest way, plays fitted pictures.
    private var mpvOnGPU: Bool {
        activeSmooth > 0 || activeSuperResolution != "off" || fill == .original || (fill == .fill && gpuZoom)
    }
    /// The app draws mpv's subtitle line (mpv's own drawn see-through): while translating, or filled on
    /// AVFoundation (GPU Enabled Zoom off), where mpv's, in the frames, would be cropped with them.
    private var appDrawsMPVSubtitles: Bool { usesMPV && (translator.translating || (fill == .fill && !mpvOnGPU)) }
    /// mpv reads its lines out as text: for translating (from the language being chosen) or for the
    /// app to draw them.
    private var wantsMPVText: Bool { !translator.target.isEmpty || appDrawsMPVSubtitles }
    /// Whether this video is upscaled: by the setting, but on Auto not while the phone is hot or in
    /// Low Power Mode (Always means always).
    private var upscaleWanted: Bool { upscaleAllowed(upscaleMode) }
    private func upscaleAllowed(_ mode: JellyUpscale) -> Bool {
        mode.applies(frameRate: frameRate) && !(mode == .auto && JellyPower.shared.constrained)
    }
    /// The phone got hot or went into Low Power Mode (or back): smooth motion follows by itself
    /// (activeSmooth); upscaling on Auto is turned off for the rest of this video (not back on as it
    /// cools, which would reload the video again and again).
    private func easeOff(_ constrained: Bool) {
        let reason = JellyPower.shared.reason
        if constrained, usesMPV, smoothRate > 0 || superResolution != "off" {
            show((smoothRate > 0 && superResolution != "off" ? "Smooth motion and Super Resolution" : smoothRate > 0 ? "Smooth motion" : "Super Resolution")
                 + " paused " + reason, for: 3)
        }
        guard constrained, !usesMPV, upscaleMode == .auto, let upscale, upscale.disabledReason == nil,
              let engine, state != .idle, state != .loading else { return }
        show("Upscaling paused " + reason, for: 3)
        Task { _ = try? await engine.reloadAtCurrentPosition { $0.upscalesLowResolutionVideo = false } }
    }
    private func setUpscale(_ mode: JellyUpscale) {
        guard mode != upscaleMode else { return }
        let before = upscaleAllowed(upscaleMode), after = upscaleAllowed(mode)
        upscaleMode = mode
        show(mode == .auto && !after ? "Upscaling: Auto (not for this video now)" : "Upscaling: " + mode.title)
        // Only a change that turns it on or off for this video reloads it.
        guard before != after, let engine, state != .idle, state != .loading else { return }
        Task {
            _ = try? await engine.reloadAtCurrentPosition { options in
                options.upscalesLowResolutionVideo = after
                options.upscaleScaler = .automatic
            }
        }
    }
    /// Dialogue boost, night mode and volume boost, as the engine's audio shaping: the dialogue lift
    /// in dB; night mode's compressor (whispers up, explosions down); a boost as a plain gain into the
    /// engine's limiter (+100% is twice as loud, about +6 dB), on top of night mode's when both are on.
    static func shaping(dialogue: Int, night: Bool, boost: Int) -> AudioShaping {
        let boostDB = boost > 0 ? 20 * log10(1 + Double(boost) / 100) : 0
        var compressor: AudioShaping.Compressor?
        if night {
            var nightly = AudioShaping.Compressor.night
            nightly.makeupGainDB = min(24, nightly.makeupGainDB + boostDB)
            compressor = nightly
        } else if boostDB > 0 {
            compressor = AudioShaping.Compressor(thresholdDB: 0, ratio: 1, makeupGainDB: boostDB)
        }
        return AudioShaping(dialogueGainDB: Double(dialogue), compressor: compressor)
    }
    /// A sound setting changed mid-video: the engine rebuilds the audio where it is.
    private func applySound(_ note: String) {
        show(note)
        guard let engine, state != .idle, state != .loading else { return }
        engine.setAudioShaping(Self.shaping(dialogue: dialogueBoost, night: nightMode, boost: volumeBoost))
    }
    /// The video stream's frame rate (0 when the server doesn't say).
    static func frameRate(_ info: JellyfinClient.PlayerInfo?, source: String?) -> Double {
        let sources = info?.MediaSources ?? []
        let video = (sources.first { $0.Id == source } ?? sources.first)?.MediaStreams?.first { $0.kind == "Video" }
        return video?.RealFrameRate ?? 0
    }
    /// " · ends 11:42 PM", at the speed it plays.
    private var endsText: String {
        guard duration > 0 else { return "" }
        let left = max(0, duration - (scrub ?? time)) / Double(max(0.1, speed))
        return " · ends " + Date.now.addingTimeInterval(left).diaryTime()
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
    private func cycleFill() {
        let all = pictureChoices
        setFill(all[(all.firstIndex(of: fill).map { $0 + 1 } ?? 0) % all.count])
    }
    private func setFill(_ next: JellyFill) {
        // For this video, and kept for its show when Preferences says so. Never your default: that's
        // Preferences → Default aspect ratio (a pinch used to rewrite it), so the next video starts there.
        if JellyPreferences.fillPerShow, let show = current.item.SeriesId {
            UserDefaults.standard.set(next.rawValue, forKey: JellyPreferences.fillKey(show: show))
        }
        showFill = next
        engine?.videoGravity = next == .fill ? .resizeAspectFill : .resizeAspect
        mpv.setFill(next)
        show(next.rawValue, for: 1.2)
        scheduleHide()
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 28).padding(.bottom, showsControls ? 160 : 40)
    }

    // MARK: Panels

    @ViewBuilder private func panelView(_ panel: Panel) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea().onTapGesture { withAnimation { self.panel = nil } }
            VStack(spacing: 16) {
                switch panel {
                case .episodes: EmptyView()
                case .chapters: chaptersContent
                case .subtitleSearch: subtitleSearchContent
                case .advanced: EmptyView()
                }
                // Chapters close by their title.
                if panel != .chapters {
                    Button { withAnimation { self.panel = nil } } label: {
                        Text("Close").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 22).frame(height: 38).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 40).padding(.vertical, 20)
        }
    }

    /// Subtitles from the server's providers (OpenSubtitles), in a language; a tap saves one on the
    /// server and turns it on.
    private var subtitleSearchContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Download subtitles").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Spacer(minLength: 12)
                JellySubtitleLanguageMenu(selected: subtitleLanguage) { subtitleLanguage = $0 }.equatable()
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
    /// mpv's Super Resolution choices (More menu).
    static let superResolutions: [(String, String)] = [("Off", "off"), ("FSR", "fsr"), ("Anime4K", "anime")]
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
                if usesMPV {
                    mpv.addSubtitle(fresh.track.url, name: fresh.track.name, language: fresh.track.language)
                    if let language = fresh.track.language { remember("subtitleLanguage", language) }
                } else if let added = engine?.addExternalSubtitleTrack(fresh.track) {
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

    /// −0.1 s, the delay (a tap puts it back to 0), +0.1 s.
    private func delayControl(_ title: String, value: Double, step: Double = 0.1, set: @escaping (Double) -> Void) -> some View {
        // Kept to the step's own precision (0.05 s steps to hundredths).
        let places = step < 0.1 ? 100.0 : 10.0
        let format = step < 0.1 ? "%+.2fs" : "%+.1fs"
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            delayStep("minus", label: title + " earlier") { set(max(-15, ((value - step) * places).rounded() / places)) }
            Button { set(0) } label: {
                Text(value == 0 ? "0.0s" : String(format: format, value)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white).frame(minWidth: 58, minHeight: 30)
            }.buttonStyle(.plain)
            delayStep("plus", label: title + " later") { set(min(15, ((value + step) * places).rounded() / places)) }
        }
    }
    /// The subtitle delay's step and memory (Settings → Subtitles → Timing).
    private static var delayStep: Double {
        let step = UserDefaults.standard.double(forKey: JellySubtitlePrefs.delayStepKey)
        return step > 0 ? step : 0.1
    }
    private static var remembersDelay: Bool {
        UserDefaults.standard.object(forKey: JellySubtitlePrefs.rememberDelayKey) as? Bool ?? true
    }
    private static func delayKey(_ show: String) -> String { "jellyspace.subtitleDelay." + show }
    /// Sets the subtitle delay, kept for this show when Settings says to.
    private func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        engineSubtitleDelay(seconds)
        if Self.remembersDelay, let show = current.item.SeriesId { UserDefaults.standard.set(seconds, forKey: Self.delayKey(show)) }
    }
    /// The subtitles' size, here as in Settings (and kept there): a slider from half to double.
    private var subtitleSizeControl: some View {
        let size = Binding<Double>(get: { subtitleLook.size }, set: { value in
            subtitleLook.size = value
            UserDefaults.standard.set(value, forKey: JellyPrefs.subtitleSizeKey)
            if usesMPV { mpv.setSubtitleLook(subtitleLook) }
        })
        return HStack(spacing: 10) {
            Text("Subtitle size").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Slider(value: size, in: 0.5...2, step: 0.05).tint(.white)
                .accessibilityLabel("Subtitle size").accessibilityValue("\(Int((subtitleLook.size * 100).rounded())) percent")
            Text("\(Int((subtitleLook.size * 100).rounded()))%").font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white).frame(minWidth: 44, alignment: .trailing)
        }
    }
    /// How high the subtitles sit, here as in Settings (and kept there): from the bottom up to a
    /// quarter of the screen.
    private var subtitlePositionControl: some View {
        let raise = Binding<Double>(get: { subtitleLook.raise }, set: { value in
            subtitleLook.raise = value
            UserDefaults.standard.set(value, forKey: JellyPrefs.subtitleRaiseKey)
            if usesMPV { mpv.setSubtitleLook(subtitleLook) }
        })
        return HStack(spacing: 10) {
            Text("Subtitle position").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Slider(value: raise, in: 0...0.25, step: 0.01).tint(.white)
                .accessibilityLabel("Subtitle position").accessibilityValue("\(Int((subtitleLook.raise * 100).rounded())) percent up")
            Text("\(Int((subtitleLook.raise * 100).rounded()))%").font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white).frame(minWidth: 44, alignment: .trailing)
        }.accessibilityIdentifier("jellyspace-subtitle-position")
    }
    /// Translate: Off, or the language the subtitles are translated into as they play, on the phone.
    private var translateControl: some View {
        HStack(spacing: 10) {
            Text("Translate").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 8)
            // Its own view, drawn again only when the language or the list changes (see JellyTranslateMenu).
            JellyTranslateMenu(target: translator.target, targetName: translator.targetName, choices: translator.choices) { [translator] code in
                translator.setTarget(code)
            }
            .equatable()
        }
        .task { await translator.loadChoices() }
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
            HStack {
                Text("Chapters").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Spacer(minLength: 12)
                Button { closePanel() } label: {
                    Text("Close").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 34).background(.white.opacity(0.15), in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Close chapters")
            }
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                            let start = Double(chapter.StartPositionTicks) / 10_000_000
                            let here = index == currentChapter
                            Button { touched(); Task { await seek(start) }; closePanel() } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ZStack {
                                        Rectangle().fill(.white.opacity(0.1))
                                        JellyImage(url: chapter.ImageTag.flatMap { JellyfinClient.imageURL(base: current.client.base, item: current.id, type: "Chapter/\(index)", tag: $0, width: 400) })
                                    }
                                    .frame(width: 176, height: 99).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(here ? Self.red : .clear, lineWidth: 2.5))
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
    /// Episodes: opens on the season playing, scrolled to this episode; the show's seasons load behind.
    private func openEpisodes() {
        panelSeasonID = current.item.SeasonId
        panelEpisodes = season
        withAnimation { panel = .episodes }
        // The season playing hadn't loaded (or has no id): fetched here.
        if season.isEmpty, let seasonID = current.item.SeasonId {
            let client = current.client, user = userID
            panelLoading = true
            Task {
                let found = ((try? await client.children(of: seasonID, user: user)) ?? []).filter { $0.kind == "Episode" }
                if panelSeasonID == seasonID { panelEpisodes = found }
                panelLoading = false
            }
        }
        guard panelSeasons.isEmpty, let series = current.item.SeriesId else { return }
        let client = current.client, user = userID
        Task {
            // Specials (season 0) last, as on the show's page.
            panelSeasons = ((try? await client.seasons(of: series, user: user)) ?? []).sorted {
                ($0.IndexNumber.map { $0 == 0 ? Int.max : $0 } ?? Int.max - 1) < ($1.IndexNumber.map { $0 == 0 ? Int.max : $0 } ?? Int.max - 1)
            }
        }
    }
    private func pickPanelSeason(_ id: String) {
        guard id != panelSeasonID, let series = current.item.SeriesId else { return }
        panelSeasonID = id
        panelEpisodes = []
        panelLoading = true
        let client = current.client, user = userID
        Task {
            let found = (try? await client.episodes(of: series, season: id, user: user)) ?? []
            // A season picked meanwhile wins.
            guard panelSeasonID == id else { return }
            panelEpisodes = found
            panelLoading = false
        }
    }
    private func closePanel() {
        withAnimation { panel = nil }
        scheduleHide()
    }
    /// The Episodes panel, as Netflix has it: the season (a menu when there are more) and how many are
    /// left, then the episodes as cards you scroll sideways, the playing one outlined.
    private var episodesPanel: some View {
        let client = current.client
        let shown = panelEpisodes
        let left = shown.filter { $0.UserData?.Played != true }.count
        let compact = verticalSizeClass == .compact
        let side: CGFloat = compact ? 28 : 16
        let seasonName = panelSeasons.first { $0.Id == panelSeasonID }?.Name
            ?? current.item.ParentIndexNumber.map { "Season \($0)" } ?? "Episodes"
        return ZStack(alignment: .top) {
            Color.black.opacity(0.9).ignoresSafeArea().onTapGesture { closePanel() }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if panelSeasons.count > 1 {
                        JellySeasonMenu(seasons: panelSeasons.map { JellySeasonChoice(id: $0.Id, name: $0.Name ?? "Season") },
                                        selected: panelSeasonID ?? "", title: seasonName) { pickPanelSeason($0) }
                            .equatable()
                    } else {
                        Text(seasonName).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    }
                    if !shown.isEmpty {
                        Text(left == 0 ? "All watched" : left == shown.count ? "\(shown.count) episodes" : "\(shown.count) episodes · \(left) left")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { closePanel() } label: {
                        Image(systemName: "xmark").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Close episodes")
                }
                .padding(.horizontal, side)
                if shown.isEmpty {
                    Group {
                        if panelLoading { ProgressView().tint(.white) }
                        else { Text("No episodes here.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)) }
                    }.frame(maxWidth: .infinity).frame(height: 160)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shown, id: \.Id) { episodeCard($0, client: client, width: compact ? 220 : 200).id($0.Id) }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .contentMargins(.horizontal, side, for: .scrollContent)
                        // Room for the playing card's outline, which sits just outside the card (the
                        // scroll area clips at its edges, which cut the outline's top off).
                        .contentMargins(.vertical, 4, for: .scrollContent)
                        .onAppear { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
            }
            .padding(.top, 12)
        }
        .accessibilityIdentifier("jellyspace-episodes-panel")
    }
    /// One episode: its still (a play sign on it, a tick once watched, the red line as far as you've
    /// watched), "3. Name", its length or what's left, and its story in three lines.
    private func episodeCard(_ episode: JellyfinClient.Item, client: JellyfinClient, width: CGFloat) -> some View {
        let playingThis = episode.Id == current.id
        let watched = episode.UserData?.Played == true
        let minutes = episode.RunTimeTicks.map { Int($0 / 600_000_000) } ?? 0
        let percent = episode.UserData?.PlayedPercentage ?? 0
        let done = playingThis && duration > 0 ? time / duration : watched ? 1 : percent / 100
        var meta: [String] = minutes > 0 ? [DiaryDate.duration(minutes)] : []
        if playingThis, duration > 0 {
            meta.append(DiaryDate.duration(max(1, Int((duration - time) / 60))) + " left")
        } else if !watched, percent > 0, minutes > 0 {
            meta.append(DiaryDate.duration(max(1, Int(Double(minutes) * (1 - percent / 100)))) + " left")
        }
        let name = [episode.IndexNumber.map { "\($0)." }, episode.Name].compactMap { $0 }.joined(separator: " ")
        return Button {
            if playingThis { closePanel() } else { panel = nil; play(episode) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Color.white.opacity(0.08).frame(width: width, height: width * 9 / 16)
                    .overlay {
                        JellyImage(url: JellyfinClient.posterURL(base: client.base, item: episode.Id, tag: episode.ImageTags?["Primary"])
                                   ?? JellySpace.poster(episode, base: client.base))
                    }
                    .overlay {
                        if !watched || playingThis {
                            Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 38, height: 38).background(.black.opacity(0.5), in: Circle())
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if playingThis {
                            Text("Playing").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).frame(height: 18).background(Self.red, in: RoundedRectangle(cornerRadius: 3)).padding(6)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if watched, !playingThis {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(.black.opacity(0.6), in: Circle()).padding(6)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if done > 0 { Rectangle().fill(Self.red).frame(width: width * min(1, done), height: 3) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if playingThis { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white, lineWidth: 2).padding(-4) }
                    }
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1).padding(.top, 8)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                if let overview = episode.Overview.map(JellySpace.plainText), !overview.isEmpty {
                    Text(overview).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(3).multilineTextAlignment(.leading)
                }
            }
            .frame(width: width, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((playingThis ? "Playing: " : "Play ") + name)
        .accessibilityIdentifier("jellyspace-panel-episode-" + episode.Id)
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
        if audio, track.isVisualImpaired { text += " (Audio description)" }
        return text
    }
    private static func channels(_ count: Int) -> String {
        switch count { case 1: "Mono"; case 2: "Stereo"; case 6: "5.1"; case 8: "7.1"; default: "\(count)ch" }
    }
    static func speedName(_ rate: Float) -> String {
        rate == 1 ? "1x" : String(format: rate == rate.rounded() ? "%.0fx" : "%gx", rate)
    }

    /// Back or on: the round arrow with the seconds in it.
    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(systemName: symbol).font(.system(size: 38, weight: .regular)).foregroundStyle(.white)
                .frame(width: 64, height: 64).contentShape(Rectangle()).shadow(color: .black.opacity(0.35), radius: 8)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    /// Whether there's a video to move in. Not before it has opened: its length isn't known then, and a
    /// double tap as it loaded went to 0, so the place you were at was lost.
    private var canSkip: Bool { duration > 0 && openedID == current.id && heavy.loading == 0 && failure == nil }
    private func jump(_ seconds: Double) {
        touched()
        guard canSkip else { return }
        // From where the last one is going: quick ones add up, though the clock moves only as it lands.
        let target = min(max(0, (heavy.seekTarget ?? exactTime) + seconds), duration)
        Task { await seek(target) }
        scheduleHide()
    }
    private func seek(_ seconds: Double) async {
        guard failure == nil else { return }
        let back = duration <= 0 || seconds < duration - 5
        if countdown != nil, back { stopCountdown() }
        heavy.seeks += 1
        let mine = heavy.seeks
        heavy.seekTarget = seconds
        if usesMPV {
            mpv.seek(to: seconds)
            // mpv stays paused after its end: moved back from there, it plays on.
            if state == .ended, back { mpv.play() }
            updateSystem(position: seconds)
            // Its clock is there a moment later.
            Task { try? await Task.sleep(for: .milliseconds(400)); if heavy.seeks == mine { heavy.seekTarget = nil } }
            return
        }
        defer { if heavy.seeks == mine { heavy.seekTarget = nil } }
        guard let engine else { return }
        // AetherEngine's end is final (it takes no seek): moved back from there, the video opens again at
        // that place.
        if state == .ended {
            if back { reopen(at: seconds) }
            return
        }
        // Nor to the very end, where it would rest paused with nothing after it, and Play would start over:
        // the last second plays, and the end comes as it always does.
        _ = await engine.seek(to: Self.landing(seconds, of: duration))
    }
    /// Where a move lands on AetherEngine: never in the last second.
    static func landing(_ seconds: Double, of duration: Double) -> Double {
        duration > 2 ? min(seconds, duration - 1) : seconds
    }
    /// The video opened again in this player, from here (nil: as it opens by itself): after its end or a
    /// failure. What was found for it, and the audio and subtitles that were on, stay.
    private func reopen(at seconds: Double?) {
        handOver()
        switchAt = seconds.map { max(0, $0) }
        if usesMPV { mpv.stop() }
        startRun += 1
    }
    /// From the beginning after the end: another viewing.
    private func replay() {
        skipped = []
        if countdown != nil { stopCountdown() }
        if usesMPV {
            mpv.seek(to: 0)
            mpv.play()
            updateSystem(position: 0)
            // A last tick from the end may still come, and would count this one as watched at once.
            let id = current.id
            Task { try? await Task.sleep(for: .seconds(1)); if current.id == id { finished = false } }
        } else {
            finished = false
            reopen(at: 0)
        }
    }
    /// Up Next: the next episode's file details and where you stopped, fetched now.
    private func prefetchNext() {
        guard let next = nextEpisode, prefetch?.id != next.Id else { return }
        let client = current.client, user = userID, id = next.Id, resume = resumeOn
        Task {
            async let info = Self.fileInfo(client, id: id, user: user, wanted: true)
            async let place = Self.savedSeconds(client, id: id, user: user, wanted: resume)
            let fetched = JellyPrefetch(id: id, info: await info, seconds: await place)
            prefetch = fetched
        }
    }
    nonisolated private static func fileInfo(_ client: JellyfinClient, id: String, user: String?, wanted: Bool) async -> JellyfinClient.PlayerInfo? {
        guard wanted else { return nil }
        return try? await client.playerInfo(id, user: user)
    }
    nonisolated private static func savedSeconds(_ client: JellyfinClient, id: String, user: String?, wanted: Bool) async -> Double? {
        guard wanted, let user, let data = try? await client.userData(id, user: user), let ticks = data.PlaybackPositionTicks, ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
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
    /// Its own clock (the player's redraws only once a second).
    let clock: JellyPlayClock
    private var time: Double { clock.time }
    private var buffered: Double { clock.buffered }
    let duration: Double
    let marks: [Double]
    let stretches: [JellyStretch]
    let tint: Color
    var knob: Color = .white
    @Binding var scrub: Double?
    /// iOS took the touch before it was let go (a swipe home from the bar).
    var released: () -> Void = {}
    /// A finger is on the bar. SwiftUI puts this back however the drag goes away; a cancelled one has no
    /// end of its own, and the bar stayed where the finger had been, with the controls up for good.
    @GestureState private var touching = false
    @State private var committed = false
    let commit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width), total = max(duration, 1)
            let shown = scrub ?? time, dragging = scrub != nil
            let at = width * min(1, max(0, shown / total))
            // Until the video's length is known (while it loads) only the empty track: the stretches,
            // marks and buffer are in seconds and, measured against nothing, ran far past the screen.
            let known = duration > 0
            let part = { (seconds: Double) in min(1, max(0, seconds / total)) }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                if known {
                    Rectangle().fill(.white.opacity(0.38)).frame(width: width * part(buffered))
                    ForEach(stretches.indices, id: \.self) { index in
                        let stretch = stretches[index]
                        let from = part(stretch.range.lowerBound), to = max(from, part(stretch.range.upperBound))
                        Rectangle().fill(stretch.color.opacity(0.85))
                            .frame(width: max(2, width * (to - from)))
                            .offset(x: width * from)
                    }
                }
                Rectangle().fill(tint).frame(width: at)
                if known {
                    ForEach(marks.indices, id: \.self) { index in
                        Rectangle().fill(.black.opacity(0.6)).frame(width: 2).offset(x: width * part(marks[index]) - 1)
                    }
                }
            }
            .frame(width: width, height: dragging ? 8 : 4, alignment: .leading).clipShape(Capsule())
            .overlay(alignment: .leading) {
                Circle().fill(knob).frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12).offset(x: at - (dragging ? 9 : 6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        scrub = min(max(0, drag.location.x / width), 1) * duration
                    }
                    .onEnded { drag in
                        guard duration > 0 else { return }
                        let target = min(max(0, drag.location.x / width), 1) * duration
                        committed = true
                        scrub = target
                        commit(target)
                    }
            )
            .onChange(of: touching) { _, touching in
                if touching { committed = false; return }
                guard !committed else { return }
                scrub = nil
                released()
            }
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
    case cancelled
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
            case .ended: layer.pan(.ended)
            case .cancelled, .failed: layer.pan(.cancelled)
            default: break
            }
        }
        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .ended { layer.pinch(gesture.scale) }
        }
    }
}

/// A double tap's sign: three small solid arrows, no backing, lighting up one after another in the
/// direction of the jump (80 ms apart), then fading out in the same order, all within 0.9 s.
private struct JellySeekArrows: View {
    let forward: Bool
    /// The tap it belongs to: a new one starts the run again.
    let tap: Int
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { slot in
                    // The first to light is the one the jump starts from.
                    let order = forward ? slot : 2 - slot
                    Image(systemName: forward ? "arrowtriangle.forward.fill" : "arrowtriangle.backward.fill")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .opacity(reduceMotion ? (elapsed < 0.7 ? 1 : 0) : Self.opacity(elapsed, order: order))
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 4)
        }
        .onChange(of: tap) { _, _ in start = .now }
        .accessibilityHidden(true)
    }
    /// In over 60 ms, 80 ms after the one before; out over 180 ms, from 0.42 s, in the same order.
    static func opacity(_ elapsed: Double, order: Int) -> Double {
        let appear = Double(order) * 0.08, fade = 0.42 + Double(order) * 0.1
        if elapsed < appear { return 0 }
        if elapsed < appear + 0.06 { return (elapsed - appear) / 0.06 }
        if elapsed < fade { return 1 }
        return max(0, 1 - (elapsed - fade) / 0.18)
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
            } else {
                // Until monitoring is on, iOS reports the level as unknown (-1). Something has to be
                // here for onAppear to run and turn it on: with nothing, it never appeared, never
                // turned monitoring on, and the battery never showed.
                Color.clear.frame(width: 1, height: 1)
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
/// AirPlay and Cast at the top of the player, each unless turned off (Settings → JellySpace → Playback).
/// A view of their own, so the settings don't add to the player view's size.
private struct JellyTVButtons: View {
    /// AirPlay can take this picture now.
    let airPlay: Bool
    @AppStorage(JellyPrefs.castButtonKey) private var castButton = true
    @AppStorage(JellyPrefs.airPlayButtonKey) private var airPlayButton = true

    var body: some View {
        if airPlay, airPlayButton {
            JellyAirPlayButton().frame(width: 44, height: 44).accessibilityIdentifier("jellyspace-airplay")
        }
        if castButton {
            JellyCastButton().frame(width: 44, height: 44).accessibilityIdentifier("jellyspace-cast")
        }
    }
}

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

/// The clock the subtitles follow (the engine's picture time), apart from the player's so its ticks
/// redraw only the subtitles.
@MainActor @Observable final class JellySubtitleClock {
    var time: Double = 0
}

/// One shared copy of the player, for its menus' actions (see JellyPlayerView.menuActions).
@MainActor fileprivate final class JellyPlayerRef {
    let view: JellyPlayerView
    init(_ view: JellyPlayerView) { self.view = view }
}

/// The player's larger values (see JellyPlayerView.heavy).
@MainActor @Observable fileprivate final class JellyPlayerStore {
    var current: JellyPlayback
    var subtitleLook = JellySubtitleLook.current
    var ratingInfo: JellyRatingInfo?
    var stillWatching: JellyfinClient.Item?
    var following: JellyfinClient.Item?
    var loadedInfo: (id: String, info: JellyfinClient.PlayerInfo?)?
    var carriedTracks: (audio: String?, subtitle: String?, subtitleName: String)?
    var prefetch: JellyPrefetch?
    var trickplay: (info: JellyfinClient.PlayerInfo.TrickplayInfo, source: String)?
    var sheet: (index: Int, image: UIImage)?
    var openMenus: JellyMenuState?
    /// This video moved to the other engine by itself, because its own couldn't play it (the next one
    /// isn't, for that).
    @ObservationIgnored var movedItself = false
    /// The video that last happened to: once each.
    @ObservationIgnored var movedFor: String?
    /// The load AetherEngine is on (0: none): its failure is the load's to say, not the player's.
    @ObservationIgnored var loading = 0
    @ObservationIgnored private var loads = 0
    func beganLoad() -> Int { loads += 1; loading = loads; return loads }
    func endedLoad(_ load: Int) { if loading == load { loading = 0 } }
    /// The video whose skip stretches, chapters, thumbnails and next episode have all been read.
    @ObservationIgnored var detailsFor: String?
    /// Where a seek on its way is going, and how many there have been.
    @ObservationIgnored var seekTarget: Double?
    @ObservationIgnored var seeks = 0
    /// AetherEngine is opening a video again that it let go of in the background.
    @ObservationIgnored var restoring = false
    /// Your own brightness is back while you're out of the app.
    @ObservationIgnored var dimmedAway = false
    /// The phone's volume as last heard of.
    @ObservationIgnored var volumeSeen: Float?
    /// mpv's lock-screen card and buttons, calls, headphones and the screen kept on.
    let system = JellyMPVSystem()
    init(current: JellyPlayback) { self.current = current }
}

/// Time asked of iOS to finish something with the app away, given back when it's done or iOS wants it.
@MainActor private final class JellyBackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.end()
            }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The next episode's details, fetched ahead during Up Next.
private struct JellyPrefetch {
    let id: String
    let info: JellyfinClient.PlayerInfo?
    let seconds: Double?
}

/// The progress bar's clock (see the player's tick).
@MainActor @Observable final class JellyPlayClock {
    var time: Double = 0
    /// How far the video has loaded, in seconds.
    var buffered: Double = 0
}

/// Translate's language menu, apart from the player: it's drawn again only when the language or the
/// list changes. iOS greys out an open menu's items and drops their taps when the button behind it
/// is rebuilt, and the player redraws as the video plays (Streamyfin keeps its menus apart the same
/// way).
private struct JellyTranslateMenu: View, Equatable {
    let target: String
    let targetName: String
    let choices: [JellyTranslator.Choice]
    let choose: @MainActor (String) -> Void

    nonisolated static func == (lhs: JellyTranslateMenu, rhs: JellyTranslateMenu) -> Bool {
        lhs.target == rhs.target && lhs.targetName == rhs.targetName && lhs.choices == rhs.choices
    }

    var body: some View {
        Menu {
            Picker("Translate subtitles", selection: Binding(get: { target }, set: { choose($0) })) {
                Text("Off").tag("")
                ForEach(choices) { choice in Text(choice.name).tag(choice.id) }
            }
        } label: {
            Label(targetName, systemImage: "translate").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 36).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
        }
        .accessibilityLabel("Translate subtitles").accessibilityValue(targetName)
        .accessibilityIdentifier("jellyspace-translate-subtitles")
    }
}

/// The time left (or the length) beside the bar, on the bar's clock.
private struct JellyTimeLeft: View {
    let clock: JellyPlayClock
    let duration: Double
    let scrub: Double?
    let total: Bool

    var body: some View {
        Text(total ? JellyPlayerView.clock(duration) : JellyPlayerView.clock(max(0, duration - (scrub ?? clock.time))))
            .font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(.white)
            .frame(minHeight: 30).contentShape(Rectangle())
    }
}

/// The subtitles on screen now: follows the subtitle clock and hands the lines showing to the
/// canvas, which is drawn again only when they change (not ten times a second).
private struct JellySubtitles: View {
    let cues: [SubtitleCue]
    let clock: JellySubtitleClock
    let delay: Double
    var look = JellySubtitleLook()
    var insets = EdgeInsets()
    var fill = JellyFill.fit
    var videoPixels = CGSize.zero
    var pixelAspect: CGFloat = 1
    var originalSize = CGSize.zero
    var sheet: JellyASSSheet? = nil
    var lift: CGFloat = 0
    /// Translated lines by their original text, while translating (they show as plain text).
    var translated: [String: String]? = nil

    var body: some View {
        let time = clock.time - delay
        let now = cues.filter { $0.startTime <= time && time < $0.endTime }
        var swap: [String: String] = [:]
        if let translated {
            for cue in now {
                if let text = cue.text.map(JellyPlainLines.plain), let done = translated[text] { swap[text] = done }
            }
        }
        return JellySubtitleCanvas(now: now, look: look, insets: insets, fill: fill, videoPixels: videoPixels,
                                   pixelAspect: pixelAspect, originalSize: originalSize, sheet: translated == nil ? sheet : nil, lift: lift, replace: swap)
            .equatable()
    }
}

/// The subtitles showing: text cues at the bottom (styled ones where their script puts them),
/// picture cues (PGS, DVD) where the file places them on its canvas.
private struct JellySubtitleCanvas: View, Equatable {
    let now: [SubtitleCue]
    /// The look from Settings → JellySpace → Subtitles (size, font, colours, edge, box, height).
    var look = JellySubtitleLook()
    var insets = EdgeInsets()
    var fill = JellyFill.fit
    /// The video's coded size in pixels (what a picture cue's canvas maps onto).
    var videoPixels = CGSize.zero
    /// How much wider than its pixels the video is shown (a DVD's aren't square).
    var pixelAspect: CGFloat = 1
    var originalSize = CGSize.zero
    /// Styled (ASS) subtitles' sheet; nil draws them as plain text.
    var sheet: JellyASSSheet? = nil
    /// The room the controls take while they show.
    var lift: CGFloat = 0
    /// Lines shown translated: the translation by the original text.
    var replace: [String: String] = [:]

    nonisolated static func == (lhs: JellySubtitleCanvas, rhs: JellySubtitleCanvas) -> Bool {
        lhs.now.map(\.id) == rhs.now.map(\.id) && lhs.look == rhs.look && lhs.insets == rhs.insets && lhs.fill == rhs.fill
            && lhs.videoPixels == rhs.videoPixels && lhs.pixelAspect == rhs.pixelAspect && lhs.originalSize == rhs.originalSize && lhs.lift == rhs.lift && lhs.sheet == rhs.sheet
            && lhs.replace == rhs.replace
    }

    var body: some View {
        GeometryReader { proxy in
            let up = proxy.size.height * look.raise + (look.lift ? lift : 0)
            let safe = CGRect(x: insets.leading + 8, y: insets.top + 8, width: proxy.size.width - insets.leading - insets.trailing - 16,
                              height: max(0, proxy.size.height - insets.top - insets.bottom - 16 - up))
            ZStack {
                ForEach(now) { cue in
                    if case .image(let picture) = cue.body {
                        let frame = Self.keep(Self.place(picture, in: proxy.size, fill: fill, videoPixels: videoPixels, originalSize: originalSize), inside: safe)
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
                        JellyASSLayer(events: events, sheet: sheet, size: proxy.size, safe: safe, fill: fill, originalSize: originalSize,
                                      video: CGSize(width: videoPixels.width * pixelAspect, height: videoPixels.height),
                                      userScale: look.styledSize ? look.size : 1)
                    }
                }
                let points = max(12, JellySubtitleLook.points(screenHeight: proxy.size.height, size: look.size))
                let blocks = sheet != nil ? [] : JellyPlainLines.blocks(JellyPlainLines.lines(now, replace: replace, look: look, points: points))
                let low: CGFloat = max(proxy.size.height * 0.07, insets.bottom + 12) + up
                // At the top, clear of the title while the controls show.
                let high: CGFloat = max(proxy.size.height * 0.07, insets.top + 12) + (look.lift && lift > 0 ? 44 : 0)
                ForEach(blocks, id: \.alignment) { block in
                    JellyPlainSubtitle(text: block.text, look: look, points: points, styled: block.styled)
                        .padding(.leading, max(40, insets.leading + 16)).padding(.trailing, max(40, insets.trailing + 16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: JellyASSLayer.anchor(block.alignment))
                        .padding(.bottom, block.alignment <= 3 ? low : 0)
                        .padding(.top, block.alignment >= 7 ? high : 0)
                }
            }
        }
    }
    /// A picture cue's rectangle on screen. Its position is a fraction (0 to 1) of its canvas (the
    /// disc's, say 1920x1080); the canvas lies across the video's full width, centred up and down (a
    /// cropped rip's canvas is taller than the video), and the video is shown fitted, filled or at its
    /// own size. AetherEngine's own compositor maps it the same way.
    static func place(_ picture: SubtitleImage, in size: CGSize, fill: JellyFill, videoPixels: CGSize, originalSize: CGSize) -> CGRect {
        let canvas = picture.canvasSize.width > 0 && picture.canvasSize.height > 0 ? picture.canvasSize : videoPixels
        let video = videoPixels.width > 0 && videoPixels.height > 0 ? videoPixels : canvas
        guard video.width > 0, video.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        // The picture as it is shown.
        let shown: CGSize
        switch fill {
        case .fit, .fill:
            let scale = fill == .fit ? min(size.width / video.width, size.height / video.height) : max(size.width / video.width, size.height / video.height)
            shown = CGSize(width: video.width * scale, height: video.height * scale)
        case .original:
            shown = originalSize.width > 0 && originalSize.height > 0 ? originalSize
                : CGSize(width: video.width * min(size.width / video.width, size.height / video.height), height: video.height * min(size.width / video.width, size.height / video.height))
        }
        let frame = CGRect(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2, width: shown.width, height: shown.height)
        let scale = frame.width / canvas.width
        let spot = picture.position
        return CGRect(x: frame.minX + spot.minX * canvas.width * scale,
                      y: frame.midY + (spot.minY * canvas.height - canvas.height / 2) * scale,
                      width: spot.width * canvas.width * scale,
                      height: spot.height * canvas.height * scale)
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

    /// What the controller was built for (the software source or the native layer), so the same one
    /// isn't built again: the engine republishes on every change, a track or setting included.
    private var builtFor: ObjectIdentifier?

    func rebuildIfNeeded() { if controller == nil { rebuild() } }
    func rebuild() {
        guard let engine, AVPictureInPictureController.isPictureInPictureSupported() else { release(); return }
        let target: AnyObject? = engine.softwarePiPSource ?? engine.nativePlayerLayer
        if let target, controller != nil, builtFor == ObjectIdentifier(target) { return }
        // The old controller goes first (its delegate off, its window closed when it isn't this one's).
        release()
        if let software = engine.softwarePiPSource {
            controller = software.makePictureInPictureController()
        } else if let layer = engine.nativePlayerLayer {
            controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        }
        builtFor = controller == nil ? nil : target.map(ObjectIdentifier.init)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    private func release() {
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
        builtFor = nil
    }
    func start() { controller?.startPictureInPicture() }

    // In the window, iOS draws the subtitles (the engine's own track); back in the app, the player's
    // own again, so they're never drawn twice (as Sodalite switches them).
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            engine?.pictureInPictureActive = true
            engine?.setNativeSubtitleRendering(true)
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            engine?.pictureInPictureActive = false
            engine?.setNativeSubtitleRendering(false)
        }
    }
}

// MARK: The player's menus

/// One audio or subtitle track as a menu shows it.
private struct JellyTrackChoice: Equatable, Sendable {
    let id: Int
    let label: String
}

/// What the player's menus show. The menus are views of their own that redraw only when this
/// changes: built inside the player, which redraws many times a second while it plays, an open menu
/// was rebuilt under the finger (submenus folded shut, choices were missed).
private struct JellyMenuState: Equatable, Sendable {
    var subtitles: [JellyTrackChoice]
    var audio: [JellyTrackChoice]
    var subtitle: Int
    var audioTrack: Int
    var sleep: Int
    var speed: Double
    var upscale: JellyUpscale
    var episode: Bool
    var dialogue: Int
    var night: Bool
    var boost: Int
    var fill: JellyFill
    /// The Picture choices this player can show (mpv through AVFoundation: Fit and Fill).
    var pictures: [JellyFill]
    var rotationLocked: Bool
    var info: Bool
    /// Chapters in More (an episode's, whose bottom row is full).
    var chapters: Bool
    var decoder: JellyDecoder
    var mpv: Bool
    var smooth: Int
    var superResolution: String
}

/// What the menus' choices do (closures: they play no part in deciding a redraw).
private struct JellyMenuActions {
    let opened: () -> Void
    let closed: () -> Void
    let sleep: (Int) -> Void
    let speed: (Double) -> Void
    let upscale: (JellyUpscale) -> Void
    let subtitle: (Int) -> Void
    let audio: (Int) -> Void
    let download: () -> Void
    let chapters: () -> Void
    let advanced: () -> Void
    let dialogue: (Int) -> Void
    let night: (Bool) -> Void
    let boost: (Int) -> Void
    let fill: (JellyFill) -> Void
    let rotation: () -> Void
    let info: (Bool) -> Void
    let decoder: (JellyDecoder) -> Void
    let superResolution: (String) -> Void
    let smooth: (Int) -> Void
}

@MainActor private enum JellyMenuParts {
    /// A button in the bottom row: its symbol and, where there's room, its name.
    static func label(_ symbol: String, _ title: String, labelled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium))
            if labelled { Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(.white).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        .shadow(color: .black.opacity(0.45), radius: 6)
    }
    @ViewBuilder static func subtitleOptions(_ choices: [JellyTrackChoice]) -> some View {
        Text("Off").tag(-1)
        ForEach(choices, id: \.id) { Text($0.label).tag($0.id) }
    }
    static func audioOptions(_ choices: [JellyTrackChoice]) -> some View {
        ForEach(choices, id: \.id) { Text($0.label).tag($0.id) }
    }
}

/// More: the picture, rotation, the sleep timer, upscaling, the sound, and Advanced options. (Speed and
/// Audio & Subtitles have buttons of their own; the subtitles' look is in Settings → JellySpace.)
private struct JellyMoreMenu: View, Equatable {
    let state: JellyMenuState
    let actions: JellyMenuActions
    let labelled: Bool
    nonisolated static func == (lhs: JellyMoreMenu, rhs: JellyMoreMenu) -> Bool { lhs.state == rhs.state && lhs.labelled == rhs.labelled }

    var body: some View {
        Menu {
            Group {
                Picker(selection: Binding(get: { state.fill }, set: { actions.fill($0) })) {
                    ForEach(state.pictures, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                } label: { Label("Picture", systemImage: state.fill.symbol) }.pickerStyle(.menu)
                Button { actions.rotation() } label: {
                    Label(state.rotationLocked ? "Unlock rotation" : "Lock rotation",
                          systemImage: state.rotationLocked ? "lock.rotation" : "lock.rotation.open")
                }
                Section {
                    Picker(selection: Binding(get: { state.sleep }, set: { actions.sleep($0) })) {
                        Text("Off").tag(-1)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                        Text(state.episode ? "End of episode" : "End of film").tag(0)
                    } label: { Label("Sleep timer", systemImage: "moon.zzz") }.pickerStyle(.menu)
                    if state.mpv {
                        Picker(selection: Binding(get: { state.smooth }, set: { actions.smooth($0) })) {
                            Text("Off").tag(0)
                            Text("60 Hz").tag(60)
                            Text("120 Hz").tag(120)
                        } label: { Label("Smooth motion", systemImage: "wand.and.sparkles") }.pickerStyle(.menu)
                        Picker(selection: Binding(get: { state.superResolution }, set: { actions.superResolution($0) })) {
                            ForEach(JellyPlayerView.superResolutions, id: \.1) { Text($0.0).tag($0.1) }
                        } label: { Label("Super resolution", systemImage: "sparkles") }.pickerStyle(.menu)
                    } else {
                        Picker(selection: Binding(get: { state.upscale }, set: { actions.upscale($0) })) {
                            ForEach(JellyUpscale.allCases, id: \.self) { Text($0.title).tag($0) }
                        } label: { Label("Upscaling", systemImage: "sparkles") }.pickerStyle(.menu)
                    }
                    Picker(selection: Binding(get: { state.decoder }, set: { actions.decoder($0) })) {
                        ForEach(JellyDecoder.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: { Label("Decoder", systemImage: "cpu") }.pickerStyle(.menu)
                }
                if !state.mpv {
                Section {
                    Picker(selection: Binding(get: { state.dialogue }, set: { actions.dialogue($0) })) {
                        ForEach(JellySound.dialogue, id: \.1) { Text($0.0).tag($0.1) }
                    } label: { Label("Dialogue boost", systemImage: "person.wave.2") }.pickerStyle(.menu)
                    Toggle(isOn: Binding(get: { state.night }, set: { actions.night($0) })) { Label("Night mode", systemImage: "moon.stars") }
                    Picker(selection: Binding(get: { state.boost }, set: { actions.boost($0) })) {
                        ForEach(JellySound.boost, id: \.1) { Text($0.0).tag($0.1) }
                    } label: { Label("Volume boost", systemImage: "speaker.plus") }.pickerStyle(.menu)
                }
                if !state.mpv {
                    Toggle(isOn: Binding(get: { state.info }, set: { actions.info($0) })) { Label("Playback info", systemImage: "info.circle") }
                }
                }
                if state.chapters {
                    Button { actions.chapters() } label: { Label("Chapters", systemImage: "list.bullet") }
                }
                Button { actions.advanced() } label: { Label("Advanced options", systemImage: "slider.horizontal.3") }
            }
            .onAppear { actions.opened() }.onDisappear { actions.closed() }
        } label: {
            JellyMenuParts.label("ellipsis.circle", "More", labelled: labelled)
        }
        .menuOrder(.fixed).menuIndicator(.hidden)
        .accessibilityLabel("More").accessibilityIdentifier("jellyspace-settings")
    }
}

/// Speed (1x).
private struct JellySpeedMenu: View, Equatable {
    let state: JellyMenuState
    let actions: JellyMenuActions
    let labelled: Bool
    nonisolated static func == (lhs: JellySpeedMenu, rhs: JellySpeedMenu) -> Bool { lhs.state.speed == rhs.state.speed && lhs.labelled == rhs.labelled }

    var body: some View {
        let name = JellyPlayerView.speedName(Float(state.speed))
        Menu {
            Group {
                Picker(selection: Binding(get: { state.speed }, set: { actions.speed($0) })) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(JellyPlayerView.speedName(Float($0))).tag($0) }
                } label: { Text("Speed") }.pickerStyle(.inline)
            }
            .onAppear { actions.opened() }.onDisappear { actions.closed() }
        } label: {
            JellyMenuParts.label("gauge.with.dots.needle.67percent", "Speed (" + name + ")", labelled: labelled)
        }
        .menuOrder(.fixed).menuIndicator(.hidden)
        .accessibilityLabel("Speed, " + name).accessibilityIdentifier("jellyspace-speed")
    }
}

/// Audio & Subtitles: the tracks, and subtitles to download.
private struct JellyTracksMenu: View, Equatable {
    let state: JellyMenuState
    let actions: JellyMenuActions
    let labelled: Bool
    nonisolated static func == (lhs: JellyTracksMenu, rhs: JellyTracksMenu) -> Bool { lhs.state == rhs.state && lhs.labelled == rhs.labelled }

    var body: some View {
        Menu {
            Group {
                if !state.subtitles.isEmpty {
                    Picker(selection: Binding(get: { state.subtitle }, set: { actions.subtitle($0) })) {
                        JellyMenuParts.subtitleOptions(state.subtitles)
                    } label: { Text("Subtitles") }.pickerStyle(.inline)
                }
                if !state.audio.isEmpty {
                    Picker(selection: Binding(get: { state.audioTrack }, set: { actions.audio($0) })) {
                        JellyMenuParts.audioOptions(state.audio)
                    } label: { Text("Audio") }.pickerStyle(.inline)
                }
                if !state.subtitles.isEmpty {
                    Button { actions.advanced() } label: { Label("Subtitle size and timing", systemImage: "textformat.size") }
                }
                Button { actions.download() } label: { Label("Download subtitles", systemImage: "arrow.down.circle") }
            }
            .onAppear { actions.opened() }.onDisappear { actions.closed() }
        } label: {
            JellyMenuParts.label("captions.bubble", "Audio & Subtitles", labelled: labelled)
        }
        .menuOrder(.fixed).menuIndicator(.hidden)
        .accessibilityLabel("Audio and subtitles").accessibilityIdentifier("jellyspace-tracks")
    }
}

/// The Download subtitles panel's language: its own view, so the menu isn't rebuilt (and sent back
/// to its top) by every tick of the video while it's open.
private struct JellySubtitleLanguageMenu: View, Equatable {
    let selected: String
    let pick: (String) -> Void
    nonisolated static func == (lhs: JellySubtitleLanguageMenu, rhs: JellySubtitleLanguageMenu) -> Bool {
        lhs.selected == rhs.selected
    }

    var body: some View {
        let languages = JellyPlayerView.subtitleLanguages
        Menu {
            Picker("Language", selection: Binding(get: { selected }, set: { pick($0) })) {
                ForEach(languages, id: \.1) { Text($0.0).tag($0.1) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(languages.first { $0.1 == selected }?.0 ?? selected)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 32).background(.white.opacity(0.15), in: Capsule())
        }.accessibilityIdentifier("jellyspace-subtitle-language")
    }
}

/// One of the show's seasons in the Episodes panel's menu.
private struct JellySeasonChoice: Equatable, Sendable {
    let id: String
    let name: String
}

/// The Episodes panel's season: a menu of the show's seasons (its own view, so it isn't rebuilt under
/// the finger while the video plays).
private struct JellySeasonMenu: View, Equatable {
    let seasons: [JellySeasonChoice]
    let selected: String
    let title: String
    let pick: (String) -> Void
    nonisolated static func == (lhs: JellySeasonMenu, rhs: JellySeasonMenu) -> Bool {
        lhs.seasons == rhs.seasons && lhs.selected == rhs.selected && lhs.title == rhs.title
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { selected }, set: { pick($0) })) {
                ForEach(seasons, id: \.id) { Text($0.name).tag($0.id) }
            } label: { Text("Season") }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
            }
            .font(.system(size: 18, weight: .bold)).foregroundStyle(.white).frame(minHeight: 44).contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Season: " + title).accessibilityIdentifier("jellyspace-panel-season")
    }
}
