import SwiftUI
import GoogleCast

/// Chromecast, through Jellyfin's own receiver app (the one Jellyfin's web app casts to): the phone
/// tells the TV the server's address, your sign-in and what to play, and the TV streams from the
/// server itself. The server transcodes what a Chromecast can't play, handles the subtitles and saves
/// your place. Messages go both ways as JSON on the receiver's channel (jellyfin-web's
/// chromecastPlayer: PlayNow, Seek, Pause, Unpause, Stop, NextTrack, SetAudioStreamIndex,
/// SetSubtitleStreamIndex; back come playbackstart, playbackprogress, playbackstop and errors).
@MainActor @Observable final class JellyCast: NSObject {
    static let shared = JellyCast()
    /// Jellyfin's receiver on the Chromecast (the server's default for every user).
    static let receiverID = "F007D354"
    static let namespace = "urn:x-cast:com.connectsdk"

    /// The Chromecast connected now ("Living Room TV"), nil when not casting.
    private(set) var deviceName: String?
    var connected: Bool { deviceName != nil }
    /// What the TV plays now.
    private(set) var itemID: String?
    private(set) var title = ""
    private(set) var seriesName: String?
    private(set) var duration: Double = 0
    private(set) var paused = false
    /// The last position the TV reported, and when (the time between is counted on the phone).
    private(set) var reported: Double = 0
    @ObservationIgnored private var reportedAt = Date.now
    /// Something went wrong on the TV ("couldn't play this"), for the remote to show.
    var problem: String?
    /// Where the phone's player was as casting began: the TV starts there.
    @ObservationIgnored var handoff: (id: String, seconds: Double)?

    @ObservationIgnored private var channel: JellyCastChannel?
    @ObservationIgnored private var server: [String: Any]?
    /// The diary (set as the app starts), and the video marked watched in it last.
    @ObservationIgnored weak var store: DiaryStore?
    @ObservationIgnored private var marked: String?

    /// Set up as the app starts (before any Cast button is made).
    static func setUp() {
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: receiverID))
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(shared)
    }

    /// The position now: the last report, plus the time since while it plays.
    func position(at date: Date = .now) -> Double {
        guard itemID != nil else { return 0 }
        let since = paused ? 0 : date.timeIntervalSince(reportedAt)
        return min(max(0, reported + since), duration > 0 ? duration : .infinity)
    }

    // MARK: Commands

    /// Plays this on the TV from a point (an episode with the rest of its season after it, so Next
    /// Episode and autoplay work there).
    func play(_ item: JellyfinClient.Item, from seconds: Double, queue: [JellyfinClient.Item] = []) async {
        guard connected, let client = JellySpace.client, let base = await serverFields(client) else { return }
        let serverID = base["serverId"] as? String ?? ""
        let stubs = ([item] + queue.filter { $0.Id != item.Id }).map { entry -> [String: Any] in
            ["Id": entry.Id, "ServerId": serverID, "Name": entry.Name ?? "", "Type": entry.kind, "MediaType": "Video", "IsFolder": false]
        }
        send("PlayNow", options: ["items": stubs, "startPositionTicks": Int64(max(0, seconds) * 10_000_000), "startIndex": 0], base: base)
        itemID = item.Id
        title = item.kind == "Episode" ? (item.Name ?? "") : (item.Name ?? "")
        seriesName = item.SeriesName
        duration = item.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        reported = seconds; reportedAt = .now; paused = false
    }
    func togglePause() {
        command(paused ? "Unpause" : "Pause")
        reported = position(); reportedAt = .now
        paused.toggle()
    }
    func seek(to seconds: Double) {
        command("Seek", options: ["position": max(0, seconds)])
        reported = max(0, seconds); reportedAt = .now
    }
    func next() { command("NextTrack") }
    /// A Jellyfin stream index (its MediaStreams' Index); -1 turns subtitles off.
    func setAudio(_ index: Int) { command("SetAudioStreamIndex", options: ["index": index]) }
    func setSubtitle(_ index: Int) { command("SetSubtitleStreamIndex", options: ["index": index]) }
    /// Stops the video on the TV and leaves the Chromecast.
    func stopCasting() {
        command("Stop")
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    private func command(_ name: String, options: [String: Any] = [:]) {
        guard connected, let base = server else { return }
        send(name, options: options, base: base)
    }
    private func send(_ name: String, options: [String: Any], base: [String: Any]) {
        var message = base
        message["command"] = name
        message["options"] = options
        message["receiverName"] = deviceName ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        channel?.sendTextMessage(text, error: nil)
    }

    /// What every message carries: the server (an address the TV can reach), your sign-in, this
    /// device. Read once a session.
    private func serverFields(_ client: JellyfinClient) async -> [String: Any]? {
        if let server { return server }
        guard let user = await JellyfinUser.id(client) else { return nil }
        let info = try? await client.publicInfo()
        var address = client.base.absoluteString
        // A localhost address means nothing to the TV: the server's own address on the network instead.
        if let host = client.base.host(), host == "localhost" || host.hasPrefix("127.") || host == "::1", let local = info?.LocalAddress {
            address = local
        }
        if address.hasSuffix("/") { address.removeLast() }
        let fields: [String: Any] = ["userId": user, "deviceId": JellyDevice.id, "accessToken": client.key, "serverAddress": address,
                                     "serverId": info?.Id ?? "", "serverVersion": info?.Version ?? ""]
        server = fields
        return fields
    }

    // MARK: The TV's side

    fileprivate func attach(_ session: GCKCastSession) {
        let name: String? = session.device.friendlyName
        deviceName = name ?? "Chromecast"
        let channel = JellyCastChannel(namespace: Self.namespace)
        session.add(channel)
        self.channel = channel
        server = nil
        problem = nil
        // Introduces this sender, as Jellyfin's web app does.
        Task { @MainActor [self] in
            guard let client = JellySpace.client, let base = await serverFields(client) else { return }
            send("Identify", options: [:], base: base)
        }
    }
    fileprivate func detach() {
        deviceName = nil; itemID = nil; title = ""; seriesName = nil; duration = 0; paused = false; reported = 0
        channel = nil; server = nil
    }
    /// A message from the TV: what it's playing, where, paused or not; or what went wrong.
    fileprivate func receive(_ text: String) {
        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "playbackstart", "playbackprogress":
            guard let state = message["data"] as? [String: Any] else { return }
            if let item = state["NowPlayingItem"] as? [String: Any] {
                if let id = item["Id"] as? String { itemID = id }
                if let name = item["Name"] as? String { title = name }
                seriesName = item["SeriesName"] as? String
                if let ticks = (item["RunTimeTicks"] as? NSNumber)?.doubleValue, ticks > 0 { duration = ticks / 10_000_000 }
            }
            if let play = state["PlayState"] as? [String: Any] {
                if let ticks = (play["PositionTicks"] as? NSNumber)?.doubleValue { reported = ticks / 10_000_000; reportedAt = .now }
                if let isPaused = play["IsPaused"] as? Bool { paused = isPaused }
            }
            markFinished(at: reported)
        case "playbackstop":
            markFinished(at: position())
            itemID = nil; paused = false
        case "playbackerror", "connectionerror":
            problem = (message["data"] as? String).map { "The TV couldn't play this: " + $0 } ?? "The TV couldn't play this"
        default:
            break
        }
    }
    /// At 90% on the TV: watched in the diary, once, as the phone's own player marks it (Jellyfin hears
    /// it from the TV itself).
    private func markFinished(at seconds: Double) {
        guard let id = itemID, marked != id, duration > 60, seconds >= duration * 0.9,
              UserDefaults.standard.object(forKey: JellyPrefs.diaryKey) as? Bool ?? true,
              let store, let client = JellySpace.client else { return }
        marked = id
        Task {
            guard let item = try? await client.item(id), ["Movie", "Episode"].contains(item.kind) else { return }
            _ = await JellyDiary.mark(item, client: client, store: store)
        }
    }
}

extension JellyCast: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        if let cast = session as? GCKCastSession { attach(cast) }
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        if let cast = session as? GCKCastSession { attach(cast) }
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        detach()
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        problem = "Couldn't connect to the Chromecast"
        detach()
    }
}

/// The receiver's message channel: what the TV sends goes to JellyCast (on the main thread, where the
/// Cast SDK calls in).
final class JellyCastChannel: GCKCastChannel {
    override func didReceiveTextMessage(_ message: String) {
        MainActor.assumeIsolated { JellyCast.shared.receive(message) }
    }
}

/// Google's Cast button: the Chromecasts on your Wi-Fi to choose from (it finds them after its
/// first tap, when iOS asks to use the local network).
struct JellyCastButton: UIViewRepresentable {
    var tint: UIColor = .white
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = tint
        return button
    }
    func updateUIView(_ button: GCKUICastButton, context: Context) { button.tintColor = tint }
}

/// While casting: the player as a remote. What's playing and on which TV, play or pause, 15 seconds
/// back or on, the bar, Audio & Subtitles, Next Episode, and Stop casting. Closing it leaves the TV
/// playing (the casting bar brings it back).
struct JellyCastRemote: View {
    /// What to send to the TV (nil: control whatever it plays now).
    let playback: JellyPlayback?
    let close: () -> Void
    @State private var audio: [Track] = []
    @State private var subtitles: [Track] = []
    @State private var audioIndex: Int?
    @State private var subtitleIndex: Int?
    @State private var scrub: Double?
    @State private var hasNext = false

    struct Track: Identifiable, Hashable { let id: Int; let name: String }

    var body: some View {
        let cast = JellyCast.shared
        ZStack {
            Color.black.ignoresSafeArea()
            if let client = JellySpace.client, let id = cast.itemID ?? playback?.id {
                JellyImage(url: JellyfinClient.imageURL(base: client.base, item: playback?.item.SeriesId ?? id, type: "Backdrop", tag: nil, width: 900))
                    .ignoresSafeArea().blur(radius: 30).opacity(0.35)
            }
            VStack(spacing: 18) {
                HStack {
                    Button(action: close) {
                        Image(systemName: "chevron.down").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Close the remote")
                    Spacer()
                    JellyCastButton().frame(width: 44, height: 44)
                }
                Spacer()
                Image(systemName: "tv").font(.system(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.85))
                Text("Playing on " + (cast.deviceName ?? "TV")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                VStack(spacing: 4) {
                    Text(cast.title.isEmpty ? (playback?.title ?? "") : cast.title)
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
                    if let series = cast.seriesName ?? playback?.item.SeriesName {
                        Text(series).font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                if let problem = cast.problem {
                    Text(problem).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.red.opacity(0.6), in: Capsule())
                }
                Spacer()
                JellyCastProgress(scrub: $scrub)
                HStack(spacing: 44) {
                    Button { cast.seek(to: cast.position() - 15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
                    Button { cast.togglePause() } label: { Image(systemName: cast.paused ? "play.fill" : "pause.fill").font(.system(size: 40)) }
                        .accessibilityLabel(cast.paused ? "Play" : "Pause")
                    Button { cast.seek(to: cast.position() + 15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("On 15 seconds")
                }
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.white).buttonStyle(.plain)
                HStack(spacing: 10) {
                    if !audio.isEmpty || !subtitles.isEmpty {
                        JellyCastTracksMenu(audio: audio, subtitles: subtitles, audioIndex: audioIndex, subtitleIndex: subtitleIndex) { kind, index in
                            if kind == "Audio" { audioIndex = index; JellyCast.shared.setAudio(index) } else { subtitleIndex = index; JellyCast.shared.setSubtitle(index) }
                        }
                        .equatable()
                    }
                    if hasNext {
                        pill("Next Episode", symbol: "forward.end") { cast.next() }
                    }
                    pill("Stop casting", symbol: "xmark.circle", tint: .red) {
                        cast.stopCasting()
                        close()
                    }
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task(id: playback?.id) { await start() }
        .task(id: cast.itemID) { await loadTracks() }
        .onChange(of: cast.connected) { _, connected in if !connected { close() } }
    }

    private func pill(_ title: String, symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .padding(.horizontal, 14).frame(height: 38).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    /// Sends the video to the TV unless it's playing it already: from where the phone's player was,
    /// else from where you stopped (an episode with the rest of its season after it).
    private func start() async {
        let cast = JellyCast.shared
        guard let playback, cast.itemID != playback.id, let client = JellySpace.client else { return }
        let user = await JellyfinUser.id(client)
        var seconds = 0.0
        if let handoff = cast.handoff, handoff.id == playback.id {
            seconds = handoff.seconds
        } else if let user, let data = try? await client.userData(playback.id, user: user), let ticks = data.PlaybackPositionTicks {
            seconds = Double(ticks) / 10_000_000
        }
        var queue: [JellyfinClient.Item] = []
        let item = playback.item
        if item.kind == "Episode", let series = item.SeriesId, let season = item.SeasonId,
           let episodes = try? await client.episodes(of: series, season: season, user: user),
           let at = episodes.firstIndex(where: { $0.Id == item.Id }) {
            queue = Array(episodes[(at + 1)...].prefix(20))
        }
        hasNext = !queue.isEmpty
        await cast.play(item, from: seconds, queue: queue)
    }
    /// The audio and subtitle tracks of what's playing (Jellyfin's stream indexes, which the TV takes).
    private func loadTracks() async {
        guard let client = JellySpace.client, let id = JellyCast.shared.itemID ?? playback?.id else { return }
        let user = await JellyfinUser.id(client)
        guard let info = try? await client.playerInfo(id, user: user), let streams = info.MediaSources?.first?.MediaStreams else { return }
        audio = streams.filter { $0.kind == "Audio" }.map { Track(id: $0.Index, name: $0.DisplayTitle ?? $0.Language ?? "Audio \($0.Index)") }
        subtitles = streams.filter { $0.kind == "Subtitle" }.map { Track(id: $0.Index, name: $0.DisplayTitle ?? $0.Language ?? "Subtitles \($0.Index)") }
    }
}

/// The remote's bar and times, redrawn once a second on their own (the rest of the remote doesn't).
private struct JellyCastProgress: View {
    @Binding var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let cast = JellyCast.shared
            let now = scrub ?? cast.position(at: context.date), total = max(cast.duration, 1)
            VStack(spacing: 6) {
                Slider(value: Binding(get: { now }, set: { scrub = $0 }), in: 0...total, onEditingChanged: { editing in
                    if !editing, let target = scrub { cast.seek(to: target); scrub = nil }
                })
                .tint(Color(red: 0.89, green: 0.16, blue: 0.16))
                .disabled(cast.duration <= 0)
                HStack {
                    Text(JellyPlayerView.clock(now))
                    Spacer()
                    Text("-" + JellyPlayerView.clock(max(0, cast.duration - now)))
                }
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

/// Audio & Subtitles on the TV: a menu of its own, drawn again only when the tracks or choices change.
private struct JellyCastTracksMenu: View, Equatable {
    let audio: [JellyCastRemote.Track]
    let subtitles: [JellyCastRemote.Track]
    let audioIndex: Int?
    let subtitleIndex: Int?
    let choose: @MainActor (String, Int) -> Void

    nonisolated static func == (lhs: JellyCastTracksMenu, rhs: JellyCastTracksMenu) -> Bool {
        lhs.audio == rhs.audio && lhs.subtitles == rhs.subtitles && lhs.audioIndex == rhs.audioIndex && lhs.subtitleIndex == rhs.subtitleIndex
    }

    var body: some View {
        Menu {
            if audio.count > 1 {
                Picker("Audio", selection: Binding(get: { audioIndex ?? -2 }, set: { choose("Audio", $0) })) {
                    ForEach(audio) { Text($0.name).tag($0.id) }
                }
            }
            if !subtitles.isEmpty {
                Picker("Subtitles", selection: Binding(get: { subtitleIndex ?? -2 }, set: { choose("Subtitle", $0) })) {
                    Text("Off").tag(-1)
                    ForEach(subtitles) { Text($0.name).tag($0.id) }
                }
            }
        } label: {
            Label("Audio & Subtitles", systemImage: "captions.bubble").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 38).background(.white.opacity(0.15), in: Capsule()).contentShape(Capsule())
        }
    }
}

/// While casting, on JellySpace's pages: what the TV plays and on which TV, play or pause; a tap opens
/// the remote.
struct JellyCastBar: View {
    @State private var open = false
    var body: some View {
        let cast = JellyCast.shared
        if cast.connected, cast.itemID != nil {
            HStack(spacing: 12) {
                Image(systemName: "tv").font(.system(size: 20)).foregroundStyle(HomeStyle.secondary).frame(width: 42, height: 42)
                    .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cast.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Label(cast.deviceName ?? "TV", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { cast.togglePause() } label: {
                    Image(systemName: cast.paused ? "play.fill" : "pause.fill").font(.system(size: 18)).foregroundStyle(HomeStyle.primary)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(cast.paused ? "Play on the TV" : "Pause on the TV")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle()).onTapGesture { open = true }
            .padding(.horizontal, 12)
            .accessibilityIdentifier("jellyspace-cast-bar")
            .fullScreenCover(isPresented: $open) { JellyCastRemote(playback: nil) { open = false }.jellyFaceLock() }
        }
    }
}
