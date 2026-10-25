import SwiftUI
import UIKit

/// Right advances through the owner's tab order; a short or vertical drag does
/// nothing. One release changes at most one tab and never wraps at either end.
enum RootTabSwipe {
    static func destination(from tab: AppTab, translation: CGSize, width: CGFloat) -> AppTab? {
        guard width.isFinite, width > 0, translation.width.isFinite, translation.height.isFinite,
              abs(translation.width) >= max(64, width * 0.18),
              abs(translation.width) > abs(translation.height) * 1.5,
              let index = AppTab.allCases.firstIndex(of: tab) else { return nil }
        let next = index + (translation.width > 0 ? 1 : -1)
        guard AppTab.allCases.indices.contains(next) else { return nil }
        return AppTab.allCases[next]
    }
}

/// A noninteractive marker reserves a child's existing horizontal gesture.
/// It is inspected once at touch-down, never during scrolling or every frame.
@MainActor private final class TabSwipeExclusionView: UIView {}
@MainActor private struct TabSwipeExclusion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TabSwipeExclusionView()
        view.isUserInteractionEnabled = false; view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor private struct RootTabSwipeInput: UIViewControllerRepresentable {
    let enabled: Bool
    let onSwipe: @MainActor (CGSize, CGFloat) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled; controller.onSwipe = onSwipe
        controller.attachWhenPresented()
    }
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = false
        var onSwipe: (@MainActor (CGSize, CGFloat) -> Void)?
        private weak var surface: UIView?
        private var attaching: Task<Void, Never>?
        private var startsOnWatchCard = false
        private lazy var pan: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(finish(_:)))
            // Once a horizontal page pan begins, cancel the underlying button
            // touch. Otherwise releasing over a cover can also push a title.
            gesture.maximumNumberOfTouches = 1; gesture.cancelsTouchesInView = true; gesture.delegate = self
            return gesture
        }()
        override func loadView() {
            view = UIView(); view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false; view.backgroundColor = .clear
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); attachWhenPresented()
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated); attaching?.cancel()
            surface?.removeGestureRecognizer(pan); surface = nil
        }
        func attachWhenPresented() {
            attaching?.cancel()
            attaching = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil,
                      let nav = self.navigationOwner, let top = nav.topViewController,
                      self.view.isDescendant(of: top.view), let window = self.view.window else { return }
                if self.surface !== window {
                    self.surface?.removeGestureRecognizer(self.pan)
                    window.addGestureRecognizer(self.pan); self.surface = window
                }
            }
        }
        private var navigationOwner: UINavigationController? {
            var responder: UIResponder? = viewIfLoaded
            var owner = navigationController
            while owner == nil, let current = responder {
                if let controller = current as? UIViewController { owner = controller.navigationController }
                responder = current.next
            }
            return owner
        }
        private var ownsRoot: Bool {
            guard enabled, let nav = navigationOwner, nav.transitionCoordinator == nil,
                  let top = nav.topViewController,
                  viewIfLoaded?.window != nil else { return false }
            return view.isDescendant(of: top.view) && nav.presentedViewController == nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard ownsRoot, let surface else { return false }
            let speed = pan.velocity(in: surface)
            return abs(speed.x) > abs(speed.y) * 1.5
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard ownsRoot, let surface else { return false }
            var ancestor = touch.view
            while let current = ancestor {
                if current is UITabBar || current is UISlider || current is UISwitch || current is UITextField || current is UITextView { return false }
                if let scroll = current as? UIScrollView,
                   scroll.alwaysBounceHorizontal || scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                if current === surface { break }
                ancestor = current.superview
            }
            startsOnWatchCard = containsExclusion(surface, point: touch.location(in: surface))
            return true
        }
        private func containsExclusion(_ container: UIView, point: CGPoint) -> Bool {
            guard !container.isHidden, container.alpha > 0.01 else { return false }
            if container is TabSwipeExclusionView { return container.bounds.contains(point) }
            return container.subviews.contains { child in
                containsExclusion(child, point: child.convert(point, from: container))
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Let a root vertical ScrollView settle naturally. Horizontal child
            // scrolls and reserved card gestures are rejected at touch-down.
            ownsRoot
        }
        @objc private func finish(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, ownsRoot, let surface else { return }
            let movement = gesture.translation(in: surface)
            // Short Glance card swipes keep the existing one-watch action;
            // a deliberate long page swipe navigates, without logging a watch.
            guard !startsOnWatchCard || abs(movement.x) >= 160 else { return }
            onSwipe?(CGSize(width: movement.x, height: movement.y), surface.bounds.width)
        }
    }
}

extension View {
    @MainActor func rootTabSwipes(enabled: Bool, onSwipe: @escaping @MainActor (CGSize, CGFloat) -> Void) -> some View {
        background(RootTabSwipeInput(enabled: enabled, onSwipe: onSwipe).frame(width: 0, height: 0))
    }
    @MainActor func reservesHorizontalSwipe(_ reserved: Bool = true) -> some View {
        background { if reserved { TabSwipeExclusion() } }
    }
}
