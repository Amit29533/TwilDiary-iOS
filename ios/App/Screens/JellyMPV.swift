import SwiftUI
import UIKit
import AVFoundation
import AetherEngine
import MPVKitAV

// MARK: Which engine a video plays on

/// Videos you've moved to mpv (More → Decoder → mpv) open on it from then on.
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

// MARK: mpv

/// What the event thread hands to the main actor.
private enum JellyMPVChange: Sendable {
    case time(Double), duration(Double), paused(Bool), buffering(Bool), ended(Bool)
    case width(Int), height(Int)
    case tracks(audio: [TrackInfo], subtitles: [TrackInfo], aid: Int?, sid: Int?)
    case loaded
    case log(String), failed(String)
}

/// mpv's handle, for the event thread (its client API may be called from any thread).
private struct JellyMPVHandle: @unchecked Sendable {
    let raw: OpaquePointer
    /// The layer mpv draws into, held until mpv has shut down: vo_avfoundation doesn't retain it, and
    /// the view can go before mpv's last frame does.
    let layer: CALayer?
}

/// libmpv as the player's second engine: the file, its clock, its tracks (as AetherEngine's
/// TrackInfo, so the player's menus and remembered languages work as they are). The picture goes
/// to an AVSampleBufferDisplayLayer (vo_avfoundation: VideoToolbox's frames shown as they are, as
/// AVPlayer and AetherEngine show video), or, with smooth motion on, is drawn through Vulkan into a
/// Metal layer (gpu-next, which can blend frames). Events are read on a thread of their own and
/// published on the main actor. mpv draws the subtitles itself.
@MainActor final class JellyMPV: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var buffering = false
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var audioID: Int?
    @Published private(set) var subtitleID: Int?
    @Published private(set) var videoSize = CGSize.zero
    /// Why the video didn't open, in mpv's words (with its latest warning or error).
    @Published private(set) var failure: String?

    private var handle: JellyMPVHandle?
    private var loaded = false, paused = false, ended = false
    private var log: [String] = []
    /// A file asked for before the picture was up; loaded once it is.
    private var pending: (url: URL, start: Double?, subtitles: [ExternalSubtitleTrack], settings: [(String, String)])?
    /// Jellyfin's separate subtitle files, added once the video has opened.
    private var pendingSubtitles: [ExternalSubtitleTrack] = []

    var running: Bool { handle != nil }

    /// The picture's layer when mpv shows frames through AVFoundation (nil: drawn on the GPU).
    private weak var sampleLayer: AVSampleBufferDisplayLayer?
    /// Watches that layer for a failure (a black picture) to recover from.
    private var layerWatch: NSKeyValueObservation?
    /// Super Resolution's shaders ("off", "fsr", "anime"), used whenever mpv is on the GPU output.
    private var superResolution = "off"
    /// Recoveries tried for this video (at most three; see resetDecoder).
    private var decoderResets = 0
    private static let maxDecoderResets = 3

    /// mpv on this layer (an AVSampleBufferDisplayLayer, or a Metal layer for smooth motion); a
    /// file asked for already is loaded now.
    func start(layer: CALayer, smooth: Int) {
        guard handle == nil else { return }
        guard let raw = mpv_create() else { failure = "mpv couldn't be created."; return }
        mpv_request_log_messages(raw, "warn")
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(raw, "wid", MPV_FORMAT_INT64, &wid)
        let sample = layer as? AVSampleBufferDisplayLayer
        sampleLayer = sample
        // The layer's renderer reports a failure (since iOS 18 the status is the renderer's), from
        // whichever thread it's on: back to the main actor to act.
        layerWatch = sample?.sampleBufferRenderer.observe(\.status, options: [.new]) { @Sendable [weak self] renderer, _ in
            guard renderer.status == .failed else { return }
            Task { @MainActor in self?.resetDecoder() }
        }
        // AVFoundation: the decoded frames go to the display layer untouched, with no GPU pass per
        // frame. Its options straight after vo, where Streamyfin found they must be. The subtitles
        // as an overlay of their own (composited into the frames they'd be cropped in Fill), or
        // composited (`jellyspace.mpv.compositeOSD`, which the performance run compares: the overlay
        // didn't show in the Simulator).
        let composite = UserDefaults.standard.bool(forKey: "jellyspace.mpv.compositeOSD")
        let output: [(String, String)] = sample != nil
            ? [("vo", "avfoundation"), ("avfoundation-composite-osd", composite ? "yes" : "no"), ("hwdec", "videotoolbox")]
            : [("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox")]
        let options: [(String, String)] = output + [
            ("hwdec-codecs", "all"), ("keep-open", "yes"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"),
            ("sub-auto", "no"), ("subs-fallback", "yes"), ("audio-display", "no"),
            ("cache", "yes"), ("demuxer-max-bytes", "150MiB"), ("demuxer-readahead-secs", "20"),
            // On the GPU (smooth motion), lighter drawing than mpv's defaults, which are made for a
            // desktop GPU: spline36 for the picture (sharp, one pass), bilinear for colour, and none of
            // the extra passes (linear light, sigmoid, HDR peak measuring each frame, debanding). On a
            // phone's dense screen they look the same. A decoder that can't use VideoToolbox falls
            // back to software rather than failing.
            ("scale", "spline36"), ("dscale", "mitchell"), ("cscale", "bilinear"),
            ("correct-downscaling", "no"), ("linear-downscaling", "no"), ("sigmoid-upscaling", "no"),
            ("hdr-compute-peak", "no"), ("deband", "no"), ("hwdec-software-fallback", "yes"),
        ]
        for (name, value) in options { mpv_set_option_string(raw, name, value) }
        if sample == nil {
            for (name, value) in Self.smoothOptions(smooth, fps: videoFPS) { mpv_set_option_string(raw, name, value) }
            mpv_set_option_string(raw, "glsl-shaders", Self.shaders(superResolution))
        }
        Self.prepareFonts(raw)
        let started = mpv_initialize(raw)
        guard started >= 0 else {
            failure = "mpv didn't start: " + String(cString: mpv_error_string(started))
            mpv_terminate_destroy(raw)
            return
        }
        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
            ("width", MPV_FORMAT_INT64), ("height", MPV_FORMAT_INT64),
            ("track-list", MPV_FORMAT_NONE), ("aid", MPV_FORMAT_NONE), ("sid", MPV_FORMAT_NONE),
        ]
        for (name, format) in observed { mpv_observe_property(raw, 0, name, format) }
        Self.addJellyfinProtocol(raw)
        let handle = JellyMPVHandle(raw: raw, layer: layer)
        self.handle = handle
        Self.readEvents(handle) { [weak self] change in self?.apply(change) }
        if let pending {
            self.pending = nil
            load(pending.url, start: pending.start, subtitles: pending.subtitles, settings: pending.settings)
        }
    }

    /// Plays this file (from `start` seconds) with these mpv settings, now or once the picture is up.
    func open(_ url: URL, start: Double?, subtitles: [ExternalSubtitleTrack], settings: [(String, String)]) {
        if handle == nil {
            pending = (url, start, subtitles, settings)
            updateState()
        } else {
            load(url, start: start, subtitles: subtitles, settings: settings)
        }
    }

    private func load(_ url: URL, start: Double?, subtitles: [ExternalSubtitleTrack], settings: [(String, String)]) {
        loaded = false; ended = false; paused = false; failure = nil; log = []
        decoderResets = 0
        time = start ?? 0; duration = 0; audioTracks = []; subtitleTracks = []; audioID = nil; subtitleID = nil
        pendingSubtitles = subtitles
        updateState()
        for (name, value) in settings { set(name, value) }
        layerZooms()
        set("pause", "no")
        var command = ["loadfile", JellyMPVStream.scheme + url.absoluteString, "replace"]
        if let start, start > 1 { command += ["-1", "start=\(start)"] }
        self.command(command)
    }

    /// Closes the file and mpv; the event thread frees it once it has shut down.
    func stop() {
        pending = nil
        loaded = false
        let raw = handle?.raw
        handle = nil
        layerWatch?.invalidate()
        layerWatch = nil
        sampleLayer = nil
        updateState()
        if let raw { mpv_command_string(raw, "quit") }
    }

    func play() { set("pause", "no") }

    /// The video layer failed (the picture goes black): iOS ends VideoToolbox sessions when the app
    /// goes to the background or memory runs short, and a codec the phone can't decode in hardware
    /// fails it at once. The decoder goes to software and back to VideoToolbox, which builds a new
    /// one. At most three times a video, as Streamyfin found: where hardware can't take the codec
    /// at all, the last try stays on software, which plays (more slowly) instead of failing again
    /// and again.
    private func resetDecoder() {
        guard handle != nil else { return }
        decoderResets += 1
        guard decoderResets <= Self.maxDecoderResets else { return }
        set("hwdec", "no")
        if decoderResets < Self.maxDecoderResets { set("hwdec", "videotoolbox") }
    }

    /// Fallback fonts for the subtitles, from the app (Noto: Latin, Greek and Cyrillic, Arabic,
    /// Hebrew, Devanagari, and Chinese, Japanese and Korean). libass asks iOS for a font that has a
    /// missing letter and then opens it as a file, but since iOS 18 the system's Chinese, Japanese and
    /// Korean font is where apps can't read it, so those letters showed as boxes (Streamyfin #1789).
    /// The fonts go in mpv's config folder: fonts/ (checked letter by letter) and subfont.ttf (the
    /// last resort, the CJK font). Links, not copies, made again when an update moves the app.
    nonisolated private static func prepareFonts(_ raw: OpaquePointer) {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let config = support.appending(path: "mpv", directoryHint: .isDirectory)
        let fonts = config.appending(path: "fonts", directoryHint: .isDirectory)
        guard (try? manager.createDirectory(at: fonts, withIntermediateDirectories: true)) != nil else { return }
        func link(_ name: String, _ kind: String, at target: URL) {
            guard let source = Bundle.main.url(forResource: name, withExtension: kind) else { return }
            let wanted = source.path(percentEncoded: false)
            if (try? manager.destinationOfSymbolicLink(atPath: target.path(percentEncoded: false))) == wanted { return }
            try? manager.removeItem(at: target)
            try? manager.createSymbolicLink(atPath: target.path(percentEncoded: false), withDestinationPath: wanted)
        }
        for name in ["NotoSans-Regular", "NotoSansArabic-Regular", "NotoSansHebrew-Regular", "NotoSansDevanagari-Regular"] {
            link(name, "ttf", at: fonts.appending(path: name + ".ttf"))
        }
        link("NotoSansCJKsc-Regular", "otf", at: config.appending(path: "subfont.ttf"))
        mpv_set_option_string(raw, "config", "yes")
        mpv_set_option_string(raw, "config-dir", config.path(percentEncoded: false))
    }
    func pause() { set("pause", "yes") }
    func seek(to seconds: Double) { command(["seek", String(max(0, seconds)), "absolute"]) }
    func setRate(_ value: Float) { set("speed", String(value)) }
    /// 0 to 1, as AetherEngine's volume (the sleep timer's fade).
    func setVolume(_ value: Float) { set("volume", String(Int((max(0, min(1, value)) * 100).rounded()))) }
    func selectAudio(_ id: Int) { set("aid", String(id)) }
    func selectSubtitle(_ id: Int?) { set("sid", id.map(String.init) ?? "no") }
    func setAudioDelay(_ seconds: Double) { set("audio-delay", String(seconds)) }
    func setSubtitleDelay(_ seconds: Double) { set("sub-delay", String(seconds)) }
    /// A subtitle file found later (downloaded), added and shown.
    func addSubtitle(_ url: URL, name: String?, language: String?) {
        command(["sub-add", JellyMPVStream.scheme + url.absoluteString, "select", name ?? "Subtitles", language ?? ""])
    }
    /// Fit, Fill (cropped to the screen) or Original (one video pixel per screen pixel).
    func setFill(_ fill: JellyFill) {
        for (name, value) in Self.fillSettings(fill) { set(name, value) }
        // Through AVFoundation the layer itself fits or fills the picture.
        sampleLayer?.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
        layerZooms()
    }
    /// On AVFoundation the layer zooms, so mpv mustn't as well (the picture would fill twice over).
    private func layerZooms() {
        guard sampleLayer != nil else { return }
        set("panscan", "0.0")
        set("video-unscaled", "no")
    }
    nonisolated static func fillSettings(_ fill: JellyFill) -> [(String, String)] {
        // Filled, the picture is cropped top and bottom, and libass would place the subtitles on the
        // whole (uncropped) video, the bottom lines under the screen's edge. Given the screen's
        // margins it places them on what's shown instead, as Infuse does.
        [("video-unscaled", fill == .original ? "yes" : "no"), ("panscan", fill == .fill ? "1.0" : "0.0"),
         ("sub-ass-force-margins", fill == .fill ? "yes" : "no"), ("sub-use-margins", "yes")]
    }
    /// The subtitles' look from JellySpace's settings, mid-video (as the size changes in the player).
    func setSubtitleLook(_ look: JellySubtitleLook) {
        for (name, value) in look.mpvSettings { set(name, value) }
    }
    /// The picture off in the background (mpv's Metal layer can't draw there) and back.
    func showVideo(_ on: Bool) { set("vid", on ? "auto" : "no") }

    /// Smooth motion at 60 or 120 Hz (0 off): frames timed to the screen's refresh, so pans and
    /// handheld shots don't judder. Where the refresh is a whole multiple of the video's rate (120 Hz
    /// for 24 fps, 60 or 120 for 30 and 60) each frame simply holds for the same number of refreshes,
    /// judder-free with nothing to compute; only where it isn't (60 Hz for 24 fps) are frames blended,
    /// with the cheapest blend there is (oversample).
    func setSmooth(_ rate: Int, fps: Double = 0) {
        videoFPS = fps
        // Only the GPU output times frames to the screen; AVFoundation's layer does that itself.
        guard sampleLayer == nil else { return }
        for (name, value) in Self.smoothOptions(rate, fps: fps) { set(name, value) }
    }
    /// Super Resolution: AMD's FSR (light, any video) or Anime4K (line art: the same small network
    /// AetherEngine's line-art upscaling runs), as mpv user shaders. They need the GPU output, which
    /// the player moves mpv to while it's on; they run only where the picture is scaled up 1.2x or
    /// more (720p and below on a phone), so a 1080p video costs nothing extra.
    func setSuperResolution(_ mode: String) {
        superResolution = mode
        guard sampleLayer == nil else { return }
        set("glsl-shaders", Self.shaders(mode))
    }
    nonisolated static func shaders(_ mode: String) -> String {
        let names: [String] = switch mode {
        case "fsr": ["FSR"]
        case "anime": ["Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_S", "Anime4K_Upscale_CNN_x2_S"]
        default: []
        }
        return names.compactMap { Bundle.main.path(forResource: $0, ofType: "glsl") }.joined(separator: ":")
    }
    /// The video's frame rate as the server reports it (0: not known yet).
    private var videoFPS = 0.0
    nonisolated static func smoothOptions(_ rate: Int, fps: Double) -> [(String, String)] {
        guard rate > 0 else { return [("interpolation", "no"), ("video-sync", "audio")] }
        let ratio = fps > 1 ? Double(rate) / fps : 0
        // 23.976 fps at 120 Hz is 5.005 refreshes a frame: display-resample plays it 0.1% faster to fit.
        let whole = ratio >= 1 && abs(ratio - ratio.rounded()) < 0.02
        return [("display-fps-override", String(rate)), ("video-sync", "display-resample"),
                ("interpolation", whole ? "no" : "yes"), ("tscale", "oversample")]
    }

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

    private func updateState() {
        let now: PlaybackState
        if !loaded { now = handle == nil && pending == nil ? .idle : .loading }
        else if ended { now = .ended }
        else if paused { now = .paused }
        else { now = .playing }
        if now != state { state = now }
    }

    private func apply(_ change: JellyMPVChange) {
        switch change {
        case .time(let value): time = value
        case .duration(let value): duration = value
        case .paused(let value): paused = value; updateState()
        case .buffering(let value): buffering = value
        case .ended(let value): ended = value; updateState()
        case .width(let value): if videoSize.width != CGFloat(value) { videoSize.width = CGFloat(value) }
        case .height(let value): if videoSize.height != CGFloat(value) { videoSize.height = CGFloat(value) }
        case .tracks(let audio, let subtitles, let aid, let sid):
            if audio.map(\.id) != audioTracks.map(\.id) { audioTracks = audio }
            if subtitles.map(\.id) != subtitleTracks.map(\.id) { subtitleTracks = subtitles }
            if aid != audioID { audioID = aid }
            if sid != subtitleID { subtitleID = sid }
        case .log(let line):
            log = Array((log + [line]).suffix(4))
        case .failed(let reason):
            failure = ([reason] + log.suffix(1)).joined(separator: "\n")
        case .loaded:
            loaded = true; buffering = false
            updateState()
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
                    lastTime = -1
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
                    let integer = property.format == MPV_FORMAT_INT64 ? property.data.map { Int($0.assumingMemoryBound(to: Int64.self).pointee) } : nil
                    switch name {
                    case "time-pos":
                        // Ten times a second, as AetherEngine's clock.
                        if let number, abs(number - lastTime) >= 0.1 { lastTime = number; change = .time(number) }
                    case "duration": if let number { change = .duration(number) }
                    case "pause": if let flag { change = .paused(flag) }
                    case "paused-for-cache": if let flag { change = .buffering(flag) }
                    case "eof-reached": change = .ended(flag ?? false)
                    case "width": if let integer { change = .width(integer) }
                    case "height": if let integer { change = .height(integer) }
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
            // mpv is gone: the layer it drew into can go too (let go of on the main thread, as views are).
            DispatchQueue.main.async { withExtendedLifetime(handle) {} }
        }
        thread.name = "mpv events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The audio and subtitle tracks, read from mpv's track list.
    nonisolated private static func tracks(_ raw: OpaquePointer) -> JellyMPVChange {
        var audio: [TrackInfo] = [], subtitles: [TrackInfo] = []
        var aid: Int?, sid: Int?
        let count = int(raw, "track-list/count") ?? 0
        for index in 0..<count {
            let base = "track-list/\(index)/"
            guard let type = string(raw, base + "type"), let id = int(raw, base + "id") else { continue }
            let track = TrackInfo(id: id, name: string(raw, base + "title") ?? "", codec: string(raw, base + "codec") ?? "",
                                  language: string(raw, base + "lang"), channels: int(raw, base + "demux-channel-count") ?? 0,
                                  isDefault: string(raw, base + "default") == "yes", isForced: string(raw, base + "forced") == "yes",
                                  isExternal: string(raw, base + "external") == "yes")
            let selected = string(raw, base + "selected") == "yes"
            switch type {
            case "audio": audio.append(track); if selected { aid = id }
            case "sub": subtitles.append(track); if selected { sid = id }
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

/// The view AVFoundation shows mpv's frames in.
final class JellyMPVSampleView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

/// The picture: a view backed by an AVSampleBufferDisplayLayer (or, with smooth motion on, a Metal
/// layer), mpv started on it. A change between the two needs a new view and a new mpv: the player
/// gives the surface a new identity and opens the video again where it was.
struct JellyMPVSurface: UIViewRepresentable {
    let player: JellyMPV
    let smooth: Int
    /// The GPU output (smooth motion or Super Resolution on), else AVFoundation's.
    let gpu: Bool
    let fill: JellyFill
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> UIView {
        if gpu {
            let view = JellyMPVSurfaceView()
            view.backgroundColor = .black
            if let layer = view.layer as? CAMetalLayer {
                layer.contentsScale = displayScale
                layer.framebufferOnly = true
                layer.backgroundColor = UIColor.black.cgColor
                player.start(layer: layer, smooth: smooth)
            }
            return view
        }
        let view = JellyMPVSampleView()
        view.backgroundColor = .black
        if let layer = view.layer as? AVSampleBufferDisplayLayer {
            layer.backgroundColor = UIColor.black.cgColor
            layer.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
            player.start(layer: layer, smooth: 0)
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        (view.layer as? AVSampleBufferDisplayLayer)?.videoGravity = fill == .fill ? .resizeAspectFill : .resizeAspect
    }
}
