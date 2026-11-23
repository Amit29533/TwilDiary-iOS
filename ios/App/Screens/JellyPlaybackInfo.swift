import SwiftUI
import AetherEngine

/// Playback info, over the corner of the player: how the video is being played, for working out a
/// stutter. A view of its own, so its updates (about once a second) don't redraw the player.
struct JellyPlaybackInfo: View {
    @ObservedObject private var engine: AetherEngine
    @ObservedObject private var diagnostics: EngineDiagnostics
    /// The frame rate the server reports for the file, for when the engine hasn't read one.
    private let serverFrameRate: Double

    /// The dropped-frame total at each of the last ten telemetry ticks (about a second apart).
    @State private var droppedHistory: [Int] = []
    /// When the main thread was held up for longer than a tenth of a second, and for how long.
    @State private var stalls: [(at: ContinuousClock.Instant, ms: Int)] = []

    init(engine: AetherEngine, serverFrameRate: Double) {
        _engine = ObservedObject(wrappedValue: engine)
        _diagnostics = ObservedObject(wrappedValue: engine.diagnostics)
        self.serverFrameRate = serverFrameRate
    }

    var body: some View {
        let telemetry = diagnostics.liveTelemetry
        VStack(alignment: .leading, spacing: 3) {
            row("Route", routeName)
            row("Video", videoLine)
            row("Decoder", engine.activeVideoDecoder ?? "–")
            row("File", Self.fps(engine.sourceVideoFrameRate ?? (serverFrameRate > 0 ? serverFrameRate : nil)))
            row("Shown", Self.fps(telemetry?.observedFps))
            row("Dropped", droppedText(telemetry?.droppedFrameCount))
            row("Late", telemetry?.accumulatedFrameDelaySeconds.map { String(format: "%.2f s", $0) } ?? "–")
            row("Buffer", (telemetry?.forwardBufferSeconds ?? telemetry?.displayCushionSeconds).map { String(format: "%.1f s", $0) } ?? "–")
            row("Bitrate", Self.mbps(telemetry?.instantBitrateMbps))
            row("Network", Self.mbps(telemetry?.networkThroughputMbps))
            row("Main thread", stallText)
            row("Buffering", engine.isBuffering ? "Yes" : "No")
            row("Engine", AetherEngine.version)
        }
        .font(.app(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onReceive(diagnostics.$liveTelemetry) { telemetry in
            guard let dropped = telemetry?.droppedFrameCount else { return }
            droppedHistory.append(dropped)
            if droppedHistory.count > 11 { droppedHistory.removeFirst(droppedHistory.count - 11) }
        }
        .task {
            // The main thread's hold-ups: a 50 ms sleep that wakes much later means the main thread
            // was busy meanwhile (where the app's own decoder plays, that's when it misses frames).
            let step = Duration.milliseconds(50)
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                let now = ContinuousClock.now
                let late = now - last - step
                last = now
                if late > .milliseconds(100) { stalls.append((now, Int(late / .milliseconds(1)))) }
                // Only touched when something ages out, so a quiet main thread redraws nothing.
                if stalls.contains(where: { now - $0.at > .seconds(10) }) { stalls.removeAll { now - $0.at > .seconds(10) } }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(.white.opacity(0.6)).frame(width: 84, alignment: .leading)
            Text(value).lineLimit(1)
        }
    }

    private var routeName: String {
        switch engine.videoRoute {
        case .none: "–"
        case .remoteBypass: "Native (direct)"
        case .loopback: "Native"
        case .software: "Software"
        case .audio: "Audio only"
        }
    }

    private var videoLine: String {
        var parts: [String] = []
        if let codec = engine.sourceVideoCodecName { parts.append(codec.uppercased()) }
        if engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            parts.append("\(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)")
        }
        switch engine.videoFormat {
        case .sdr: parts.append("SDR")
        case .hdr10: parts.append("HDR10")
        case .hdr10Plus: parts.append("HDR10+")
        case .dolbyVision: parts.append("Dolby Vision")
        case .hlg: parts.append("HLG")
        }
        return parts.joined(separator: " ")
    }

    /// The session's total, and how many of those in the last ten seconds.
    private func droppedText(_ total: Int?) -> String {
        guard let total else { return "–" }
        guard let first = droppedHistory.first, droppedHistory.count > 1 else { return "\(total)" }
        return "\(total) (+\(max(0, total - first)) in 10 s)"
    }

    private var stallText: String {
        guard !stalls.isEmpty else { return "OK" }
        return "\(stalls.count) stalls in 10 s, worst \(stalls.map(\.ms).max() ?? 0) ms"
    }

    private static func fps(_ value: Double?) -> String {
        guard let value, value > 0 else { return "–" }
        return String(format: "%.3f fps", value)
    }
    private static func mbps(_ value: Double?) -> String {
        guard let value, value > 0 else { return "–" }
        return String(format: "%.1f Mbps", value)
    }
}
