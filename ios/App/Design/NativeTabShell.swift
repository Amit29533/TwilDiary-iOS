import SwiftUI
import UIKit

/// Own the public UIKit tab-controller delegate instead of replacing SwiftUI's
/// private delegate. Each hosted NavigationStack remains alive between tabs.
@MainActor struct NativeTabShell: UIViewControllerRepresentable {
    @Binding var selection: AppTab
    let accent: UIColor
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
        controller.delegate = coordinator
        controller.view.addGestureRecognizer(coordinator.pan)
        controller.selectedIndex = AppTab.allCases.firstIndex(of: selection) ?? 0
        controller.tabBar.tintColor = accent
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection; coordinator.canPage = canPage
        coordinator.onReselect = onReselect
        controller.tabBar.tintColor = accent
        for (index, host) in (controller.viewControllers ?? []).enumerated() {
            (host as? UIHostingController<AnyView>)?.rootView = page(AppTab.allCases[index])
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
        var interaction: UIPercentDrivenInteractiveTransition?
        private var origin = 0
        private var target = 0
        private var direction: CGFloat = 1
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
            let velocity = pan.velocity(in: controller.view)
            guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
            let next = controller.selectedIndex + (velocity.x < 0 ? 1 : -1)
            return AppTab.allCases.indices.contains(next)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var ancestor = touch.view
            while let view = ancestor {
                // Child carousels, text editing, sliders and the native tab bar
                // keep their own recognizers. Vertical lists may page sideways.
                if view is UITabBar || view is UISlider || view is UISwitch || view is UITextField || view is UITextView { return false }
                if let scroll = view as? UIScrollView, scroll.alwaysBounceHorizontal || scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                if view === controller?.view { break }
                ancestor = view.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
        @objc private func track(_ gesture: UIPanGestureRecognizer) {
            guard let controller else { return }
            let width = max(1, controller.view.bounds.width)
            switch gesture.state {
            case .began:
                origin = controller.selectedIndex
                direction = gesture.velocity(in: controller.view).x < 0 ? 1 : -1
                target = origin + Int(direction)
                guard AppTab.allCases.indices.contains(target) else { return }
                let driver = UIPercentDrivenInteractiveTransition()
                driver.completionCurve = .easeOut
                interaction = driver
                controller.selectedIndex = target
            case .changed:
                interaction?.update(min(1, max(0, -gesture.translation(in: controller.view).x * direction / width)))
            case .ended:
                let progress = max(0, -gesture.translation(in: controller.view).x * direction / width)
                let velocity = -gesture.velocity(in: controller.view).x * direction
                if RootTabSwipe.shouldFinish(progress: progress, velocity: velocity) { interaction?.finish() }
                else { interaction?.cancel() }
            case .cancelled, .failed: interaction?.cancel()
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
