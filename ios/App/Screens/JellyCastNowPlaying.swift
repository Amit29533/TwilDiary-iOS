import AVFoundation
import MediaPlayer
import UIKit

/// Casting on the lock screen, in Control Center and in the Dynamic Island: the TV's video as iOS's Now
/// Playing card (poster, name, the show and the TV, the bar), its buttons working the TV. iOS gives that
/// card only to an app that plays sound, and casting plays none on the phone ("Not Playing" while a video
/// played on the TV), so while it casts the app plays silence; that also keeps it, and its line to the TV,
/// awake in the background. The buttons are set up as JellyMPVSystem sets them for the phone's own player
/// (Streamyfin's way).
@MainActor final class JellyCastNowPlaying {
    /// What the card shows.
    struct Card: Equatable {
        var title: String
        var subtitle: String
        var duration: Double
        var position: Double
        var paused: Bool
        var artwork: URL?
    }
    /// What the buttons do on the TV.
    struct Actions {
        /// true plays, false pauses, nil switches.
        let play: @MainActor (Bool?) -> Void
        let seek: @MainActor (Double) -> Void
        let position: @MainActor () -> Double
        let next: @MainActor () -> Void
    }
    private var actions: Actions?
    private var card: Card?
    private var silence: AVAudioPlayer?
    private var picture: (url: URL, artwork: MPMediaItemArtwork)?
    private var loadingPicture: URL?
    private var targets: [(command: MPRemoteCommand, target: Any, wasEnabled: Bool)] = []
    private var observers: [NSObjectProtocol] = []

    var active: Bool { actions != nil }

    /// A video casts: the buttons go to the TV and the silence starts (once; later calls change nothing).
    func begin(_ actions: Actions) {
        self.actions = actions
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.playCommand) { cast, _ in cast.actions?.play(true) }
        add(center.pauseCommand) { cast, _ in cast.actions?.play(false) }
        add(center.togglePlayPauseCommand) { cast, _ in cast.actions?.play(nil) }
        add(center.skipForwardCommand) { cast, seconds in cast.move(seconds ?? 15) }
        add(center.skipBackwardCommand) { cast, seconds in cast.move(-(seconds ?? 15)) }
        add(center.changePlaybackPositionCommand) { cast, seconds in if let seconds { cast.go(to: seconds) } }
        add(center.nextTrackCommand) { cast, _ in cast.actions?.next() }
        // A call or an alarm stops the silence: on again after it, or the card would go.
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            Task { @MainActor in if ended, let self, self.active { self.silence?.play() } }
        })
        Task { [weak self] in
            await JellyAudioSession.activate()
            guard let self, self.active, self.silence == nil else { return }
            self.silence = Self.makeSilence()
            self.silence?.play()
            self.publish()
        }
    }

    /// What the TV plays now: the card follows (iOS counts the time on by itself between reports).
    func update(_ next: Card) {
        guard active, next != card else { return }
        card = next
        if let url = next.artwork, picture?.url != url, loadingPicture != url {
            loadingPicture = url
            Task { [weak self] in
                guard let image = await JellyfinPosterCache.shared.image(url), let self, self.loadingPicture == url else { return }
                self.loadingPicture = nil
                self.picture = (url, MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image })
                self.publish()
            }
        }
        publish()
    }

    /// Nothing casts any more: the card, the buttons and the silence go, and the sound is let go so music
    /// that was playing before carries on.
    func end() {
        guard active else { return }
        actions = nil; card = nil; picture = nil; loadingPicture = nil
        silence?.stop(); silence = nil
        for entry in targets {
            entry.command.removeTarget(entry.target)
            entry.command.isEnabled = entry.wasEnabled
        }
        targets = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !JellyMusic.shared.playing { JellyAudioSession.release() }
    }

    private func publish() {
        guard let card else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: card.title,
            MPMediaItemPropertyArtist: card.subtitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: card.position,
            MPNowPlayingInfoPropertyPlaybackRate: card.paused ? 0.0 : 1.0,
        ]
        if card.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = card.duration }
        if let picture { info[MPMediaItemPropertyArtwork] = picture.artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func move(_ seconds: Double) {
        guard let actions else { return }
        go(to: actions.position() + seconds)
    }
    /// Moved from the lock screen: the card says where it is now.
    private func go(to seconds: Double) {
        guard let actions else { return }
        let duration = card?.duration ?? 0
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        actions.seek(target)
        card?.position = target
        publish()
    }
    private func add(_ command: MPRemoteCommand, _ act: @escaping @MainActor @Sendable (JellyCastNowPlaying, Double?) -> Void) {
        let wasEnabled = command.isEnabled
        command.isEnabled = true
        let target = command.addTarget { @Sendable [weak self] event in
            // What the event carries, read before the hop (the event stays where it came in).
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            Task { @MainActor in
                if let self { act(self, seconds) }
            }
            return .success
        }
        targets.append((command, target, wasEnabled))
    }

    /// A second of silence (a WAV: 8 kHz, 16-bit, mono), played over and over.
    private static func makeSilence() -> AVAudioPlayer? {
        let rate: UInt32 = 8000
        let bytes = Int(rate) * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        data.append(Data(count: bytes))
        guard let player = try? AVAudioPlayer(data: data) else { return nil }
        player.numberOfLoops = -1
        player.prepareToPlay()
        return player
    }
}
