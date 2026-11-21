import AVFoundation

/// The player's audio session, changed off the main thread. Each change is a round trip to the
/// audio server that usually takes milliseconds but sometimes seconds (Streamyfin saw its app freeze
/// for 2 to 8 seconds with it on the main thread), so the player never waits on it there. Changes
/// run in the order they were asked, on one queue.
enum JellyAudioSession {
    private static let queue = DispatchQueue(label: "twildiary.jellyspace.audio-session", qos: .userInitiated)

    /// Playback, as a film plays (on with the ringer off, on in the background); returns once it's
    /// applied, so mpv opens its sound after.
    static func activate() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playback, mode: .moviePlayback)
                try? session.setActive(true)
                done.resume()
            }
        }
    }

    /// The player closed: the session is let go, so music or a podcast that was playing before
    /// carries on (it was kept until the app quit).
    static func release() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
