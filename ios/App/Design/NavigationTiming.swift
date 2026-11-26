#if DEBUG
import SwiftUI
import UIKit
import QuartzCore

/// UI tests only ("--ui-nav-timing", NavigationRoundTripProbe): how long going back from a title page
/// took, from Back to the end of UIKit's transition (a page pushed meanwhile waits for that end), and
/// how long the main thread was held up in the 2.5 s after Back. Read from an invisible accessibility
/// element ("nav-timing"), so the test asks nothing of the app while it measures.
@MainActor enum NavigationTiming {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--ui-nav-timing")
    /// "--ui-card-animations-off": a page opened as a card appears with UIKit's animations off, as on
    /// the owner's iPhone (where the card jumped to full size).
    static let cardAnimationsOff = ProcessInfo.processInfo.arguments.contains("--ui-card-animations-off")
    private static var backAt: CFTimeInterval = 0
    private static var popMS: Int?
    /// Title pages opened and closed as a card (CardTransition).
    private static var cards = (opened: 0, shown: 0, closed: 0)
    static func cardOpened() { cards.opened += 1 }
    static func cardShown() { cards.shown += 1 }
    static func cardClosed() { cards.closed += 1 }
    /// The last opening of a title page, from its start to the end of UIKit's transition.
    private static var pushAt: CFTimeInterval = 0
    private static var pushMS: Int?
    static func pushStarted() { guard enabled else { return }; pushAt = CACurrentMediaTime(); pushMS = nil }
    static func pushEnded() { guard enabled, pushAt > 0 else { return }; pushMS = Int((CACurrentMediaTime() - pushAt) * 1000) }
    static func popStarted() {
        guard enabled else { return }
        backAt = CACurrentMediaTime()
        popMS = nil
    }
    static func popEnded(cancelled: Bool) {
        guard enabled, backAt > 0 else { return }
        popMS = cancelled ? -1 : Int((CACurrentMediaTime() - backAt) * 1000)
    }
    /// "pop=812ms stalls=3 total=140ms longest=90ms".
    static var report: String {
        guard backAt > 0 else { return "no slide timed cards-opened=\(cards.opened) cards-shown=\(cards.shown) cards-closed=\(cards.closed)" }
        let held = MainThreadStalls.shared.summary(from: backAt, to: backAt + 2.5)
        return "pop=\(popMS.map { String($0) } ?? "?")ms open=\(pushMS.map { String($0) } ?? "?")ms cards-opened=\(cards.opened) cards-shown=\(cards.shown) cards-closed=\(cards.closed) stalls=\(held.count) total=\(Int(held.total))ms longest=\(Int(held.longest))ms"
    }
}

/// Every time the main thread took more than 16 ms to answer, with when (a background thread asks it
/// every 5 ms). UI tests only.
final class MainThreadStalls: @unchecked Sendable {
    static let shared = MainThreadStalls()
    private let lock = NSLock()
    private var stalls: [(at: CFTimeInterval, ms: Double)] = []
    private var running = false
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        let thread = Thread { [self] in
            while true {
                let sent = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = (CACurrentMediaTime() - sent) * 1000
                if ms > 16 {
                    lock.lock()
                    stalls.append((sent, ms))
                    if stalls.count > 4000 { stalls.removeFirst(1000) }
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func summary(from: CFTimeInterval, to: CFTimeInterval) -> (count: Int, total: Double, longest: Double) {
        lock.lock(); defer { lock.unlock() }
        let window = stalls.filter { $0.at >= from && $0.at <= to }
        return (window.count, window.reduce(0) { $0 + $1.ms }, window.map(\.ms).max() ?? 0)
    }
}

/// The invisible element the probe reads (its label is worked out when asked, no redraws).
struct NavigationTimingProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        MainThreadStalls.shared.start()
        return ProbeView()
    }
    func updateUIView(_ view: ProbeView, context: Context) {}
    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityIdentifier = "nav-timing"
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }
        override var accessibilityLabel: String? {
            get { NavigationTiming.report }
            set {}
        }
    }
}
#endif
