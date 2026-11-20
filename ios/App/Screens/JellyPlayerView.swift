import SwiftUI
import AVKit
import AetherEngine
import TwilDiaryCore

/// What the player opens: the stream, its title, and the Jellyfin item behind it (resume point,
/// progress, and the diary match when it's finished).
struct JellyPlayback: Identifiable {
    let id: String
    let url: URL
    let title: String
    let item: JellyfinClient.Item
    let client: JellyfinClient
}

/// JellySpace's player: AetherEngine's picture, sideways, with play and pause, 10 seconds back and on,
/// a scrub bar, audio and subtitle menus and Picture in Picture. It resumes where Jellyfin says you
/// stopped, saves your place there as you watch, and at 90% marks it played in Jellyfin and watched
/// in your diary (the title has to be in your diary; an episode by its show's TMDB id and number).
struct JellyPlayerView: View {
    let playback: JellyPlayback
    @Environment(\.dismiss) private var dismiss
    @Environment(DiaryStore.self) private var store
    @State private var engine: AetherEngine?
    @State private var pip = JellyPiP()
    @State private var state: PlaybackState = .idle
    @State private var time: Double = 0
    @State private var duration: Double = 0
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

    init(playback: JellyPlayback) {
        self.playback = playback
        _engine = State(initialValue: try? AetherEngine())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine {
                AetherPlayerSurface(engine: engine).ignoresSafeArea()
                    .onReceive(engine.$state) { state = $0; if $0 == .playing { pip.rebuildIfNeeded() } }
                    .onReceive(engine.clock.$currentTime) { seconds in time = seconds; reachedEnd(seconds) }
                    .onReceive(engine.$duration) { duration = $0 }
                    .onReceive(engine.$audioTracks) { audioTracks = $0 }
                    .onReceive(engine.$subtitleTracks) { tracks in subtitleTracks = tracks; pickDefaultSubtitle(tracks) }
                    .onReceive(engine.$activeAudioTrackIndex) { activeAudio = $0 }
                    .onReceive(engine.$activeSubtitleTrackIndex) { activeSubtitle = $0 }
                    .onReceive(engine.$subtitleCues) { cues = $0 }
                    .onReceive(engine.$softwarePiPSource) { _ in pip.rebuild() }
            }
            JellySubtitles(cues: cues, time: time).ignoresSafeArea().allowsHitTesting(false)
            Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() } }
            if showsControls || failure != nil { controls.transition(.opacity) }
            if let notice {
                Text(notice).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34).background(.black.opacity(0.7), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14).transition(.opacity)
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
        .task { await start() }
        .task(id: state == .playing) {
            // Your place, saved every 15 seconds while it plays.
            guard state == .playing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, state == .playing else { return }
                savePlace()
            }
        }
    }

    // MARK: Starting and finishing

    private func start() async {
        guard let engine else { failure = "The player couldn’t start."; return }
        pip.engine = engine
        let client = playback.client
        // The user Jellyfin keeps your places for (the administrator, else the first), found once.
        let user = await JellyfinUser.id(client)
        userID = user
        var startAt: Double?
        if let user, let data = try? await client.userData(playback.id, user: user), let ticks = data.PlaybackPositionTicks, ticks > 0 {
            startAt = Double(ticks) / 10_000_000
        }
        do {
            if let startAt, startAt > 30 {
                try await engine.load(url: playback.url, startPosition: startAt)
                resumedAt = startAt
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation { resumedAt = nil } }
            } else {
                try await engine.load(url: playback.url)
            }
            engine.play()
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    /// Where you are, to Jellyfin (not once it's finished: Jellyfin then starts it over next time).
    private func savePlace() {
        guard !finished, let user = userID, time > 5 else { return }
        let client = playback.client, id = playback.id, at = time
        Task { try? await client.savePosition(id, user: user, seconds: at) }
    }

    /// At 90%: played in Jellyfin, watched in the diary, once.
    private func reachedEnd(_ seconds: Double) {
        guard !finished, duration > 60, seconds >= duration * 0.9 else { return }
        finished = true
        let client = playback.client, id = playback.id, user = userID
        Task {
            if let user {
                try? await client.markPlayed(id, user: user)
                try? await client.savePosition(id, user: user, seconds: 0)
            }
            await markInDiary()
        }
    }

    private func markInDiary() async {
        let item = playback.item
        let episode = item.kind == "Episode"
        var ids = item.ProviderIds
        if episode, let series = item.SeriesId { ids = (try? await playback.client.item(series))?.ProviderIds }
        guard let tmdb = ids?["Tmdb"].flatMap(Int.init),
              let titleID = store.libraryIdentity(CatalogItem(id: tmdb, mediaType: episode ? .tv : .movie, name: item.SeriesName ?? item.Name ?? "")),
              let title = store.title(titleID) else { show("Not in your diary, so not marked"); return }
        if episode {
            guard let season = item.ParentIndexNumber, let number = item.IndexNumber,
                  let match = store.episodesForSeason(title.id, season: season).first(where: { $0.number == number }) else {
                show("Episode not found in your diary"); return
            }
            if await store.recordViewing(title, episode: match, watchedAt: store.now) { show("Marked S\(season) E\(number) in your diary") }
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
    @State private var pickedSubtitle = false
    private func pickDefaultSubtitle(_ tracks: [TrackInfo]) {
        guard !pickedSubtitle, !tracks.isEmpty else { return }
        pickedSubtitle = true
        if let track = tracks.first(where: { $0.isDefault }) ?? tracks.first(where: { $0.isForced }) {
            engine?.selectSubtitleTrack(index: track.id)
        }
    }

    // MARK: Controls

    private var playingNow: Bool { state == .playing }

    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var showsTracks = false

    /// The streaming-app layout: back and the title on top; back 10, play/pause and on 10 large in the
    /// middle; the bar with the time left at its end; then a row of labelled actions.
    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Close player").accessibilityIdentifier("jellyspace-close")
                Spacer(minLength: 0)
                Text(playback.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
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
                    }
                    transport("goforward.10", label: "Forward 10 seconds", size: 34) { jump(10) }
                }
            }
            Spacer(minLength: 0)
            if let resumedAt {
                Button { Task { await seek(0) }; withAnimation { self.resumedAt = nil } } label: {
                    Text("Resumed at \(Self.clock(resumedAt)) · Start over").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34).background(.black.opacity(0.6), in: Capsule())
                }.buttonStyle(.plain).padding(.bottom, 8).accessibilityIdentifier("jellyspace-start-over")
            }
            HStack(spacing: 14) {
                Slider(value: Binding(get: { scrub ?? time }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
                    guard !editing, let target = scrub else { return }
                    Task { await seek(target); scrub = nil }
                }.tint(theme.accent).disabled(duration <= 0)
                Text(Self.clock(max(0, duration - (scrub ?? time)))).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white).frame(minWidth: 56, alignment: .trailing)
            }.padding(.horizontal, 28)
            HStack(spacing: 34) {
                if audioTracks.count > 1 || !subtitleTracks.isEmpty {
                    action("captions.bubble", "Audio & Subtitles") { withAnimation(.easeInOut(duration: 0.2)) { showsTracks = true } }
                        .accessibilityIdentifier("jellyspace-tracks")
                }
                if pip.available { action("pip.enter", "Picture in Picture") { pip.start() } }
            }.padding(.top, 6).padding(.bottom, 14)
        }
        .background {
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        .overlay { if showsTracks { tracksPanel.transition(.opacity) } }
    }

    private func action(_ symbol: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 14, weight: .semibold))
            }.foregroundStyle(.white).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Audio and Subtitles side by side; the chosen one of each is ticked. A tap outside closes it.
    private var tracksPanel: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea().onTapGesture { withAnimation { showsTracks = false } }
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 40) {
                    if audioTracks.count > 1 {
                        trackColumn("Audio", rows: audioTracks.map { ($0.id, Self.label($0, audio: true)) }, chosen: activeAudio) { id in
                            if let id { engine?.selectAudioTrack(index: id) }
                        }
                    }
                    if !subtitleTracks.isEmpty {
                        trackColumn("Subtitles", rows: [(-1, "Off")] + subtitleTracks.map { ($0.id, Self.label($0, audio: false)) },
                                    chosen: activeSubtitle ?? -1) { id in
                            if let id, id >= 0 { engine?.selectSubtitleTrack(index: id) } else { engine?.clearSubtitle() }
                        }
                    }
                }
                Button("Close") { withAnimation { showsTracks = false } }.font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).frame(height: 38).background(.white.opacity(0.15), in: Capsule()).buttonStyle(.plain)
            }.padding(.horizontal, 40).padding(.vertical, 24)
        }
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
            }.frame(maxHeight: 220)
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

/// The subtitles on screen now: text cues at the bottom, picture cues (PGS, DVD) where the file
/// places them on its canvas. ASS styling is shown as plain text.
private struct JellySubtitles: View {
    let cues: [SubtitleCue]
    let time: Double
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
                    Text(lines.joined(separator: "\n")).font(.system(size: max(16, proxy.size.height * 0.05), weight: .semibold))
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
