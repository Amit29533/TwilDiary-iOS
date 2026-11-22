import AVFoundation
import MediaPlayer
import UIKit

/// mpv's place in the phone, which AetherEngine looks after itself: the lock screen's and Control
/// Center's card and buttons (AirPods' taps too), as Streamyfin sets them up; a pause when a call or an
/// alarm takes the sound, and on again after it when iOS says so, as Yattee does; a pause when the
/// headphones go, as Plezy does; and the screen kept on while it plays (mpv's GPU output, unlike a
/// video layer, doesn't keep it on by itself).
@MainActor final class JellyMPVSystem {
    /// What the buttons do.
    struct Actions {
        let play: @MainActor () -> Void
        let pause: @MainActor () -> Void
        let seek: @MainActor (Double) -> Void
        let position: @MainActor () -> Double
    }
    private var actions: Actions?
    /// The title, show and poster on the card.
    private var info: [String: Any] = [:]
    private var playing = false
    private var position = 0.0, duration = 0.0, rate = 1.0
    /// A call paused it: on again when it ends.
    private var interrupted = false
    private var targets: [(command: MPRemoteCommand, target: Any, wasEnabled: Bool)] = []
    private var observers: [NSObjectProtocol] = []

    /// A video opens on mpv (again for the next episode: the card changes, the buttons stay).
    func begin(_ info: [String: Any], skip: Double, actions: Actions) {
        self.info = info
        self.actions = actions
        position = 0; duration = 0
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skip)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skip)]
        guard targets.isEmpty else { return }
        add(center.playCommand) { system, _ in system.actions?.play() }
        add(center.pauseCommand) { system, _ in system.actions?.pause() }
        add(center.togglePlayPauseCommand) { system, _ in
            if system.playing { system.actions?.pause() } else { system.actions?.play() }
        }
        add(center.skipForwardCommand) { system, seconds in system.move(seconds ?? 15) }
        add(center.skipBackwardCommand) { system, seconds in system.move(-(seconds ?? 15)) }
        add(center.changePlaybackPositionCommand) { system, seconds in
            if let seconds { system.actions?.seek(seconds) }
        }
        let notes = NotificationCenter.default
        observers.append(notes.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // Read here: the notification itself doesn't cross to the main actor.
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type, options: options) }
        })
        observers.append(notes.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.routeChanged(reason) }
        })
    }
    /// The poster has come.
    func show(_ info: [String: Any]) {
        guard actions != nil else { return }
        self.info = info
        publish()
    }
    /// It plays, pauses, moves or changes speed: the card follows (iOS counts on by itself between).
    func update(playing: Bool, position: Double, duration: Double, rate: Double) {
        guard actions != nil else { return }
        self.playing = playing; self.position = position; self.duration = duration; self.rate = rate
        if UIApplication.shared.isIdleTimerDisabled != playing { UIApplication.shared.isIdleTimerDisabled = playing }
        publish()
    }
    /// The player closed, or the video moved to AetherEngine: everything given back.
    func end() {
        guard actions != nil else { return }
        actions = nil
        interrupted = false
        playing = false
        for entry in targets {
            entry.command.removeTarget(entry.target)
            entry.command.isEnabled = entry.wasEnabled
        }
        targets = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        UIApplication.shared.isIdleTimerDisabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func publish() {
        guard duration > 0 else { return }
        var card = info
        card[MPMediaItemPropertyPlaybackDuration] = duration
        card[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        card[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = card
    }
    private func move(_ seconds: Double) {
        guard let actions else { return }
        let target = max(0, actions.position() + seconds)
        actions.seek(duration > 0 ? min(target, duration) : target)
    }
    private func add(_ command: MPRemoteCommand, _ act: @escaping @MainActor @Sendable (JellyMPVSystem, Double?) -> Void) {
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

    /// A call, an alarm or another app's sound: paused as it begins; on again as it ends, when iOS says
    /// the interruption was the kind to resume from and it was playing before.
    private func interruption(_ type: UInt?, options: UInt) {
        switch type.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
        case .began:
            guard playing else { return }
            interrupted = true
            actions?.pause()
        case .ended:
            guard interrupted else { return }
            interrupted = false
            guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else { return }
            Task {
                // iOS left the session inactive: it has to be active again before the sound.
                await JellyAudioSession.activate()
                actions?.play()
            }
        default:
            break
        }
    }
    /// Headphones or AirPods gone: paused, rather than on through the speaker.
    private func routeChanged(_ reason: UInt?) {
        guard playing, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        actions?.pause()
    }
}
