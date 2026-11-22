import SwiftUI
import UIKit
import OSLog

/// SwiftUI onAppear can run during an interactive transition. Publish shell
/// visibility only once UIKit finishes presenting the owning destination.
@MainActor private struct NativeNavigationAppearance: UIViewControllerRepresentable {
    let onPresented: @MainActor () -> Void
    let detail: Bool
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onPresented = onPresented
        controller.detail = detail
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onPresented = onPresented
        controller.detail = detail
        controller.publishWhenAttached()
    }
    final class Controller: UIViewController {
        var onPresented: (@MainActor () -> Void)?
        var detail = false
        /// The tab bar stays on every page, title and profile pages included (owner's request:
        /// one navigation everywhere). `detail` now only fades the navigation bar in and out.
        private let hidesTabBar = false
        private var publishing: Task<Void, Never>?
        private var transitionPending = false
        private var observing = [UIGestureRecognizer]()
        private var observedKinds = [ObjectIdentifier: String]()
        private let logger = Logger(subsystem: "com.amit29533.TwilDiary.navigation", category: "presentation")
        override func loadView() {
            let surface = UIView()
            surface.backgroundColor = .clear
            surface.isUserInteractionEnabled = false
            surface.isAccessibilityElement = false
            view = surface
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Settle the bar if appearance ran before this page was attached.
            applyTabBarVisibility(animated: false)
            publishWhenAttached()
        }
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            fadeNavigationBar(appearing: true)
            // viewWillAppear runs before the page is in the hierarchy, so the old
            // containment check there often failed and title pages kept the tab bar.
            // viewIsAppearing has the attached view and still runs alongside the
            // native push/pop, including a cancelled interactive Back.
            applyTabBarVisibility(animated: animated)
        }
        private func applyTabBarVisibility(animated: Bool) {
            // The cheap check first: the bar is almost always already right, and walking the view
            // tree on every page update (it runs while scrolling) showed up in the profile.
            guard let tabs = tabBarController, tabs.isTabBarHidden != hidesTabBar, let selected = tabs.selectedViewController,
                  view.isDescendant(of: selected.view) else { return }
            let previous = tabs.isTabBarHidden
            tabs.setTabBarHidden(hidesTabBar, animated: animated)
            _ = transitionCoordinator?.animate(alongsideTransition: nil) { context in
                guard context.isCancelled else { return }
                // Completion runs on the main thread: restore in the same frame.
                MainActor.assumeIsolated { tabs.setTabBarHidden(previous, animated: false) }
            }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            fadeNavigationBar(appearing: false)
        }
        /// Main tabs hide the navigation bar and title pages show it, but UIKit shows it before the
        /// zoom in and hides it only after the zoom out, so a title page's back, info, heart and
        /// menu buttons sat over the Glance header. Between a main tab and a title page, the bar
        /// now fades with the transition itself (and comes back if the swipe back is cancelled).
        private func fadeNavigationBar(appearing: Bool) {
            guard detail, let navigation = owningNavigation(), let coordinator = navigation.transitionCoordinator,
                  let root = navigation.viewControllers.first,
                  coordinator.viewController(forKey: appearing ? .from : .to) === root else { return }
            let bar = navigation.navigationBar
            if appearing { bar.alpha = 0 }
            coordinator.animate(alongsideTransition: { _ in
                MainActor.assumeIsolated { bar.alpha = appearing ? 1 : 0 }
            }, completion: { context in
                MainActor.assumeIsolated {
                    if appearing || context.isCancelled { bar.alpha = 1; return }
                    // Back on the main tab: keep the bar invisible until UIKit has hidden it, then
                    // restore it for the next page (at most a second later).
                    Task { @MainActor in
                        for _ in 0..<20 where !navigation.isNavigationBarHidden {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        bar.alpha = 1
                    }
                }
            })
        }
        private func owningNavigation() -> UINavigationController? {
            if let navigationController { return navigationController }
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController, let navigation = controller.navigationController { return navigation }
                responder = current.next
            }
            return nil
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil { publishWhenAttached() }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            publishing?.cancel()
            #if DEBUG
            for gesture in observing { gesture.removeTarget(self, action: #selector(observePop(_:))) }
            observing.removeAll()
            observedKinds.removeAll()
            #endif
        }
        func publishWhenAttached() {
            publishing?.cancel()
            publishing = Task { @MainActor [weak self] in
                // A representable's controller ancestry can still be changing in
                // didAppear. Its attached view is the source of containment truth.
                await Task.yield()
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil else { return }
                self.publish()
            }
        }
        private func publish() {
            var responder: UIResponder? = view
            var owner = navigationController
            while owner == nil, let current = responder {
                if let controller = current as? UIViewController { owner = controller.navigationController }
                responder = current.next
            }
            guard let navigation = owner, let top = navigation.topViewController,
                  view.isDescendant(of: top.view) else { return }
            if let transition = navigation.transitionCoordinator {
                guard !transitionPending else { return }
                transitionPending = true
                let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.transitionPending = false
                        self?.publishWhenAttached()
                    }
                }
                if registered { return }
                transitionPending = false
            }
            // Scrolling/toolbar updates can make UIKit reveal the tab bar again.
            // Only the attached top destination may reassert its ownership.
            top.hidesBottomBarWhenPushed = hidesTabBar
            applyTabBarVisibility(animated: false)
            onPresented?()
            #if DEBUG
            let gestures: [(UIGestureRecognizer?, String)] = [(navigation.interactivePopGestureRecognizer, "edge"), (navigation.interactiveContentPopGestureRecognizer, "content")]
            if observing.isEmpty {
                for (candidate, kind) in gestures {
                    guard let gesture = candidate else { continue }
                    observing.append(gesture); observedKinds[ObjectIdentifier(gesture)] = kind
                    gesture.addTarget(self, action: #selector(observePop(_:)))
                }
            }
            logger.notice("presented depth=\(navigation.viewControllers.count) barHidden=\(navigation.isNavigationBarHidden) edgeEnabled=\(navigation.interactivePopGestureRecognizer?.isEnabled ?? false) contentEnabled=\(navigation.interactiveContentPopGestureRecognizer?.isEnabled ?? false)")
            #endif
            // UIKit owns recognition/delegates and deliberate slider tracking.
            // Updating unrelated state must never re-enable a protected gesture.
        }
        #if DEBUG
        @objc private func observePop(_ gesture: UIGestureRecognizer) {
            guard gesture.state != .changed else { return }
            let pan = gesture as? UIPanGestureRecognizer
            let distance = Double(pan?.translation(in: gesture.view).x ?? 0)
            let velocity = Double(pan?.velocity(in: gesture.view).x ?? 0)
            let kind = observedKinds[ObjectIdentifier(gesture)] ?? "unknown"
            logger.notice("nativePop kind=\(kind, privacy: .public) state=\(gesture.state.rawValue) enabled=\(gesture.isEnabled) translationX=\(distance) velocityX=\(velocity)")
        }
        #endif
    }
}

extension View {
    @MainActor func diaryNavigationAppearance(tab: AppTab, detail: Bool, router: AppRouter) -> some View {
        background(NativeNavigationAppearance(onPresented: { router.setDetailVisibility(detail, tab: tab) }, detail: detail).frame(width: 0, height: 0))
    }
}
