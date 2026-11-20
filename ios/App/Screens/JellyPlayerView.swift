import SwiftUI
import AVKit
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

    private enum Panel { case tracks, episodes }

    init(playback: JellyPlayback) {
        _current = State(initialValue: playback)
        _engine = State(initialValue: try? AetherEngine())
    }

    private var fill: JellyFill { JellyFill(rawValue: fillRaw) ?? .fit }
    private var nextEpisode: JellyfinClient.Item? {
        guard current.item.kind == "Episode", let number = current.item.IndexNumber else { return nil }
        return season.filter { ($0.IndexNumber ?? 0) > number }.min { ($0.IndexNumber ?? 0) < ($1.IndexNumber ?? 0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine {
                picture(engine)
            }
            JellySubtitles(cues: cues, time: time, scale: subtitleSize).ignoresSafeArea().allowsHitTesting(false)
            // Single tap: the controls; a double tap on the left or right half: 10 seconds back or on.
            HStack(spacing: 0) {
                tapZone(seconds: -10)
                tapZone(seconds: 10)
            }.ignoresSafeArea()
            if let skipFlash {
                Text(skipFlash < 0 ? "−10s" : "+10s").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .padding(18).background(.black.opacity(0.45), in: Circle())
                    .frame(maxWidth: .infinity, alignment: skipFlash < 0 ? .leading : .trailing).padding(.horizontal, 90)
                    .transition(.opacity).allowsHitTesting(false)
            }
            if showsControls || failure != nil { controls.transition(.opacity) }
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
        .onAppear { OrientationLock.set(.landscape, turnTo: .landscapeRight) }
        .onDisappear {
            savePlace()
            engine?.stop()
            OrientationLock.set(.portrait, turnTo: .portrait)
        }
        .task(id: current.id) { await start() }
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
            .onReceive(engine.$audioTracks) { audioTracks = $0 }
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

    private func tapZone(seconds: Double) -> some View {
        Color.clear.contentShape(Rectangle())
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
        finished = false; failure = nil; resumedAt = nil; countdown = nil; pickedSubtitle = false; time = 0
        let client = current.client
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
        engine.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
        do {
            if let startAt, startAt > 30 {
                try await engine.load(url: current.url, startPosition: startAt)
                resumedAt = startAt
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation { resumedAt = nil } }
            } else {
                try await engine.load(url: current.url)
            }
            engine.play()
            if speed != 1 { engine.setRate(speed) }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
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
        Task {
            while let left = countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard countdown != nil else { return }
                countdown = left - 1
            }
            if countdown == 0, let next = nextEpisode { play(next) }
        }
    }

    /// Where you are, to Jellyfin (not once it's finished: Jellyfin then starts it over next time).
    private func savePlace() {
        guard !finished, let user = userID, time > 5 else { return }
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

    /// The file's default (or forced) subtitle, turned on once when the tracks first arrive.
    private func pickDefaultSubtitle(_ tracks: [TrackInfo]) {
        guard !pickedSubtitle, !tracks.isEmpty else { return }
        pickedSubtitle = true
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
                HStack(spacing: 84) {
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
                Text("-" + Self.clock(max(0, duration - (scrub ?? time)))).frame(minWidth: 56, alignment: .trailing)
            }.font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white).padding(.horizontal, 28)
            HStack(spacing: 26) {
                if current.item.kind == "Episode", season.count > 1 {
                    action("rectangle.stack", "Episodes") { withAnimation { panel = .episodes } }
                }
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button { speed = Float(value); engine?.setRate(Float(value)) } label: {
                            Label(Self.speedName(Float(value)), systemImage: speed == Float(value) ? "checkmark" : "")
                        }
                    }
                } label: { actionFace("gauge.with.needle", "Speed (\(Self.speedName(speed)))") }
                    .accessibilityIdentifier("jellyspace-speed")
                if audioTracks.count > 1 || !subtitleTracks.isEmpty {
                    action("captions.bubble", "Audio & Subtitles") { withAnimation { panel = .tracks } }.accessibilityIdentifier("jellyspace-tracks")
                }
                action(fill.symbol, fill.rawValue) { cycleFill() }.accessibilityIdentifier("jellyspace-fill")
                if pip.available { action("pip.enter", "PiP") { pip.start() } }
                if let next = nextEpisode {
                    action("forward.end", "Next Episode") { play(next) }.accessibilityIdentifier("jellyspace-next")
                }
            }.padding(.top, 6).padding(.bottom, 14)
        }
        .background {
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
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

    private func action(_ symbol: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { actionFace(symbol, title) }.buttonStyle(.plain)
    }
    private func actionFace(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }.foregroundStyle(.white).frame(minHeight: 44).contentShape(Rectangle())
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
        HStack(alignment: .top, spacing: 40) {
            if audioTracks.count > 1 {
                trackColumn("Audio", rows: audioTracks.map { ($0.id, Self.label($0, audio: true)) }, chosen: activeAudio) { id in
                    if let id { engine?.selectAudioTrack(index: id) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if !subtitleTracks.isEmpty {
                    trackColumn("Subtitles", rows: [(-1, "Off")] + subtitleTracks.map { ($0.id, Self.label($0, audio: false)) },
                                chosen: activeSubtitle ?? -1) { id in
                        if let id, id >= 0 { engine?.selectSubtitleTrack(index: id) } else { engine?.clearSubtitle() }
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
            }.frame(maxHeight: 190)
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
    var body: some View {
        let now = cues.filter { $0.startTime <= time && time < $0.endTime }
        GeometryReader { proxy in
            ZStack {
                ForEach(now) { cue in
                    if case .image(let picture) = cue.body {
                        let frame = Self.place(picture, in: proxy.size)
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
                        .padding(.horizontal, 40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, proxy.size.height * 0.07)
                }
            }
        }
    }
    /// A picture cue's rectangle: its canvas fitted into the screen, as the video is.
    static func place(_ picture: SubtitleImage, in size: CGSize) -> CGRect {
        let canvas = picture.canvasSize
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(size.width / canvas.width, size.height / canvas.height)
        let origin = CGPoint(x: (size.width - canvas.width * scale) / 2, y: (size.height - canvas.height * scale) / 2)
        let spot = picture.position
        return CGRect(x: origin.x + spot.minX * scale, y: origin.y + spot.minY * scale, width: spot.width * scale, height: spot.height * scale)
    }
    /// ASS override tags ({\i1}) out, its line breaks (\N) in.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The Jellyfin user whose places and plays JellySpace keeps: the administrator (else the first
/// user), found once and remembered.
@MainActor enum JellyfinUser {
    private static let key = "jellyspace.userID"
    static func id(_ client: JellyfinClient) async -> String? {
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        guard let users = try? await client.users(), let user = users.first(where: { $0.Policy?.IsAdministrator == true }) ?? users.first else { return nil }
        UserDefaults.standard.set(user.Id, forKey: key)
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
