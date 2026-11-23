import SwiftUI
import LocalAuthentication

/// Face ID lock for JellySpace (Settings → JellySpace → Preferences → Privacy): its pages and player
/// stay covered until Face ID (or the phone's passcode) unlocks them, and lock again once the app has
/// been away for the time chosen. While the app isn't in front they're covered too, so the app
/// switcher's picture shows nothing of them.
@MainActor @Observable final class JellyFaceLock {
    static let shared = JellyFaceLock()

    private(set) var unlocked = false
    /// The app isn't in front (covered for the app switcher).
    private(set) var covered = false
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var asking = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: JellyPrefs.faceLockKey) }

    /// Face ID, or the passcode when it fails or isn't set up.
    func unlock() async {
        guard enabled, !unlocked, !covered, !asking else { return }
        asking = true
        defer { asking = false }
        let context = LAContext()
        var problem: NSError?
        // No passcode on the phone: there's nothing to check against.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else { unlocked = true; return }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock JellySpace")) == true {
            unlocked = true
        }
    }
    /// Your face (or passcode) once more, for turning the lock off: that opens all it covers, and
    /// anyone holding the phone could.
    func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
    /// Just turned on: you're here, so it starts unlocked (it locks the next time you leave).
    func turnedOn() { unlocked = true }
    /// About to open JellySpace: Face ID first when it's locked. True when it may open.
    func enter() async -> Bool {
        guard enabled, !unlocked else { return true }
        await unlock()
        return unlocked
    }
    /// Left JellySpace: the next time in, Face ID first.
    func relock() { if enabled { unlocked = false } }

    // JellySpace's home locks again as you leave it. Its pages and its player open from the diary too
    // (a title's page has Play and Open in JellySpace), and leaving those left it unlocked.

    /// Where JellySpace's pages begin in each tab's stack.
    @ObservationIgnored private var roots: [AppTab: Int] = [:]
    @ObservationIgnored private var depths: [AppTab: Int] = [:]
    @ObservationIgnored private var check: Task<Void, Never>?

    /// A JellySpace page has opened in this tab, at this depth.
    func opened(_ tab: AppTab, depth: Int) { roots[tab] = min(roots[tab] ?? depth, depth) }
    /// A tab's stack has changed. Looked at once the page going has gone: locked sooner, it would ask
    /// for your face on its way out.
    func stacksChanged(_ counts: [AppTab: Int]) {
        guard !roots.isEmpty else { return }
        depths = counts
        check?.cancel()
        check = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let open = roots.filter { (depths[$0.key] ?? 0) >= $0.value }
            guard open.count < roots.count else { return }
            roots = open
            if open.isEmpty { relock() }
        }
    }
    /// A video opened from a diary page has closed.
    func leftPlayer() { if roots.isEmpty { relock() } }

    /// The app's coming and going (from the root view).
    func phase(_ phase: ScenePhase) {
        if phase == .active {
            covered = false
            if let leftAt, Date.now.timeIntervalSince(leftAt) >= Double(UserDefaults.standard.integer(forKey: JellyPrefs.faceLockAfterKey)) { unlocked = false }
            leftAt = nil
        } else if phase == .inactive {
            // Face ID's own prompt makes the app inactive too: only cover once it's unlocked (it is
            // covered anyway while locked).
            if enabled, unlocked { covered = true }
        } else if phase == .background {
            if enabled { covered = true; if leftAt == nil { leftAt = .now } }
        }
    }
}

/// The cover over a JellySpace page or the player while it's locked (or the app is away).
private struct JellyFaceLockCover: ViewModifier {
    @AppStorage(JellyPrefs.faceLockKey) private var on = false

    func body(content: Content) -> some View {
        let lock = JellyFaceLock.shared
        content.overlay {
            if on && (!lock.unlocked || lock.covered) {
                ZStack {
                    Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                    if !lock.covered {
                        VStack(spacing: 16) {
                            Image(systemName: "faceid").font(.app(size: 46, weight: .light)).foregroundStyle(HomeStyle.primary)
                            Text("JellySpace is locked").font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Button { Task { await lock.unlock() } } label: {
                                Text("Unlock").font(.app(size: 15, weight: .semibold)).padding(.horizontal, 22).frame(height: 40)
                            }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("jellyspace-face-unlock")
                        }
                    }
                }
                .transition(.opacity)
                // Face ID straight away when the page shows locked (and again on coming back).
                .task(id: lock.covered) { await lock.unlock() }
            }
        }
    }
}

/// Notes where a JellySpace page is in its tab's stack (see JellyFaceLock.opened).
private struct JellyPagePlace: ViewModifier {
    @Environment(AppRouter.self) private var router
    @State private var noted = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !noted else { return }
            noted = true
            JellyFaceLock.shared.opened(router.selectedTab, depth: router.paths[router.selectedTab]?.count ?? 0)
        }
    }
}

extension View {
    /// Covered by JellySpace's Face ID lock while it's locked.
    func jellyFaceLock() -> some View { modifier(JellyFaceLockCover()) }
    /// A page of JellySpace: leaving the last of them locks it again.
    func jellyPage() -> some View { modifier(JellyPagePlace()) }
}
