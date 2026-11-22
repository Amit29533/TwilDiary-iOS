import os
import SwiftUI
import UIKit
import AVFoundation
import VideoToolbox
import AetherEngine
import MPVKitAV

// MARK: Which engine a video plays on

/// The engine each video opens on: the default (Settings → JellySpace → Engines), unless you moved
/// that video to the other one (More → Decoder), which it then keeps. Only videos that differ from
/// the default are listed.
enum JellyMPVChoice {
    private static let mpvKey = "jellyspace.mpvItems"
    private static let appKey = "jellyspace.appItems"
    static func isOn(_ id: String) -> Bool {
        let defaults = UserDefaults.standard
        if (defaults.stringArray(forKey: mpvKey) ?? []).contains(id) { return true }
        if (defaults.stringArray(forKey: appKey) ?? []).contains(id) { return false }
        return JellyDecoder.preferred == .mpv
    }
    static func set(_ id: String, _ on: Bool) {
        let byDefault = JellyDecoder.preferred == .mpv
        update(mpvKey) { ids in if on && !byDefault { ids.insert(id) } else { ids.remove(id) } }
        update(appKey) { ids in if !on && byDefault { ids.insert(id) } else { ids.remove(id) } }
    }
    /// How many videos keep an engine of their own.
    static var count: Int {
        let defaults = UserDefaults.standard
        return (defaults.stringArray(forKey: mpvKey) ?? []).count + (defaults.stringArray(forKey: appKey) ?? []).count
    }
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: mpvKey)
        UserDefaults.standard.removeObject(forKey: appKey)
    }
    private static func update(_ key: String, _ change: (inout Set<String>) -> Void) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let before = ids
        change(&ids)
        guard ids != before else { return }
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
    /// The default engine (Settings → JellySpace → Engines).
    static var preferred: JellyDecoder { JellyDecoder(rawValue: UserDefaults.standard.string(forKey: JellyPrefs.engineKey) ?? "") ?? .auto }
}

// MARK: mpv

/// What the event thread hands to the main actor.
private enum JellyMPVChange: Sendable {
    case time(Double), duration(Double), paused(Bool), buffering(Bool), ended(Bool)
    case width(Int), height(Int)
    case tracks(audio: [TrackInfo], subtitles: [TrackInfo], aid: Int?, sid: Int?)
    case subtitleText(String)
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
    /// The subtitle line showing now, as plain text (for translating it).
    @Published private(set) var subtitleText = ""
    /// While subtitles are translated: mpv draws its text see-through (picture subtitles still show).
    private var hidesText = false
    /// Whether mpv sends its subtitle lines as text (sub-text): only while a translation language is
    /// chosen, as reading them out costs work on every line (measured with styled subtitles).
    var watchesText = false {
        didSet { if watchesText != oldValue { applyTextWatch() } }
    }
    /// sub-text's own observation id (the others share 0), so it can be stopped on its own.
    private static let textWatch: UInt64 = 1
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
    /// Subtitles composited into the frames unless set otherwise (Engines → Subtitles in the picture):
    /// on a phone; the Simulator has no VideoToolbox for it.
    #if targetEnvironment(simulator)
    nonisolated static let compositesByDefault = false
    #else
    nonisolated static let compositesByDefault = true
    #endif
    /// The file has opened (its first frame or its length came).
    var hasLoaded: Bool { loaded }
    /// mpv's last warning or error, if any.
    var lastMessage: String? { log.last }
    /// Where mpv is, for the log when it doesn't start.
    var diagnosis: String { "handle \(handle != nil), pending \(pending != nil), loaded \(loaded), state \(state)" }
    /// mpv's lifecycle in the system log (Console, or `log show --predicate 'subsystem == "com.amit29533.TwilDiary.mpv"'`).
    nonisolated static let log = Logger(subsystem: "com.amit29533.TwilDiary.mpv", category: "player")

    /// The picture's layer when mpv shows frames through AVFoundation (nil: drawn on the GPU).
    private weak var sampleLayer: AVSampleBufferDisplayLayer?
    /// Watches that layer for a failure (a black picture) to recover from.
    private var layerWatch: NSKeyValueObservation?
    /// Super Resolution's shaders ("off", "fsr", "anime"), used whenever mpv is on the GPU output.
    private var superResolution = "off"
    /// Recoveries tried for this video (at most three; see resetDecoder).
    private var decoderResets = 0
    private static let maxDecoderResets = 3
    /// Standard definition through the deinterlacing filter (see updateDeinterlace).
    private var deinterlacing = false
    /// VideoToolbox's decoder now: zero-copy, or (for the deinterlacing filter) copying.
    private var hardwareDecoder: String { deinterlacing ? "videotoolbox-copy" : "videotoolbox" }

    /// The codecs this phone decodes in hardware, asked of VideoToolbox once (as IINA does): an AV1
    /// file on a phone without AV1 hardware goes straight to software instead of failing in
    /// hardware first (a black flash and a decoder reset). Codecs it can't ask about stay in. In the
    /// Simulator (no hardware decoding at all) it stays "all", as before.
    private static let hardwareCodecs: String = {
        let asked: [(String, [CMVideoCodecType])] = [
            ("h264", [kCMVideoCodecType_H264]), ("hevc", [kCMVideoCodecType_HEVC]), ("av1", [kCMVideoCodecType_AV1]),
            ("vp9", [kCMVideoCodecType_VP9]), ("mpeg2video", [kCMVideoCodecType_MPEG2Video]), ("mpeg4", [kCMVideoCodecType_MPEG4Video]),
            ("prores", [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444]),
        ]
        let supported = asked.filter { $0.1.contains(where: VTIsHardwareDecodeSupported) }.map(\.0)
        guard !supported.isEmpty else { return "all" }
        return (supported + ["mpeg1video", "vc1", "wmv3"]).joined(separator: ",")
    }()

    /// mpv on this layer (an AVSampleBufferDisplayLayer, or a Metal layer for smooth motion); a
    /// file asked for already is loaded now.
    func start(layer: CALayer, smooth: Int) {
        Self.log.notice("start: layer \(layer is CAMetalLayer ? "metal" : "sample", privacy: .public), handle \(self.handle != nil), pending \(self.pending != nil)")
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
        // composited into the frames on a device, as Streamyfin ships it (they show in Picture in
        // Picture too; the player keeps this output to fitted pictures, so they aren't cropped). The
        // Simulator has no VideoToolbox for that, so an overlay there. `jellyspace.mpv.compositeOSD`
        // overrides it (the performance run compares both).
        let defaults = UserDefaults.standard
        let composite = defaults.object(forKey: JellyPrefs.mpvCompositeKey) != nil ? defaults.bool(forKey: JellyPrefs.mpvCompositeKey) : Self.compositesByDefault
        let output: [(String, String)] = sample != nil
            ? [("vo", "avfoundation"), ("avfoundation-composite-osd", composite ? "yes" : "no"), ("hwdec", "videotoolbox")]
            : [("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox")]
        let options: [(String, String)] = output + [
            ("hwdec-codecs", Self.hardwareCodecs), ("keep-open", "yes"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"),
            ("sub-auto", "no"), ("subs-fallback", "yes"), ("audio-display", "no"),
            // Arabic and Hebrew lines in styled subtitles in the order their authors' tools showed them
            // (Streamyfin sets it).
            ("sub-vsfilter-bidi-compat", "yes"),
            // Streamyfin's defaults: 10 seconds ahead, within 150 MB ahead and 50 MB behind. The cache
            // stays on outright, as before: Streamyfin's "auto" means on for network streams, and ours
            // comes through the app's own reader, not mpv's network code.
            ("cache", "yes"), ("cache-secs", "10"), ("demuxer-max-bytes", "150MiB"), ("demuxer-max-back-bytes", "50MiB"),
            // Behind, frames are dropped at the decoder first (lighter), then at the output.
            ("framedrop", "decoder+vo"),
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
        if watchesText { mpv_observe_property(raw, Self.textWatch, "sub-text", MPV_FORMAT_STRING) }
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
        Self.log.notice("open: \(self.handle == nil ? "waits for the picture" : "loads now", privacy: .public)")
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
        // The last file's deinterlacing off first: the filter and decoder mode outlive a loadfile, and
        // the filter can't take the next file's zero-copy frames (mpv would drop it with errors).
        if deinterlacing {
            deinterlacing = false
            set("vf", "")
            set("hwdec", hardwareDecoder)
        }
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
        Self.log.notice("stop: handle \(self.handle != nil), pending \(self.pending != nil)")
        pending = nil
        loaded = false
        let stopping = handle
        handle = nil
        layerWatch?.invalidate()
        layerWatch = nil
        sampleLayer = nil
        updateState()
        // After everything already sent (the same queue); the event thread frees mpv once it has quit.
        if let stopping { Self.calls.async { mpv_command_string(stopping.raw, "quit") } }
    }

    func play() { set("pause", "no") }

    /// mpv's GPU output sets its own drawing size as it starts. Turned sideways before that, the
    /// layout had already passed and it stayed at the upright size: the picture drew only the left
    /// part of the screen (now and then; fine after a restart). Once the video's size is known (mpv's
    /// output is up), the drawable is checked against the layer again, then twice more as it settles.
    private func fitGPUOutput() {
        guard handle?.layer is CAMetalLayer else { return }
        Task { @MainActor [weak self] in
            for delay in [0, 500, 1500] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard let layer = self?.handle?.layer as? CAMetalLayer else { return }
                JellyMPVSurfaceView.fit(layer)
            }
        }
    }

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
        if decoderResets < Self.maxDecoderResets { set("hwdec", hardwareDecoder) }
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
        if hidesText { hideText() }
    }
    /// Subtitles translated: mpv keeps reading its lines (sub-text) but draws them see-through, and the
    /// player draws the translation in their place. Off: the look back.
    func setTextHidden(_ hidden: Bool, look: JellySubtitleLook) {
        guard hidden != hidesText else { return }
        hidesText = hidden
        setSubtitleLook(look)
    }
    /// Standard definition (576 lines or fewer: DVDs, TV recordings) is deinterlaced, as Streamyfin
    /// does it: mpv's AVFoundation output shows what the decoder gives it, so interlaced video
    /// showed comb lines. The filter only touches frames marked interlaced (progressive video
    /// passes unchanged) and needs frames in memory, so VideoToolbox decodes in its copying mode for
    /// it, cheap at this size; anything bigger keeps zero-copy and no filter.
    private func updateDeinterlace(height: Int) {
        guard handle != nil, height > 0 else { return }
        let wanted = height <= 576
        guard wanted != deinterlacing else { return }
        deinterlacing = wanted
        // After the decoder resets gave up on hardware, software stays (its frames take the filter as
        // they are): only the filter changes then.
        let onHardware = decoderResets < Self.maxDecoderResets
        if wanted {
            // The copying decoder first: the filter can't take zero-copy frames.
            if onHardware { set("hwdec", hardwareDecoder) }
            set("vf", "lavfi=[bwdif=mode=send_frame:deint=interlaced]")
        } else {
            set("vf", "")
            if onHardware { set("hwdec", hardwareDecoder) }
        }
    }
    private func applyTextWatch() {
        guard let handle else { return }
        let watch = Self.textWatch
        if watchesText {
            Self.calls.async { mpv_observe_property(handle.raw, watch, "sub-text", MPV_FORMAT_STRING) }
        } else {
            Self.calls.async { _ = mpv_unobserve_property(handle.raw, watch) }
            if !subtitleText.isEmpty { subtitleText = "" }
        }
    }
    private func hideText() {
        for (name, value) in [("sub-color", "#00000000"), ("sub-border-color", "#00000000"), ("sub-shadow-offset", "0"),
                              ("sub-back-color", "#00000000"), ("sub-ass-override", "force")] { set(name, value) }
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

    /// Every call into a running mpv goes through this queue, in order and off the main thread, as
    /// Streamyfin's player sends them. mpv's AVFoundation output sets its layer up on the main thread
    /// as a video starts; a call made from the main thread at that moment waited on mpv while mpv
    /// waited on the main thread: the player froze on its spinner (now and then, at 0% CPU).
    nonisolated private static let calls = DispatchQueue(label: "twildiary.jellyspace.mpv", qos: .userInitiated)

    private func set(_ name: String, _ value: String) {
        guard let handle else { return }
        Self.calls.async { mpv_set_property_string(handle.raw, name, value) }
    }

    private func command(_ args: [String]) {
        guard let handle else { return }
        Self.calls.async {
            var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
            defer { for pointer in cargs { free(UnsafeMutablePointer(mutating: pointer)) } }
            mpv_command(handle.raw, &cargs)
        }
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
        case .height(let value):
            if videoSize.height != CGFloat(value) { videoSize.height = CGFloat(value) }
            updateDeinterlace(height: value)
            fitGPUOutput()
        case .tracks(let audio, let subtitles, let aid, let sid):
            if audio.map(\.id) != audioTracks.map(\.id) { audioTracks = audio }
            if subtitles.map(\.id) != subtitleTracks.map(\.id) { subtitleTracks = subtitles }
            if aid != audioID { audioID = aid }
            if sid != subtitleID { subtitleID = sid }
        case .subtitleText(let text):
            if text != subtitleText { subtitleText = text }
        case .log(let line):
            log = Array((log + [line]).suffix(4))
            // mpv's warnings and errors in the phone's log too (Console), for a video it can't play.
            Self.log.notice("mpv: \(line, privacy: .public)")
        case .failed(let reason):
            failure = ([reason] + log.suffix(1)).joined(separator: "\n")
        case .loaded:
            loaded = true; buffering = false
            updateState()
            if hidesText { hideText() }
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
                    let string = property.format == MPV_FORMAT_STRING
                        ? property.data?.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self).pointee.map { String(cString: $0) } : nil
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
                    case "sub-text": change = .subtitleText(string ?? "")
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
    /// The pieces fetched last, most recently read last. One piece at a time wasn't enough: in a file
    /// whose audio and video lie far apart, mpv reads from two places in turn, and every turn fetched
    /// 4 MB again for a few kilobytes: the video never started (nothing loaded ahead on the bar)
    /// while AetherEngine, reading its own way, played it. Eight pieces (32 MB) hold both places.
    private var pieces: [(start: Int64, data: Data)] = []
    private static let keptPieces = 8
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    /// Opens it with its first piece (which also gives its length); nil when the server won't serve it.
    init?(url: URL) {
        self.url = url
        guard let first = fetch(from: 0) else { return nil }
        if !first.isEmpty { pieces = [(0, first)] }
    }

    func read(into out: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        if length >= 0, position >= length { return 0 }
        let piece: (start: Int64, data: Data)
        if let at = pieces.firstIndex(where: { position >= $0.start && position < $0.start + Int64($0.data.count) }) {
            piece = pieces.remove(at: at)
        } else {
            guard let data = fetch(from: position) else { return -1 }
            if data.isEmpty { return 0 }
            piece = (position, data)
        }
        pieces.append(piece)
        if pieces.count > Self.keptPieces { pieces.removeFirst() }
        let offset = Int(position - piece.start)
        let taken = min(Int(min(count, UInt64(Int.max))), piece.data.count - offset)
        piece.data.withUnsafeBytes { bytes in
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

    /// The piece starting here (empty past the end); nil when it couldn't be had.
    private func fetch(from start: Int64) -> Data? {
        lock.lock()
        let stop = cancelled
        lock.unlock()
        if stop { return nil }
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
            if let response = result.response, response.statusCode == 416 { return Data() }
            return nil
        }
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            length = total
        }
        return data
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
    /// The drawable follows the view's size. It's set once as mpv starts, and once MoltenVK has set it
    /// iOS stops following the view: turned sideways after opening, mpv drew at the upright width in
    /// a corner. A new size here makes mpv build its output again at that size.
    override func layoutSubviews() {
        super.layoutSubviews()
        if let layer = layer as? CAMetalLayer { Self.fit(layer) }
    }
    /// The drawable at the layer's size in pixels (a no-op when it already is).
    static func fit(_ layer: CAMetalLayer) {
        let size = CGSize(width: (layer.bounds.width * layer.contentsScale).rounded(), height: (layer.bounds.height * layer.contentsScale).rounded())
        if size.width > 1, size.height > 1, size != layer.drawableSize { layer.drawableSize = size }
    }
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
