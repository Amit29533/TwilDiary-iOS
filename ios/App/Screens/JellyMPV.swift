import SwiftUI
import UIKit
import AVFoundation
import AetherEngine
import Libmpv

// MARK: Which player a video opens in

/// Videos you've moved to mpv (More → Decoder → mpv) open there from then on.
enum JellyMPVChoice {
    private static let key = "jellyspace.mpvItems"
    static func isOn(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id) }
    static func set(_ id: String, _ on: Bool) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}

/// The Decoder choice: AetherEngine picking (Auto), AetherEngine's own decoder (App), or mpv.
enum JellyDecoder: String, CaseIterable, Sendable {
    case auto, app, mpv
    var title: String {
        switch self {
        case .auto: "Auto"
        case .app: "App"
        case .mpv: "mpv"
        }
    }
    var path: DecodePath { self == .app ? .software : .automatic }
}

/// Opens a video in JellySpace's player (AetherEngine), or in mpv when it was moved there, and
/// switches between the two where you are.
struct JellyPlayerHost: View {
    @State private var playback: JellyPlayback
    @State private var usesMPV: Bool
    /// Where the other player was when you switched (nil: where Jellyfin says you stopped).
    @State private var handoff: Double?

    init(playback: JellyPlayback) {
        _playback = State(initialValue: playback)
        _usesMPV = State(initialValue: JellyMPVChoice.isOn(playback.id))
    }

    var body: some View {
        if usesMPV {
            JellyMPVPlayerView(playback: playback, startAt: handoff) { at in
                JellyMPVChoice.set(playback.id, false)
                handoff = at
                usesMPV = false
            }
        } else {
            JellyPlayerView(playback: playback, startAt: handoff) { now, at in
                JellyMPVChoice.set(now.id, true)
                playback = now
                handoff = at
                usesMPV = true
            }
        }
    }
}

// MARK: mpv

/// One of the file's tracks as mpv lists it.
struct JellyMPVTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
}

/// What the event thread hands to the main actor.
private enum JellyMPVChange: Sendable {
    case time(Double), duration(Double), paused(Bool), buffering(Bool), ended(Bool), speed(Double)
    case tracks(audio: [JellyMPVTrack], subtitles: [JellyMPVTrack], aid: Int?, sid: Int?)
    case loaded
    case log(String), failed(String)
}

/// mpv's handle, for the event thread (its client API may be called from any thread).
private struct JellyMPVHandle: @unchecked Sendable {
    let raw: OpaquePointer
}

/// libmpv driving a Metal layer: the file, its clock, its tracks. Events are read on a thread of their
/// own and published on the main actor.
@MainActor final class JellyMPV: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var paused = false
    @Published private(set) var buffering = true
    @Published private(set) var ended = false
    @Published private(set) var speed: Double = 1
    @Published private(set) var audioTracks: [JellyMPVTrack] = []
    @Published private(set) var subtitleTracks: [JellyMPVTrack] = []
    @Published private(set) var audioID: Int?
    @Published private(set) var subtitleID: Int?
    @Published private(set) var loaded = false
    /// Why the video didn't open (mpv's own words), and its latest warnings and errors.
    @Published private(set) var failure: String?
    @Published private(set) var log: [String] = []

    private var handle: JellyMPVHandle?
    /// Jellyfin's separate subtitle files, added once the video has opened.
    private var pendingSubtitles: [ExternalSubtitleTrack] = []

    func start(layer: CAMetalLayer, url: URL, at seconds: Double?, subtitles: [ExternalSubtitleTrack], smooth: Int) {
        guard handle == nil else { return }
        guard let raw = mpv_create() else { failure = "mpv couldn't be created."; return }
        mpv_request_log_messages(raw, "warn")
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(raw, "wid", MPV_FORMAT_INT64, &wid)
        let options: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox"),
            ("keep-open", "yes"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"),
            ("sub-auto", "no"), ("subs-fallback", "yes"), ("subs-match-os-language", "yes"), ("audio-display", "no"),
            ("cache", "yes"), ("demuxer-max-bytes", "150MiB"), ("demuxer-readahead-secs", "20"),
        ]
        for (name, value) in options { mpv_set_option_string(raw, name, value) }
        for (name, value) in Self.smoothOptions(smooth) { mpv_set_option_string(raw, name, value) }
        let started = mpv_initialize(raw)
        guard started >= 0 else {
            failure = "mpv didn't start: " + String(cString: mpv_error_string(started))
            mpv_terminate_destroy(raw)
            return
        }
        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE),
            ("track-list", MPV_FORMAT_NONE), ("aid", MPV_FORMAT_NONE), ("sid", MPV_FORMAT_NONE),
        ]
        for (name, format) in observed { mpv_observe_property(raw, 0, name, format) }
        Self.addJellyfinProtocol(raw)
        let handle = JellyMPVHandle(raw: raw)
        self.handle = handle
        pendingSubtitles = subtitles
        Self.readEvents(handle) { [weak self] change in self?.apply(change) }
        var load = ["loadfile", JellyMPVStream.scheme + url.absoluteString, "replace"]
        if let seconds, seconds > 1 { load += ["-1", "start=\(seconds)"] }
        command(load)
    }

    /// Closes the file; the event thread frees mpv once it has shut down.
    func stop() {
        guard let raw = handle?.raw else { return }
        handle = nil
        mpv_command_string(raw, "quit")
    }

    func togglePause() { set("pause", paused ? "no" : "yes") }
    func pause() { set("pause", "yes") }
    func seek(to seconds: Double) { command(["seek", String(max(0, seconds)), "absolute"]) }
    func skip(_ seconds: Double) { command(["seek", String(seconds), "relative"]) }
    func setSpeed(_ value: Double) { set("speed", String(value)) }
    func selectAudio(_ id: Int) { set("aid", String(id)) }
    func selectSubtitle(_ id: Int?) { set("sid", id.map(String.init) ?? "no") }
    /// Smooth motion at 60 or 120 Hz (0 off): frames timed to the screen's refresh and blended where
    /// they fall between two refreshes (mpv's display-resample with interpolation), so pans and
    /// handheld shots don't judder.
    func setSmooth(_ rate: Int) {
        for (name, value) in Self.smoothOptions(rate) { set(name, value) }
    }
    nonisolated private static func smoothOptions(_ rate: Int) -> [(String, String)] {
        rate > 0 ? [("display-fps-override", String(rate)), ("video-sync", "display-resample"), ("interpolation", "yes"), ("tscale", "oversample")]
                 : [("interpolation", "no"), ("video-sync", "audio")]
    }
    /// The picture off in the background (mpv's Metal layer can't draw there) and back.
    func showVideo(_ on: Bool) { set("vid", on ? "auto" : "no") }

    private func set(_ name: String, _ value: String) {
        guard let raw = handle?.raw else { return }
        mpv_set_property_string(raw, name, value)
    }

    private func command(_ args: [String]) {
        guard let raw = handle?.raw else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for pointer in cargs { free(UnsafeMutablePointer(mutating: pointer)) } }
        mpv_command(raw, &cargs)
    }

    private func apply(_ change: JellyMPVChange) {
        switch change {
        case .time(let value): time = value
        case .duration(let value): duration = value
        case .paused(let value): paused = value
        case .buffering(let value): buffering = value
        case .ended(let value): ended = value
        case .speed(let value): speed = value
        case .tracks(let audio, let subtitles, let aid, let sid):
            audioTracks = audio; subtitleTracks = subtitles; audioID = aid; subtitleID = sid
        case .log(let line):
            log = Array((log + [line]).suffix(8))
        case .failed(let reason):
            failure = reason; buffering = false
        case .loaded:
            loaded = true; buffering = false
            for subtitle in pendingSubtitles {
                command(["sub-add", JellyMPVStream.scheme + subtitle.url.absoluteString, "auto", subtitle.name ?? "Subtitles", subtitle.language ?? ""])
            }
            pendingSubtitles = []
        }
    }

    /// jellyfin://<address>: mpv reads the file through JellyMPVStream (the FFmpeg mpv runs on in this
    /// app is AetherEngine's, which has no network of its own).
    nonisolated private static func addJellyfinProtocol(_ raw: OpaquePointer) {
        mpv_stream_cb_add_ro(raw, "jellyfin", nil) { _, uri, info in
            guard let uri, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let text = String(cString: uri)
            guard text.hasPrefix(JellyMPVStream.scheme), let url = URL(string: String(text.dropFirst(JellyMPVStream.scheme.count))),
                  let stream = JellyMPVStream(url: url) else { return MPV_ERROR_LOADING_FAILED.rawValue }
            info.pointee.cookie = Unmanaged.passRetained(stream).toOpaque()
            info.pointee.read_fn = { cookie, buffer, count in
                guard let cookie, let buffer else { return -1 }
                return Unmanaged<JellyMPVStream>.fromOpaque(cookie).takeUnretainedValue().read(into: buffer, count: count)
            }
            info.pointee.seek_fn = { cookie, offset in
                guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
                return Unmanaged<JellyMPVStream>.fromOpaque(cookie).takeUnretainedValue().seek(to: offset)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
                return Unmanaged<JellyMPVStream>.fromOpaque(cookie).takeUnretainedValue().length
            }
            info.pointee.cancel_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<JellyMPVStream>.fromOpaque(cookie).takeUnretainedValue().cancel()
            }
            info.pointee.close_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<JellyMPVStream>.fromOpaque(cookie).release()
            }
            return 0
        }
    }

    // MARK: The event thread

    nonisolated private static func readEvents(_ handle: JellyMPVHandle, deliver: @escaping @Sendable @MainActor (JellyMPVChange) -> Void) {
        let thread = Thread {
            var lastTime = -1.0
            while true {
                guard let event = mpv_wait_event(handle.raw, -1)?.pointee else { continue }
                if event.event_id == MPV_EVENT_SHUTDOWN { break }
                var change: JellyMPVChange?
                switch event.event_id {
                case MPV_EVENT_FILE_LOADED:
                    change = .loaded
                case MPV_EVENT_LOG_MESSAGE:
                    if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                       let prefix = message.prefix, let level = message.level, let text = message.text {
                        let line = "[\(String(cString: prefix))] \(String(cString: level)): \(String(cString: text))"
                        change = .log(line.replacing(/api_key=[^&\s]+/, with: "api_key=…").trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                case MPV_EVENT_END_FILE:
                    if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee, end.reason == MPV_END_FILE_REASON_ERROR {
                        change = .failed("mpv couldn't open this video: " + String(cString: mpv_error_string(end.error)))
                    }
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                          let cName = property.name else { break }
                    let name = String(cString: cName)
                    let number = property.format == MPV_FORMAT_DOUBLE ? property.data?.assumingMemoryBound(to: Double.self).pointee : nil
                    let flag = property.format == MPV_FORMAT_FLAG ? property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } : nil
                    switch name {
                    case "time-pos":
                        // A few times a second is enough for the clock and the bar.
                        if let number, abs(number - lastTime) >= 0.25 { lastTime = number; change = .time(number) }
                    case "duration": if let number { change = .duration(number) }
                    case "pause": if let flag { change = .paused(flag) }
                    case "paused-for-cache": if let flag { change = .buffering(flag) }
                    case "eof-reached": change = .ended(flag ?? false)
                    case "speed": if let number { change = .speed(number) }
                    case "track-list", "aid", "sid": change = Self.tracks(handle.raw)
                    default: break
                    }
                default:
                    break
                }
                if let change {
                    DispatchQueue.main.async { MainActor.assumeIsolated { deliver(change) } }
                }
            }
            mpv_terminate_destroy(handle.raw)
        }
        thread.name = "mpv events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The audio and subtitle tracks, read from mpv's track list.
    nonisolated private static func tracks(_ raw: OpaquePointer) -> JellyMPVChange {
        var audio: [JellyMPVTrack] = [], subtitles: [JellyMPVTrack] = []
        var aid: Int?, sid: Int?
        let count = int(raw, "track-list/count") ?? 0
        for index in 0..<count {
            let base = "track-list/\(index)/"
            guard let type = string(raw, base + "type"), let id = int(raw, base + "id") else { continue }
            let language = string(raw, base + "lang").flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            let title = string(raw, base + "title")
            let codec = string(raw, base + "codec")?.uppercased()
            let label = [title ?? language ?? "Track \(id)", title != nil ? language : nil, codec]
                .compactMap { $0 }.joined(separator: " · ")
            let selected = string(raw, base + "selected") == "yes"
            switch type {
            case "audio": audio.append(JellyMPVTrack(id: id, label: label)); if selected { aid = id }
            case "sub": subtitles.append(JellyMPVTrack(id: id, label: label)); if selected { sid = id }
            default: break
            }
        }
        return .tracks(audio: audio, subtitles: subtitles, aid: aid, sid: sid)
    }
    nonisolated private static func string(_ raw: OpaquePointer, _ name: String) -> String? {
        guard let value = mpv_get_property_string(raw, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }
    nonisolated private static func int(_ raw: OpaquePointer, _ name: String) -> Int? {
        var value: Int64 = 0
        return mpv_get_property(raw, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
    }
}

/// A file on the server as mpv reads it: ranges of it fetched over HTTP as mpv asks (4 MB at a
/// time; mpv's own cache reads ahead of the picture). mpv calls read, seek and size from one thread,
/// and cancel from any.
final class JellyMPVStream: @unchecked Sendable {
    static let scheme = "jellyfin://"
    private static let chunk: Int64 = 4 << 20
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let url: URL
    private var position: Int64 = 0
    /// The file's length (-1 until the server has said).
    private(set) var length: Int64 = -1
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    /// Opens it with its first piece (which also gives its length); nil when the server won't serve it.
    init?(url: URL) {
        self.url = url
        guard fill(at: 0) else { return nil }
    }

    func read(into out: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        if length >= 0, position >= length { return 0 }
        if position < bufferStart || position >= bufferStart + Int64(buffer.count) {
            guard fill(at: position) else { return -1 }
            if buffer.isEmpty { return 0 }
        }
        let offset = Int(position - bufferStart)
        let taken = min(Int(min(count, UInt64(Int.max))), buffer.count - offset)
        buffer.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(out, base + offset, taken) }
        }
        position += Int64(taken)
        return Int64(taken)
    }

    func seek(to offset: Int64) -> Int64 {
        guard offset >= 0, length < 0 || offset <= length else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        position = offset
        return offset
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    /// The piece starting here.
    private func fill(at start: Int64) -> Bool {
        lock.lock()
        let stop = cancelled
        lock.unlock()
        if stop { return false }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + Self.chunk - 1)", forHTTPHeaderField: "Range")
        let done = DispatchSemaphore(value: 0)
        let result = JellyMPVFetch()
        let task = Self.session.dataTask(with: request) { data, response, _ in
            result.data = data
            result.response = response as? HTTPURLResponse
            done.signal()
        }
        lock.lock(); self.task = task; lock.unlock()
        task.resume()
        done.wait()
        lock.lock(); self.task = nil; lock.unlock()
        // Only a range answer: a server sending the whole file at once would fill the memory.
        guard let response = result.response, response.statusCode == 206, let data = result.data else {
            if let response = result.response, response.statusCode == 416 { buffer = Data(); bufferStart = start; return true }
            return false
        }
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            length = total
        }
        buffer = data
        bufferStart = start
        return true
    }
}

/// One answer from the server, handed from URLSession's thread to the reading one.
private final class JellyMPVFetch: @unchecked Sendable {
    var data: Data?
    var response: HTTPURLResponse?
}

/// Holds the screen at a refresh rate while smooth motion is on (a display link asking for it; the
/// frames themselves come from mpv). 0 lets iOS choose again.
@MainActor final class JellyRefreshRate {
    private var link: CADisplayLink?
    private let target = JellyRefreshTarget()

    func hold(_ rate: Int) {
        link?.invalidate()
        link = nil
        guard rate > 0 else { return }
        let link = CADisplayLink(target: target, selector: #selector(JellyRefreshTarget.tick(_:)))
        let hz = Float(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
}
private final class JellyRefreshTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {}
}

/// The Metal layer mpv draws into. MoltenVK sets a 1×1 drawable to finish a presentation early, which
/// flickers and can stick; such sizes are ignored (mpv's own workaround).
final class JellyMPVLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue } }
    }
}

final class JellyMPVSurfaceView: UIView {
    override class var layerClass: AnyClass { JellyMPVLayer.self }
}

/// The picture: a view backed by mpv's Metal layer, with mpv started on it.
private struct JellyMPVSurface: UIViewRepresentable {
    let player: JellyMPV
    let url: URL
    let start: Double?
    let subtitles: [ExternalSubtitleTrack]
    let smooth: Int
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> JellyMPVSurfaceView {
        let view = JellyMPVSurfaceView()
        view.backgroundColor = .black
        if let layer = view.layer as? CAMetalLayer {
            layer.contentsScale = displayScale
            layer.framebufferOnly = true
            layer.backgroundColor = UIColor.black.cgColor
            player.start(layer: layer, url: url, at: start, subtitles: subtitles, smooth: smooth)
        }
        return view
    }
    func updateUIView(_ view: JellyMPVSurfaceView, context: Context) {}
}

// MARK: The mpv player

/// The fallback player: mpv's picture with simple controls (back and on 15 seconds, play/pause, the
/// bar, audio and subtitles, speed, and the decoder to go back to JellySpace's player). It resumes and
/// saves your place in Jellyfin, and at 90% marks it played there and watched in your diary.
struct JellyMPVPlayerView: View {
    let playback: JellyPlayback
    /// Where to start (from the other player); nil starts where Jellyfin says you stopped.
    let startAt: Double?
    /// Back to JellySpace's player, at this time.
    let toEngine: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(DiaryStore.self) private var store
    @AppStorage(JellyPrefs.resumeKey) private var resumeOn = true
    @AppStorage(JellyPrefs.diaryKey) private var diaryOn = true
    /// Smooth motion: 0 (off), 60 or 120 Hz, kept for every video.
    @AppStorage("jellyspace.mpvSmoothRate") private var smoothMotion = 0
    @State private var refresh = JellyRefreshRate()
    @StateObject private var mpv = JellyMPV()
    @State private var start: Double?
    @State private var subtitles: [ExternalSubtitleTrack] = []
    @State private var ready = false
    @State private var userID: String?
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var finished = false
    @State private var switching = false
    /// Still nothing opened ten seconds in: mpv's latest warnings show.
    @State private var stalled = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready {
                JellyMPVSurface(player: mpv, url: playback.url, start: start, subtitles: subtitles, smooth: smoothMotion).ignoresSafeArea()
            }
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                    if showsControls { scheduleHide() }
                }
            if mpv.buffering, !showsControls, mpv.failure == nil {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if mpv.failure != nil || (stalled && !mpv.loaded) {
                problem.allowsHitTesting(false)
            }
            controls.opacity(showsControls ? 1 : 0).allowsHitTesting(showsControls)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task { await prepare() }
        .task(id: mpv.paused) {
            // Your place, saved every 15 seconds while it plays.
            guard ready else { return }
            while !Task.isCancelled, !mpv.paused {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                savePlace(); report("progress")
            }
        }
        .onChange(of: mpv.loaded) { _, loaded in if loaded { report("start"); scheduleHide() } }
        .onChange(of: mpv.paused) { _, _ in report("progress") }
        .onChange(of: mpv.time) { _, now in reachedEnd(now) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { mpv.pause(); mpv.showVideo(false) }
            if phase == .active { mpv.showVideo(true) }
        }
        .onAppear {
            refresh.hold(smoothMotion)
            UIApplication.shared.isIdleTimerDisabled = true
            JellyMusic.shared.pause()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let upright = (playback.item.Height ?? 0) > (playback.item.Width ?? 1)
            OrientationLock.set(upright ? .portrait : .landscape, turnTo: upright ? .portrait : .landscape)
        }
        .onDisappear {
            refresh.hold(0)
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            report("stop")
            savePlace()
            mpv.stop()
            if !switching { OrientationLock.set(.portrait, turnTo: .portrait) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        let compact = verticalSizeClass == .compact
        let side: CGFloat = compact ? 28 : 16
        let shown = scrub ?? mpv.time
        return ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                        Text("mpv").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close player")
                }
                .padding(.horizontal, side).padding(.top, 10)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    Slider(value: Binding(get: { scrub ?? mpv.time }, set: { scrub = $0 }), in: 0...max(1, mpv.duration),
                           onEditingChanged: { editing in
                               if editing { hideTask?.cancel() } else if let scrub { mpv.seek(to: scrub); self.scrub = nil; scheduleHide() }
                           })
                    .tint(.red)
                    Text("-" + JellyPlayerView.clock(max(0, mpv.duration - shown)))
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                .padding(.horizontal, side)
                HStack(spacing: compact ? 34 : 22) {
                    tracksMenu
                    speedMenu
                    decoderMenu
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 10).padding(.bottom, compact ? 10 : 18)
            }
            HStack(spacing: compact ? 90 : 56) {
                Button { mpv.skip(-15); scheduleHide() } label: { Image(systemName: "gobackward.15").font(.system(size: 34, weight: .medium)) }
                    .accessibilityLabel("Back 15 seconds")
                Button { mpv.togglePause(); scheduleHide() } label: {
                    Image(systemName: mpv.paused ? "play.fill" : "pause.fill").font(.system(size: 48)).frame(width: 64, height: 64)
                }
                .accessibilityLabel(mpv.paused ? "Play" : "Pause")
                Button { mpv.skip(15); scheduleHide() } label: { Image(systemName: "goforward.15").font(.system(size: 34, weight: .medium)) }
                    .accessibilityLabel("On 15 seconds")
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.45), radius: 6)
    }

    private var tracksMenu: some View {
        Menu {
            Picker(selection: Binding(get: { mpv.subtitleID ?? -1 }, set: { mpv.selectSubtitle($0 < 0 ? nil : $0); scheduleHide() })) {
                Text("Off").tag(-1)
                ForEach(mpv.subtitleTracks) { Text($0.label).tag($0.id) }
            } label: { Text("Subtitles") }.pickerStyle(.inline)
            if mpv.audioTracks.count > 1 {
                Picker(selection: Binding(get: { mpv.audioID ?? -1 }, set: { mpv.selectAudio($0); scheduleHide() })) {
                    ForEach(mpv.audioTracks) { Text($0.label).tag($0.id) }
                } label: { Text("Audio") }.pickerStyle(.inline)
            }
        } label: {
            Label("Audio & Subtitles", systemImage: "captions.bubble")
        }
        .menuIndicator(.hidden)
        .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
    }

    private var speedMenu: some View {
        Menu {
            Picker(selection: Binding(get: { mpv.speed }, set: { mpv.setSpeed($0); scheduleHide() })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(JellyPlayerView.speedName(Float($0))).tag($0) }
            } label: { Text("Speed") }.pickerStyle(.inline)
        } label: {
            Label("Speed (" + JellyPlayerView.speedName(Float(mpv.speed)) + ")", systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuIndicator(.hidden)
        .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
    }

    private var decoderMenu: some View {
        Menu {
            Picker(selection: Binding(get: { smoothMotion }, set: { rate in
                smoothMotion = rate
                mpv.setSmooth(rate)
                refresh.hold(rate)
                scheduleHide()
            })) {
                Text("Off").tag(0)
                Text("60 Hz").tag(60)
                Text("120 Hz").tag(120)
            } label: { Label("Smooth motion", systemImage: "wand.and.sparkles") }.pickerStyle(.menu)
            Picker(selection: Binding(get: { JellyDecoder.mpv }, set: { choice in
                guard choice != .mpv else { return }
                switching = true
                toEngine(mpv.time)
            })) {
                ForEach(JellyDecoder.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: { Label("Decoder", systemImage: "cpu") }.pickerStyle(.menu)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
    }

    /// What went wrong, in mpv's words, with its latest warnings and errors.
    private var problem: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mpv.failure ?? "Still opening…").font(.system(size: 14, weight: .semibold))
            ForEach(Array(mpv.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !mpv.paused, scrub == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
        }
    }

    // MARK: Jellyfin

    /// Where to start and the separate subtitle files, then the picture.
    private func prepare() async {
        let client = playback.client, id = playback.id
        let user = await JellyfinUser.id(client)
        userID = user
        if let startAt {
            start = startAt
        } else if resumeOn, let user, let data = try? await client.userData(id, user: user), let ticks = data.PlaybackPositionTicks, ticks > 0 {
            start = Double(ticks) / 10_000_000
        }
        let info = try? await client.playerInfo(id, user: user)
        subtitles = JellyPlayerView.subtitleFiles(info, source: playback.source, item: id, client: client)
        ready = true
        try? await Task.sleep(for: .seconds(10))
        stalled = true
    }

    private func savePlace() {
        guard let user = userID, mpv.time > 5, !(finished && mpv.time >= mpv.duration * 0.9) else { return }
        let client = playback.client, id = playback.id, at = mpv.time
        Task { try? await client.savePosition(id, user: user, seconds: at) }
    }

    private func report(_ event: String) {
        guard JellyAccount.token != nil else { return }
        let client = playback.client, id = playback.id, source = playback.source, at = mpv.time, paused = mpv.paused
        Task { await client.report(event, item: id, source: source, seconds: at, paused: paused) }
    }

    private func reachedEnd(_ seconds: Double) {
        guard !finished, mpv.duration > 60, seconds >= mpv.duration * 0.9 else { return }
        finished = true
        let client = playback.client, id = playback.id, user = userID, item = playback.item, diaryStore = store, diary = diaryOn
        Task {
            if let user {
                try? await client.markPlayed(id, user: user)
                try? await client.savePosition(id, user: user, seconds: 0)
            }
            if diary { _ = await JellyDiary.mark(item, client: client, store: diaryStore) }
        }
    }
}
