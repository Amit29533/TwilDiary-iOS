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
    private static var backAt: CFTimeInterval = 0
    private static var popMS: Int?
    /// Pages asked for while a page was going back (a tap during the pop).
    private static var pushes = 0
    static func pushAskedDuringPop() { pushes += 1 }
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
        guard backAt > 0 else { return "none" }
        let held = MainThreadStalls.shared.summary(from: backAt, to: backAt + 2.5)
        return "pop=\(popMS.map { String($0) } ?? "?")ms pushes-during-pops=\(pushes) stalls=\(held.count) total=\(Int(held.total))ms longest=\(Int(held.longest))ms"
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
