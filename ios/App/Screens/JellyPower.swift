import Foundation
import Observation

/// Whether the phone wants the player to go easy: Low Power Mode is on, or it's running hot
/// (iOS's thermal state serious or critical). The player then leaves out what costs the most and
/// isn't needed to watch: mpv's smooth motion, and upscaling on Auto.
@MainActor @Observable final class JellyPower {
    static let shared = JellyPower()

    private(set) var constrained = false
    /// Why, for the notice ("to keep the phone cool", "in Low Power Mode").
    private(set) var reason = ""
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        update()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { JellyPower.shared.update() }
            })
        }
    }

    private func update() {
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let low = info.isLowPowerModeEnabled
        let now = hot || low
        let why = hot ? "to keep the phone cool" : low ? "in Low Power Mode" : ""
        if now != constrained { constrained = now }
        if why != reason { reason = why }
    }
}
