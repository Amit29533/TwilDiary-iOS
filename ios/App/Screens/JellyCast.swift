import SwiftUI
import GoogleCast

/// Chromecast, through Jellyfin's own receiver app (the one Jellyfin's web app casts to): the phone
/// tells the TV the server's address, your sign-in and what to play, and the TV streams from the
/// server itself. The server transcodes what a Chromecast can't play, handles the subtitles and saves
/// your place. Messages go both ways as JSON on the receiver's channel (jellyfin-web's
/// chromecastPlayer: PlayNow, Seek, Pause, Unpause, Stop, NextTrack, SetAudioStreamIndex,
/// SetSubtitleStreamIndex; back come playbackstart, playbackprogress, playbackstop and errors).
/// The receiver asks the server for everything as the signed-in user, which the server's API key
/// isn't: the TV is given a sign-in as you (see tvSignIn).
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
    /// The show of what the TV plays (for the remote's picture, also when it's opened from the casting bar).
    private(set) var seriesID: String?
    private(set) var duration: Double = 0
    private(set) var paused = false
    /// The audio and subtitle tracks the TV plays now (Jellyfin's stream indexes; subtitles -1 for off),
    /// from its reports, or as just chosen.
    private(set) var audioTrack: Int?
    private(set) var subtitleTrack: Int?
    /// What was sent to the TV: the video and the episodes after it (for sending it again, see restart).
    @ObservationIgnored private var sent: [JellyfinClient.Item] = []
    /// The file (Jellyfin's media source) the TV plays, from its reports. The server keeps to a chosen
    /// audio or subtitle track only when the request names the file too; without it, it went back to the
    /// file's default audio (English) every time.
    @ObservationIgnored private var mediaSourceID: String?
    /// A track just chosen on the phone, and when: the TV's reports of the old one are passed over until
    /// it plays the new one (they set the menu back while the server made the new stream).
    @ObservationIgnored private var pendingAudio: (index: Int, at: Date)?
    @ObservationIgnored private var pendingSubtitle: (index: Int, at: Date)?
    /// The lock screen's, Control Center's and the Dynamic Island's card while a video casts.
    private let nowPlaying = JellyCastNowPlaying()
    /// The last position the TV reported, and when (the time between is counted on the phone).
    private(set) var reported: Double = 0
    @ObservationIgnored private var reportedAt = Date.now
    /// Something went wrong on the TV ("couldn't play this"), for the remote to show.
    var problem: String?
    /// Where the phone's player was as casting began: the TV starts there.
    @ObservationIgnored var handoff: (id: String, seconds: Double)?

    @ObservationIgnored private var channel: JellyCastChannel?
    @ObservationIgnored private var server: TVFields?
    /// The fields being made (the sign-in may take a moment): a second ask waits for the same one.
    @ObservationIgnored private var making: Task<TVFields?, Never>?
    /// What every message carries: the server (an address the TV can reach), the sign-in, this device.
    private struct TVFields: Sendable {
        let user: String, token: String, address: String, serverID: String, version: String
    }
    private static let tvTokenKey = "tv-token", tvForKey = "jellyspace.cast.tvSignInFor"
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
        let serverID = base.serverID
        let stubs = ([item] + queue.filter { $0.Id != item.Id }).map { entry -> [String: Any] in
            ["Id": entry.Id, "ServerId": serverID, "Name": entry.Name ?? "", "Type": entry.kind, "MediaType": "Video", "IsFolder": false]
        }
        send("PlayNow", options: ["items": stubs, "startPositionTicks": Int64(max(0, seconds) * 10_000_000), "startIndex": 0], base: base)
        itemID = item.Id
        title = item.kind == "Episode" ? (item.Name ?? "") : (item.Name ?? "")
        seriesName = item.SeriesName
        seriesID = item.SeriesId
        sent = [item] + queue.filter { $0.Id != item.Id }
        audioTrack = nil; subtitleTrack = nil; mediaSourceID = nil; pendingAudio = nil; pendingSubtitle = nil
        duration = item.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        reported = seconds; reportedAt = .now; paused = false
        refreshNowPlaying()
    }
    func togglePause() {
        if let media {
            if paused { media.play() } else { media.pause() }
        } else {
            command(paused ? "Unpause" : "Pause")
        }
        reported = position(); reportedAt = .now
        paused.toggle()
        refreshNowPlaying()
    }
    func seek(to seconds: Double) {
        let target = max(0, seconds)
        if let media {
            let options = GCKMediaSeekOptions()
            options.interval = target
            options.resumeState = .unchanged
            media.seek(with: options)
        } else {
            command("Seek", options: ["position": target])
        }
        reported = target; reportedAt = .now
        refreshNowPlaying()
    }
    /// Google's own media channel to the TV's player, once it plays something: pause, play and seek go
    /// there (every Cast receiver takes them, Jellyfin's included, and answers at once). Jellyfin's own
    /// messages are the way while nothing's loaded, and for what only Jellyfin knows (tracks, next).
    private var media: GCKRemoteMediaClient? {
        guard let client = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient,
              client.mediaStatus != nil else { return nil }
        return client
    }
    func next() { command("NextTrack") }
    /// A Jellyfin stream index (its MediaStreams' Index); -1 turns subtitles off.
    /// Another audio track: the video sent again from where it is, with it (see restart).
    func setAudio(_ index: Int) {
        audioTrack = index; pendingAudio = (index, .now)
        Task { await restart() }
    }
    /// Another subtitle track (-1 off). A text one the TV lays over the picture as it plays; a picture one
    /// (PGS, DVD) the server burns into the video, so that goes the way of an audio change (`restarting`).
    func setSubtitle(_ index: Int, restarting: Bool) {
        subtitleTrack = index; pendingSubtitle = (index, .now)
        if restarting { Task { await restart() } } else { command("SetSubtitleStreamIndex", options: ["index": index]) }
    }
    /// The video sent to the TV again from where it is, with the chosen tracks, as a new cast starts it.
    /// Asked to change the stream in place (SetAudioStreamIndex), Jellyfin's receiver stopped the picture,
    /// and once the server had the new stream ready its idle pictures stayed over the video while the new
    /// sound played behind them. Sent afresh it shows the video as it does for any cast. The server still
    /// makes the new stream first (another audio track can't be played straight from the file), so it
    /// takes a moment.
    func restart() async {
        guard connected, let id = itemID, let client = JellySpace.client, let base = await serverFields(client) else { return }
        var items = sent
        if let at = items.firstIndex(where: { $0.Id == id }) {
            items = Array(items[at...])
        } else {
            // Opened again (the app restarted): the video, and the episodes after it in its season.
            guard let item = try? await client.item(id) else { return }
            items = [item]
            if item.kind == "Episode", let series = item.SeriesId, let season = item.SeasonId,
               let episodes = try? await client.episodes(of: series, season: season, user: await JellyfinUser.id(client)),
               let at = episodes.firstIndex(where: { $0.Id == id }) {
                items += episodes[(at + 1)...].prefix(20)
            }
        }
        let stubs = items.map { entry -> [String: Any] in
            ["Id": entry.Id, "ServerId": base.serverID, "Name": entry.Name ?? "", "Type": entry.kind, "MediaType": "Video", "IsFolder": false]
        }
        // The file named with the tracks (see mediaSourceID): the one the TV reported, else the video's
        // first version, else the video itself (a single-version video's file has its id).
        var source = mediaSourceID
        if source == nil, let info = try? await client.playerInfo(id, user: await JellyfinUser.id(client)) { source = info.MediaSources?.first?.Id }
        guard connected, itemID == id else { return }
        let at = position()
        var options: [String: Any] = ["items": stubs, "startPositionTicks": Int64(at * 10_000_000), "startIndex": 0,
                                      "mediaSourceId": source ?? id]
        if let audioTrack { options["audioStreamIndex"] = audioTrack }
        if let subtitleTrack { options["subtitleStreamIndex"] = subtitleTrack }
        send("PlayNow", options: options, base: base)
        reported = at; reportedAt = .now
    }
    /// Stops the video on the TV and leaves the Chromecast.
    func stopCasting() {
        command("Stop")
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    private func command(_ name: String, options: [String: Any] = [:]) {
        guard connected else { return }
        if let base = server { send(name, options: options, base: base); return }
        // Still getting ready (just reconnected, the app opened again): sent once it is. A tap then was
        // dropped without a word, so the controls seemed not to work.
        guard let client = JellySpace.client else { return }
        Task { [self] in
            guard let base = await serverFields(client), connected else { return }
            send(name, options: options, base: base)
        }
    }
    private func send(_ name: String, options: [String: Any], base: TVFields) {
        var message: [String: Any] = ["userId": base.user, "deviceId": JellyDevice.id, "accessToken": base.token, "serverAddress": base.address,
                                      "serverId": base.serverID, "serverVersion": base.version]
        message["command"] = name
        message["options"] = options
        message["receiverName"] = deviceName ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        channel?.sendTextMessage(text, error: nil)
    }

    /// What every message carries. Made once a session.
    private func serverFields(_ client: JellyfinClient) async -> TVFields? {
        if let server { return server }
        if let making { return await making.value }
        let task = Task { await self.makeFields(client) }
        making = task
        let fields = await task.value
        making = nil
        return fields
    }
    private func makeFields(_ client: JellyfinClient) async -> TVFields? {
        guard let user = await JellyfinUser.id(client) else { return nil }
        guard let token = await tvSignIn(client, user: user) else {
            // Quick Connect off on a server that answers: only your own sign-in can go to the TV. Otherwise
            // the server didn't answer, or refused.
            let answers = (try? await client.publicInfo()) != nil
            if answers, !(await JellyAuth.quickConnectEnabled(client.base)) {
                problem = "To cast, sign in to Jellyfin as yourself in Settings → JellySpace"
            } else {
                problem = "The TV couldn't be signed in to your server"
            }
            return nil
        }
        let info = try? await client.publicInfo()
        var address = client.base.absoluteString
        // A localhost address means nothing to the TV: the server's own address on the network instead.
        if let host = client.base.host(), host == "localhost" || host.hasPrefix("127.") || host == "::1", let local = info?.LocalAddress {
            address = local
        }
        if address.hasSuffix("/") { address.removeLast() }
        let fields = TVFields(user: user, token: token, address: address, serverID: info?.Id ?? "", version: info?.Version ?? "")
        server = fields
        return fields
    }
    /// The sign-in the TV uses. Jellyfin's receiver asks for the video as the signed-in user, and the
    /// server's API key is no user: the server refused, the receiver said nothing, and the TV stayed on
    /// its pictures. Signed in as you in JellySpace, that sign-in; with the API key, one of the TV's own
    /// as the user JellySpace watches as (made once with Quick Connect, kept, made again if it's removed).
    private func tvSignIn(_ client: JellyfinClient, user: String) async -> String? {
        if JellyAccount.token != nil { return client.key }
        let owner = client.base.absoluteString + "|" + user
        if UserDefaults.standard.string(forKey: Self.tvForKey) == owner, let saved = JellySecrets.read(Self.tvTokenKey),
           await JellyAuth.tvSignInWorks(client.base, token: saved) != false {
            return saved
        }
        guard let session = try? await JellyAuth.signInForTV(client.base, apiKey: client.key, user: user) else { return nil }
        JellySecrets.write(Self.tvTokenKey, session.AccessToken)
        UserDefaults.standard.set(owner, forKey: Self.tvForKey)
        return session.AccessToken
    }

    // MARK: The TV's side

    fileprivate func attach(_ session: GCKCastSession) {
        let name: String? = session.device.friendlyName
        deviceName = name ?? "Chromecast"
        let channel = JellyCastChannel(namespace: Self.namespace)
        session.add(channel)
        self.channel = channel
        server = nil; making = nil
        problem = nil
        // Introduces this sender, as Jellyfin's web app does.
        Task { @MainActor [self] in
            guard let client = JellySpace.client, let base = await serverFields(client) else { return }
            send("Identify", options: [:], base: base)
        }
    }
    fileprivate func detach() {
        deviceName = nil; itemID = nil; title = ""; seriesName = nil; seriesID = nil; duration = 0; paused = false; reported = 0
        channel = nil; server = nil; making = nil
        audioTrack = nil; subtitleTrack = nil; sent = []; mediaSourceID = nil; pendingAudio = nil; pendingSubtitle = nil
        nowPlaying.end()
    }
    /// The Now Playing card follows what the TV plays (see JellyCastNowPlaying), and goes once nothing does.
    /// JellySpace's own music keeps the card while it plays.
    private func refreshNowPlaying() {
        guard connected, let id = itemID, let client = JellySpace.client else { nowPlaying.end(); return }
        if !nowPlaying.active {
            guard !JellyMusic.shared.playing else { return }
            nowPlaying.begin(JellyCastNowPlaying.Actions(
                play: { [weak self] play in
                    guard let self else { return }
                    if play == nil || play == self.paused { self.togglePause() }
                },
                seek: { [weak self] in self?.seek(to: $0) },
                position: { [weak self] in self?.position() ?? 0 },
                next: { [weak self] in self?.next() }))
        }
        nowPlaying.update(.init(title: title.isEmpty ? (seriesName ?? "Casting") : title,
                                subtitle: [seriesName, deviceName].compactMap { $0 }.joined(separator: " · "),
                                duration: duration, position: position(), paused: paused,
                                artwork: JellyfinClient.imageURL(base: client.base, item: seriesID ?? id, type: "Primary", tag: nil, width: 600)))
    }
    /// Whether a track the TV reports is taken: not while one just chosen on the phone isn't playing yet
    /// (for up to two minutes, as the server makes the new stream).
    private static func takes(_ reported: Int, pending: inout (index: Int, at: Date)?) -> Bool {
        guard let chosen = pending else { return true }
        guard reported == chosen.index || Date.now.timeIntervalSince(chosen.at) > 120 else { return false }
        pending = nil
        return true
    }
    /// A message from the TV: what it's playing, where, paused or not; or what went wrong.
    fileprivate func receive(_ text: String) {
        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        defer { refreshNowPlaying() }
        switch type {
        case "playbackstart", "playbackprogress":
            guard let state = message["data"] as? [String: Any] else { return }
            if type == "playbackstart" { problem = nil }
            if let item = state["NowPlayingItem"] as? [String: Any] {
                if let id = item["Id"] as? String { itemID = id }
                if let name = item["Name"] as? String { title = name }
                seriesName = item["SeriesName"] as? String
                seriesID = item["SeriesId"] as? String
                if let ticks = (item["RunTimeTicks"] as? NSNumber)?.doubleValue, ticks > 0 { duration = ticks / 10_000_000 }
            }
            if let play = state["PlayState"] as? [String: Any] {
                if let source = play["MediaSourceId"] as? String, !source.isEmpty { mediaSourceID = source }
                if let audio = (play["AudioStreamIndex"] as? NSNumber)?.intValue, Self.takes(audio, pending: &pendingAudio) { audioTrack = audio }
                if let subtitle = (play["SubtitleStreamIndex"] as? NSNumber)?.intValue, Self.takes(subtitle, pending: &pendingSubtitle) { subtitleTrack = subtitle }
                if let ticks = (play["PositionTicks"] as? NSNumber)?.doubleValue { reported = ticks / 10_000_000; reportedAt = .now }
                if let isPaused = play["IsPaused"] as? Bool { paused = isPaused }
            }
            markFinished(at: reported)
        case "playbackstop":
            markFinished(at: position())
            itemID = nil; paused = false
        case "playbackerror", "connectionerror":
            // The receiver's reason is in "message" (a code from the server, or nothing).
            problem = Self.problem(type: type, detail: message["message"] as? String ?? message["data"] as? String)
        default:
            break
        }
    }
    /// What went wrong on the TV, in words.
    nonisolated static func problem(type: String, detail: String?) -> String? {
        let code = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch type {
        case "connectionerror": return "The TV couldn't reach your server"
        case "playbackerror":
            switch code {
            case "NoCompatibleStream": return "The TV can't play this file, and your server couldn't convert it for the TV"
            case "NotAllowed": return "Your Jellyfin user isn't allowed to play this"
            case "RateLimitExceeded": return "Your server is busy. Try again in a moment"
            case "": return "The TV couldn't play this"
            default: return "The TV couldn't play this (\(code))"
            }
        default: return nil
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
    @State private var scrub: Double?
    @State private var hasNext = false

    struct Track: Identifiable, Hashable {
        let id: Int
        let name: String
        /// A picture subtitle (PGS, DVD, DVB): burned into the video by the server.
        var picture = false
    }
    /// Subtitle formats that are pictures, not text.
    static let pictureSubtitles: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "pgs", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle", "xsub"]

    var body: some View {
        let cast = JellyCast.shared
        ZStack {
            Color.black.ignoresSafeArea()
            if let client = JellySpace.client, let id = cast.itemID ?? playback?.id {
                // Filling the screen without setting its width: the picture (wider than the phone) set the
                // remote's width, so its sides were off the screen (Audio & Subtitles, Stop casting, the times).
                Color.clear.overlay {
                    JellyImage(url: JellyfinClient.imageURL(base: client.base, item: playback?.item.SeriesId ?? cast.seriesID ?? id, type: "Backdrop", tag: nil, width: 900))
                }
                .clipped().ignoresSafeArea().blur(radius: 30).opacity(0.35)
            }
            VStack(spacing: 18) {
                HStack {
                    Button(action: close) {
                        Image(systemName: "chevron.down").font(.app(size: 18, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Close the remote")
                    Spacer()
                    JellyCastButton().frame(width: 44, height: 44)
                }
                Spacer()
                Image(systemName: "tv").font(.app(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.85))
                Text("Playing on " + (cast.deviceName ?? "TV")).font(.app(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                VStack(spacing: 4) {
                    Text(cast.title.isEmpty ? (playback?.title ?? "") : cast.title)
                        .font(.app(size: 22, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
                    if let series = cast.seriesName ?? playback?.item.SeriesName {
                        Text(series).font(.app(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                if let problem = cast.problem {
                    Text(problem).font(.app(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.red.opacity(0.6), in: Capsule())
                }
                Spacer()
                JellyCastProgress(scrub: $scrub)
                HStack(spacing: 44) {
                    Button { cast.seek(to: cast.position() - 15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
                    Button { cast.togglePause() } label: { Image(systemName: cast.paused ? "play.fill" : "pause.fill").font(.app(size: 40)) }
                        .accessibilityLabel(cast.paused ? "Play" : "Pause")
                    Button { cast.seek(to: cast.position() + 15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("On 15 seconds")
                }
                .font(.app(size: 30, weight: .medium)).foregroundStyle(.white).buttonStyle(.plain)
                // Round buttons with their names under them, sharing the width: three pills side by side
                // were wider than the screen (cut off at both edges, and the bar's times pushed off it).
                HStack(alignment: .top, spacing: 8) {
                    if !audio.isEmpty || !subtitles.isEmpty {
                        JellyCastTracksMenu(audio: audio, subtitles: subtitles, audioIndex: cast.audioTrack, subtitleIndex: cast.subtitleTrack) { kind, index in
                            if kind == "Audio" {
                                JellyCast.shared.setAudio(index)
                            } else {
                                // From or to a picture subtitle, the video is sent again (the server burns it in).
                                let picture = { (id: Int?) in subtitles.first { $0.id == id }?.picture ?? false }
                                JellyCast.shared.setSubtitle(index, restarting: picture(index) || picture(cast.subtitleTrack))
                            }
                        }
                        .equatable()
                        .frame(maxWidth: .infinity)
                    }
                    if hasNext {
                        roundButton("Next Episode", symbol: "forward.end") { cast.next() }
                    }
                    roundButton("Stop casting", symbol: "xmark.circle", tint: .red) {
                        cast.stopCasting()
                        close()
                    }
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task(id: playback?.id) { await start() }
        .task(id: cast.itemID) { await loadTracks(); await findNext() }
        .onChange(of: cast.connected) { _, connected in if !connected { close() } }
    }

    private func roundButton(_ title: String, symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) { JellyCastRound(title: title, symbol: symbol, tint: tint) }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
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
    /// Whether the TV has an episode after the one it plays now (it was sent the rest of the season): Next
    /// Episode was missing when the remote was opened from the casting bar, and stayed after the last one.
    private func findNext() async {
        guard let client = JellySpace.client, let id = JellyCast.shared.itemID else { return }
        let user = await JellyfinUser.id(client)
        guard let item = try? await client.item(id), item.kind == "Episode", let series = item.SeriesId, let season = item.SeasonId,
              let episodes = try? await client.episodes(of: series, season: season, user: user),
              let at = episodes.firstIndex(where: { $0.Id == id }) else { return }
        hasNext = at + 1 < episodes.count
    }
    /// The audio and subtitle tracks of what's playing (Jellyfin's stream indexes, which the TV takes).
    private func loadTracks() async {
        guard let client = JellySpace.client, let id = JellyCast.shared.itemID ?? playback?.id else { return }
        let user = await JellyfinUser.id(client)
        guard let info = try? await client.playerInfo(id, user: user), let streams = info.MediaSources?.first?.MediaStreams else { return }
        audio = streams.filter { $0.kind == "Audio" }.map { Track(id: $0.Index, name: $0.DisplayTitle ?? $0.Language ?? "Audio \($0.Index)") }
        subtitles = streams.filter { $0.kind == "Subtitle" }.map {
            Track(id: $0.Index, name: $0.DisplayTitle ?? $0.Language ?? "Subtitles \($0.Index)", picture: Self.pictureSubtitles.contains(($0.Codec ?? "").lowercased()))
        }
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
                .font(.app(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
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
            JellyCastRound(title: "Audio & Subtitles", symbol: "captions.bubble")
        }
    }
}

/// One of the remote's bottom buttons: a round icon with its name under it.
private struct JellyCastRound: View {
    let title: String
    let symbol: String
    var tint: Color = .white

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.app(size: 19, weight: .semibold))
                .frame(width: 48, height: 48).background(.white.opacity(0.15), in: Circle())
            Text(title).font(.app(size: 12, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
        }
        .foregroundStyle(tint).frame(maxWidth: .infinity).contentShape(Rectangle())
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
                Image(systemName: "tv").font(.app(size: 20)).foregroundStyle(HomeStyle.secondary).frame(width: 42, height: 42)
                    .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cast.title).font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Label(cast.deviceName ?? "TV", systemImage: "dot.radiowaves.left.and.right").font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { cast.togglePause() } label: {
                    Image(systemName: cast.paused ? "play.fill" : "pause.fill").font(.app(size: 18)).foregroundStyle(HomeStyle.primary)
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
