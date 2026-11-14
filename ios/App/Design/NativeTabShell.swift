import SwiftUI
import UIKit

/// Own the public UIKit tab-controller delegate instead of replacing SwiftUI's
/// private delegate. Each hosted NavigationStack remains alive between tabs.
@MainActor struct NativeTabShell: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    let accent: UIColor
    /// Something is syncing: the Profile tab's icon turns a ring (as Cinopsys shows it).
    var syncing = false
    /// Every value `page` captures besides the observed store and router. Pages observe
    /// those themselves, so the five roots are rebuilt only when this key changes.
    let pageKey: String
    let canPage: @MainActor (AppTab) -> Bool
    let onReselect: @MainActor (AppTab) -> Void
    let page: @MainActor (AppTab) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, canPage: canPage, onReselect: onReselect) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.view.backgroundColor = ThemeStore.current.followsSystemAppearance ? .systemGroupedBackground : .black
        // Scrolling down shrinks the tab bar into a small pill; scrolling up (or a tap) brings it back.
        // UI tests keep it open so they can reach every tab, unless they ask for the real behaviour.
        let arguments = ProcessInfo.processInfo.arguments
        controller.tabBarMinimizeBehavior = arguments.contains("--ui-testing") && !arguments.contains("--ui-tabbar-minimize") ? .never : .onScrollDown
        controller.viewControllers = AppTab.allCases.map { tab in
            let host = UIHostingController(rootView: page(tab))
            host.view.backgroundColor = .clear
            host.tabBarItem = UITabBarItem(title: tab.label, image: UIImage(systemName: tab.systemIcon), selectedImage: UIImage(systemName: tab.systemIcon))
            host.tabBarItem.accessibilityIdentifier = "tab-" + tab.rawValue
            return host
        }
        let coordinator = context.coordinator
        coordinator.controller = controller
        coordinator.renderedPageKey = pageKey
        // iOS shrinks the bar on scroll down but only brings it back at the end of a page;
        // this brings it back as soon as you scroll up.
        if controller.tabBarMinimizeBehavior == .onScrollDown { coordinator.scrollUp.attach(to: controller) }
        controller.delegate = coordinator
        // No content swipe between tabs: a sideways swipe belongs to the page (All, Movies, Shows, Anime).
        controller.selectedIndex = AppTab.allCases.firstIndex(of: selection) ?? 0
        controller.tabBar.tintColor = accent
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection; coordinator.canPage = canPage
        coordinator.onReselect = onReselect
        controller.tabBar.tintColor = accent
        controller.view.backgroundColor = ThemeStore.current.followsSystemAppearance ? .systemGroupedBackground : .black
        coordinator.showSync(syncing, in: controller, accent: accent)
        // Reassigning a root re-diffs that whole tab. Doing all five on every root update
        // (opening Surprise me, any state the root body read) rebuilt every screen.
        if coordinator.renderedPageKey != pageKey {
            coordinator.renderedPageKey = pageKey
            for (index, host) in (controller.viewControllers ?? []).enumerated() {
                (host as? UIHostingController<AnyView>)?.rootView = page(AppTab.allCases[index])
            }
        }
        guard coordinator.interaction == nil, controller.transitionCoordinator == nil,
              let index = AppTab.allCases.firstIndex(of: selection), controller.selectedIndex != index else { return }
        // Only a jump asked for from inside a page lands here (Home's Up next or Stats, Profile's
        // Watchlist, a stat opening Library, Search): a tap on the bar has already switched. A short
        // cross-fade instead of a cut (owner's request); none with Reduce Motion or off screen.
        guard controller.view.window != nil, !UIAccessibility.isReduceMotionEnabled else { controller.selectedIndex = index; return }
        UIView.transition(with: controller.view, duration: 0.3, options: [.transitionCrossDissolve, .allowAnimatedContent, .beginFromCurrentState]) {
            controller.selectedIndex = index
        }
    }
    static func dismantleUIViewController(_ controller: UITabBarController, coordinator: Coordinator) {
        controller.view.removeGestureRecognizer(coordinator.pan)
        coordinator.scrollUp.detach(from: controller)
        coordinator.stopSpinner()
        controller.delegate = nil
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        // MARK: Syncing ring on the Profile tab

        private var spinLink: CADisplayLink?
        private var spinFrames: (normal: [UIImage], selected: [UIImage]) = ([], [])
        private var spinIndex = 0
        private var spinStarted = Date.distantPast
        private var spinAccent: UIColor?
        private var spinStop: Task<Void, Never>?
        private weak var spinItem: UITabBarItem?
        private static let spinSteps = 24

        /// On: the ring turns (once a second). Off: it stays a moment at least, so a quick sync
        /// doesn't flicker, then the plain icon comes back.
        func showSync(_ on: Bool, in controller: UITabBarController, accent: UIColor) {
            guard let index = AppTab.allCases.firstIndex(of: .more), let host = controller.viewControllers?[index] else { return }
            if on {
                spinStop?.cancel(); spinStop = nil
                guard spinLink == nil || spinAccent != accent else { return }
                startSpinner(host.tabBarItem, bar: controller.tabBar, accent: accent)
            } else if spinLink != nil, spinStop == nil {
                let wait = max(0, 0.9 - Date.now.timeIntervalSince(spinStarted))
                spinStop = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    self?.stopSpinner()
                }
            }
        }
        private func startSpinner(_ item: UITabBarItem, bar: UITabBar, accent: UIColor) {
            spinLink?.invalidate()
            let icon = UIColor.label.resolvedColor(with: bar.traitCollection)
            spinFrames = (Self.ringFrames(icon: icon, ring: accent), Self.ringFrames(icon: accent, ring: accent))
            spinItem = item; spinAccent = accent; spinIndex = 0; spinStarted = .now
            item.accessibilityValue = "Syncing"
            let link = CADisplayLink(target: self, selector: #selector(spinTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
            link.add(to: .main, forMode: .common)
            spinLink = link
            spinTick()
        }
        @objc private func spinTick() {
            guard let item = spinItem, !spinFrames.normal.isEmpty else { stopSpinner(); return }
            // A turn a second, whatever the frame rate.
            let step = Int(Date.now.timeIntervalSince(spinStarted) * Double(Self.spinSteps)) % Self.spinSteps
            guard step != spinIndex || item.image !== spinFrames.normal[step] else { return }
            spinIndex = step
            item.image = spinFrames.normal[step]
            item.selectedImage = spinFrames.selected[step]
        }
        func stopSpinner() {
            spinStop?.cancel(); spinStop = nil
            spinLink?.invalidate(); spinLink = nil
            if let item = spinItem {
                item.image = UIImage(systemName: AppTab.more.systemIcon)
                item.selectedImage = UIImage(systemName: AppTab.more.systemIcon)
                item.accessibilityValue = nil
            }
            spinItem = nil; spinAccent = nil; spinFrames = ([], [])
        }
        /// The Profile icon inside a faint ring, with an arc in the accent at each step of a turn.
        private static func ringFrames(icon: UIColor, ring: UIColor) -> [UIImage] {
            let side: CGFloat = 30, radius: CGFloat = 13.6
            let glyph = UIImage(systemName: AppTab.more.systemIcon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))?
                .withTintColor(icon, renderingMode: .alwaysOriginal)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            let center = CGPoint(x: side / 2, y: side / 2)
            return (0..<spinSteps).map { step in
                renderer.image { _ in
                    let track = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                    track.lineWidth = 2; icon.withAlphaComponent(0.22).setStroke(); track.stroke()
                    let start = CGFloat(step) / CGFloat(spinSteps) * .pi * 2 - .pi / 2
                    let arc = UIBezierPath(arcCenter: center, radius: radius, startAngle: start, endAngle: start + .pi * 0.6, clockwise: true)
                    arc.lineWidth = 2.4; arc.lineCapStyle = .round; ring.setStroke(); arc.stroke()
                    if let glyph {
                        let size = glyph.size
                        glyph.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
                    }
                }.withRenderingMode(.alwaysOriginal)
            }
        }

        var selection: Binding<AppTab>
        var canPage: @MainActor (AppTab) -> Bool
        var onReselect: @MainActor (AppTab) -> Void
        weak var controller: UITabBarController?
        let scrollUp = TabBarScrollUpRestorer()
        var renderedPageKey: String?
        var interaction: UIPercentDrivenInteractiveTransition?
        private var origin = 0
        private var target = 0
        private var direction: CGFloat = 1
        /// Swiping past the first or last tab bounces the page instead of failing.
        /// A failed pan would let the touch fall through to a row or menu button.
        private weak var edgePage: UIView?
        lazy var pan: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(track(_:)))
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = true
            gesture.delegate = self
            return gesture
        }()
        init(selection: Binding<AppTab>, canPage: @escaping @MainActor (AppTab) -> Bool, onReselect: @escaping @MainActor (AppTab) -> Void) {
            self.selection = selection; self.canPage = canPage; self.onReselect = onReselect
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let controller, interaction == nil, controller.transitionCoordinator == nil,
                  controller.presentedViewController == nil, !UIAccessibility.isVoiceOverRunning,
                  AppTab.allCases.indices.contains(controller.selectedIndex), canPage(AppTab.allCases[controller.selectedIndex]) else { return false }
            // Claim every deliberate horizontal swipe on a root page, including one
            // past either end (it bounces). Declining it would hand the delayed
            // touch to the control underneath, e.g. open a picker's menu.
            let velocity = pan.velocity(in: controller.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var ancestor = touch.view
            while let view = ancestor {
                // Child carousels, text editing, sliders and the native tab bar
                // keep their own recognizers. Vertical lists may page sideways.
                if view is UITabBar || view is UISlider || view is UISwitch || view is UITextField || view is UITextView { return false }
                // Only a real horizontal scroller owns the touch. A vertical list whose
                // content is a few points wider than the screen (glass button padding,
                // rounding) must still page between tabs.
                if let scroll = view as? UIScrollView, Self.scrollsSideways(scroll) { return false }
                if view === controller?.view { break }
                ancestor = view.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // More's list is 0.2 pt wider than its frame, so UIKit treats it as able
            // to scroll sideways and its pan claimed every horizontal swipe first.
            // A vertical list's pan now waits for the pager to decline; the pager
            // declines any non-horizontal drag at its first movement.
            guard let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer else { return false }
            return !Self.scrollsSideways(scroll)
        }
        private static func scrollsSideways(_ scroll: UIScrollView) -> Bool {
            RootTabSwipe.isHorizontalScroller(contentWidth: scroll.contentSize.width, boundsWidth: scroll.bounds.width,
                                              bouncesHorizontally: scroll.alwaysBounceHorizontal, bouncesVertically: scroll.alwaysBounceVertical)
        }
        @objc private func track(_ gesture: UIPanGestureRecognizer) {
            guard let controller else { return }
            let width = max(1, controller.view.bounds.width)
            switch gesture.state {
            case .began:
                origin = controller.selectedIndex
                direction = gesture.velocity(in: controller.view).x < 0 ? 1 : -1
                target = origin + Int(direction)
                guard AppTab.allCases.indices.contains(target) else {
                    edgePage = controller.selectedViewController?.view
                    return
                }
                let driver = UIPercentDrivenInteractiveTransition()
                driver.completionCurve = .easeOut
                interaction = driver
                controller.selectedIndex = target
            case .changed:
                if let page = edgePage {
                    guard !UIAccessibility.isReduceMotionEnabled else { return }
                    page.transform = CGAffineTransform(translationX: RootTabSwipe.edgeOffset(gesture.translation(in: controller.view).x, width: width), y: 0)
                    return
                }
                interaction?.update(min(1, max(0, -gesture.translation(in: controller.view).x * direction / width)))
            case .ended, .cancelled, .failed:
                if let page = edgePage {
                    edgePage = nil
                    guard page.transform != .identity else { return }
                    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                                   options: [.allowUserInteraction, .beginFromCurrentState]) { page.transform = .identity }
                    return
                }
                guard gesture.state == .ended else { interaction?.cancel(); return }
                let progress = max(0, -gesture.translation(in: controller.view).x * direction / width)
                let velocity = -gesture.velocity(in: controller.view).x * direction
                if RootTabSwipe.shouldFinish(progress: progress, velocity: velocity) { interaction?.finish() }
                else { interaction?.cancel() }
            default: break
            }
        }
        func tabBarController(_ tabBarController: UITabBarController, animationControllerForTransitionFrom fromVC: UIViewController, to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            guard interaction != nil else { return nil }
            return TabPageAnimator(direction: direction) { [weak self] completed in
                guard let self else { return }
                self.interaction = nil
                self.selection.wrappedValue = AppTab.allCases[completed ? self.target : self.origin]
            }
        }
        func tabBarController(_ tabBarController: UITabBarController, interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)? { interaction }
        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            guard interaction == nil, AppTab.allCases.indices.contains(tabBarController.selectedIndex) else { return }
            let tab = AppTab.allCases[tabBarController.selectedIndex]
            if selection.wrappedValue == tab { onReselect(tab) }
            else { selection.wrappedValue = tab }
        }
    }
}

@MainActor private final class TabPageAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let direction: CGFloat
    let completion: @MainActor (Bool) -> Void
    init(direction: CGFloat, completion: @escaping @MainActor (Bool) -> Void) { self.direction = direction; self.completion = completion }
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.3 }
    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to), let target = context.viewController(forKey: .to) else {
            context.completeTransition(false); completion(false); return
        }
        let container = context.containerView
        to.frame = context.finalFrame(for: target)
        container.addSubview(to)
        let distance = container.bounds.width * direction
        to.transform = CGAffineTransform(translationX: distance, y: 0)
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            from.transform = CGAffineTransform(translationX: -distance, y: 0)
            to.transform = .identity
        } completion: { _ in
            let completed = !context.transitionWasCancelled
            from.transform = .identity; to.transform = .identity
            if !completed { to.removeFromSuperview() }
            context.completeTransition(completed)
            self.completion(completed)
        }
    }
}

/// Brings a shrunken tab bar back as soon as a page is dragged upward (content scrolling back
/// toward the top). It only watches: it never claims, delays or cancels a touch.
@MainActor final class TabBarScrollUpRestorer: NSObject, UIGestureRecognizerDelegate {
    private weak var controller: UITabBarController?
    private var restored = false
    /// The bar shrinks only after a scroll down (finger moving up); until then it's full size and a
    /// scroll up has nothing to bring back. Without this, every drag up pumped the bar.
    private var shrunk = false
    private lazy var watcher: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(track(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()
    func attach(to controller: UITabBarController) {
        self.controller = controller
        controller.view.addGestureRecognizer(watcher)
    }
    func detach(from controller: UITabBarController) { controller.view.removeGestureRecognizer(watcher) }
    @objc private func track(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: restored = false
        case .changed:
            guard !restored, let controller, controller.tabBarMinimizeBehavior == .onScrollDown else { return }
            let moved = gesture.translation(in: controller.view)
            // A finger moving up scrolls the page down: the system shrinks the bar.
            if moved.y < -24, -moved.y > abs(moved.x) * 1.5 { shrunk = true; return }
            // A finger moving down the screen scrolls the page up: bring the bar back, once.
            guard shrunk, moved.y > 24, moved.y > abs(moved.x) * 1.5 else { return }
            restored = true; shrunk = false
            // There's no "expand" call: switching shrinking off expands the bar; it's back on at once
            // for the next scroll down. The switch runs inside a spring, and the bar grows in from
            // slightly smaller and dimmer, so it eases back instead of popping.
            let bar = controller.tabBar
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if !reduceMotion { bar.transform = CGAffineTransform(scaleX: 0.8, y: 0.8).translatedBy(x: 0, y: 18); bar.alpha = 0.4 }
            UIView.animate(withDuration: reduceMotion ? 0.2 : 0.55, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                controller.tabBarMinimizeBehavior = .never
                bar.transform = .identity; bar.alpha = 1
                controller.view.layoutIfNeeded()
            } completion: { [weak controller] _ in
                controller?.tabBarMinimizeBehavior = .onScrollDown
            }
        default: break
        }
    }
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
}
