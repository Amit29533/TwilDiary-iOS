import XCTest
import UIKit
@testable import TwilDiary

/// How reliably a YouTube video starts in the app's own player (CinesPlayer, as a title page's cover
/// trailer uses it) on the Simulator's WebKit, under the app's own address (YouTube refuses an embed
/// that doesn't say whose it is). Runs only when asked (TEST_RUNNER_TRAILER_PROBE=1): it needs the
/// network and takes a few minutes. One line per attempt ("TRAILER-PROBE …") and a summary.
///
/// Two ways, each video several times:
/// - plain: a fresh player asked to play once, nothing else (how often YouTube starts by itself);
/// - app: the shared, ready player with the cover's help (asked again when YouTube reports the
///   video unstarted or cued, reloaded every 2.5 s up to five times).
@MainActor final class CinesTrailerStartProbe: XCTestCase {
    /// Embeddable videos: YouTube's own API sample, Big Buck Bunny, and two long-standing uploads.
    private static let videos = ["M7lc1UVf-VE", "aqz-KE-bpKQ", "dQw4w9WgXcQ", "jNQXAC9IVRw"]
    private static let rounds = 3
    private static let limit: TimeInterval = 16

    private struct Attempt { let mode: String; let video: String; let seconds: Double?; let refused: Bool; let reloads: Int }

    func testTrailersStartOnOneTap() async throws {
        guard ProcessInfo.processInfo.environment["TRAILER_PROBE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_TRAILER_PROBE=1 to run the trailer probe (network, minutes).")
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first else {
            throw XCTSkip("No window to show the player in.")
        }
        // The app's way: one player for every attempt, its page loaded ahead.
        let shared = CinesPlayer()
        shared.loops = false
        shared.keepsStarting = true
        shared.prepare()
        try await Task.sleep(for: .seconds(3))

        var attempts: [Attempt] = []
        for round in 1...Self.rounds {
            for video in Self.videos {
                for mode in ["plain", "app"] {
                    let player: CinesPlayer
                    if mode == "plain" {
                        player = CinesPlayer()
                        player.loops = false
                    } else {
                        player = shared
                    }
                    player.muted = true
                    player.unmutesOnStart = true
                    // On screen, as the cover shows it (media in a web view outside a window doesn't play).
                    let host = UIView(frame: CGRect(x: 0, y: 80, width: 390, height: 220))
                    window.addSubview(host)
                    player.web.frame = host.bounds
                    host.addSubview(player.web)

                    let start = Date.now
                    player.play(video)
                    var seconds: Double?
                    var reloads = 0
                    while Date.now.timeIntervalSince(start) < Self.limit {
                        try await Task.sleep(for: .milliseconds(100))
                        let elapsed = Date.now.timeIntervalSince(start)
                        if player.playing { seconds = elapsed; break }
                        if player.refused.contains(video) { break }
                        // The cover's retries: loaded again every 2.5 s, five times.
                        if mode == "app", reloads < 5, elapsed >= 2.5 * Double(reloads + 1) {
                            player.reload()
                            reloads += 1
                        }
                    }
                    let refused = player.refused.contains(video)
                    let attempt = Attempt(mode: mode, video: video, seconds: seconds, refused: refused, reloads: reloads)
                    attempts.append(attempt)
                    print("TRAILER-PROBE round \(round) \(mode) \(video): "
                          + (seconds.map { String(format: "started in %.1f s", $0) } ?? (refused ? "refused by YouTube" : "did not start"))
                          + " reloads \(reloads)")
                    player.stop()
                    player.web.removeFromSuperview()
                    host.removeFromSuperview()
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        func summary(_ mode: String) -> (started: Int, total: Int, firstTry: Int, median: Double?) {
            let mine = attempts.filter { $0.mode == mode && !$0.refused }
            let times = mine.compactMap(\.seconds).sorted()
            return (times.count, mine.count, mine.filter { $0.seconds != nil && $0.reloads == 0 }.count,
                    times.isEmpty ? nil : times[times.count / 2])
        }
        for mode in ["plain", "app"] {
            let result = summary(mode)
            print("TRAILER-PROBE SUMMARY \(mode): started \(result.started) of \(result.total)"
                  + ", without a reload \(result.firstTry)"
                  + (result.median.map { String(format: ", median %.1f s", $0) } ?? ""))
        }
        let plain = summary("plain"), app = summary("app")
        XCTAssertGreaterThanOrEqual(app.started * max(1, plain.total), plain.started * max(1, app.total),
                                    "The cover's way started fewer videos than asking once")
        XCTAssertGreaterThan(app.total, 0, "Every video was refused: YouTube didn't accept the embed")
    }
}
