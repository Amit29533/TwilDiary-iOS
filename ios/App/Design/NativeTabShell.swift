import SwiftUI
import UIKit

/// Own the public UIKit tab-controller delegate instead of replacing SwiftUI's
/// private delegate. Each hosted NavigationStack remains alive between tabs.
@MainActor struct NativeTabShell: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    let accent: UIColor
    /// Every value `page` captures besides the observed store and router. Pages observe
    /// those themselves, so the five roots are rebuilt only when this key changes.
    let pageKey: String
    let canPage: @MainActor (AppTab) -> Bool
    let onReselect: @MainActor (AppTab) -> Void
    let page: @MainActor (AppTab) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, canPage: canPage, onReselect: onReselect) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.view.backgroundColor = .black
        controller.tabBarMinimizeBehavior = .never
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
        controller.selectedIndex = index
    }
    static func dismantleUIViewController(_ controller: UITabBarController, coordinator: Coordinator) {
        controller.view.removeGestureRecognizer(coordinator.pan)
        controller.delegate = nil
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        var selection: Binding<AppTab>
        var canPage: @MainActor (AppTab) -> Bool
        var onReselect: @MainActor (AppTab) -> Void
        weak var controller: UITabBarController?
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
