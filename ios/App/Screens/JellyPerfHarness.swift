import SwiftUI

/// For measuring playback (the Namespace performance run, `ios-namespace-perf.yml`): launched with
/// `--jellyspace-perf <video URL>`, the app opens the JellySpace player on that video at once, with no
/// Jellyfin server (its requests to the server fail quietly and the video plays on its own).
/// `--jellyspace-perf-mpv` plays it on mpv instead. Without the argument it does nothing.
struct JellyPerfHarness: ViewModifier {
    @State private var playback: JellyPlayback?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $playback) { JellyPlayerView(playback: $0) }
            .task { playback = Self.requested() }
    }

    static func requested() -> JellyPlayback? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "--jellyspace-perf"), arguments.indices.contains(at + 1),
              let url = URL(string: arguments[at + 1]), let scheme = url.scheme, let host = url.host(),
              let base = URL(string: "\(scheme)://\(host):\(url.port ?? 80)") else { return nil }
        let id = "jellyspace-perf"
        let json = #"{"Id":"\#(id)","Type":"Movie","Name":"Performance run"}"#
        guard let item = try? JSONDecoder().decode(JellyfinClient.Item.self, from: Data(json.utf8)) else { return nil }
        JellyMPVChoice.set(id, arguments.contains("--jellyspace-perf-mpv"))
        return JellyPlayback(id: id, url: url, title: "Performance run", item: item, client: JellyfinClient(base: base, key: "perf"))
    }
}
