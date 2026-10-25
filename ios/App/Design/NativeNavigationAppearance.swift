import SwiftUI
import UIKit
import OSLog

/// SwiftUI onAppear can run during an interactive transition. Publish shell
/// visibility only once UIKit finishes presenting the owning destination.
@MainActor private struct NativeNavigationAppearance: UIViewControllerRepresentable {
    let onPresented: @MainActor () -> Void
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onPresented = onPresented
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onPresented = onPresented
        controller.publishWhenAttached()
    }
    final class Controller: UIViewController {
        var onPresented: (@MainActor () -> Void)?
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
            publishWhenAttached()
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
        background(NativeNavigationAppearance { router.setDetailVisibility(detail, tab: tab) }.frame(width: 0, height: 0))
    }
}
