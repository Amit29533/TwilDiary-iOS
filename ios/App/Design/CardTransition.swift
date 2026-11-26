import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Title pages open as a card from their poster and close back into it, as Netflix's do (owner's
/// choice). UIKit's own transitions keep the next page or Back waiting until they've ended (the zoom
/// 0.87 s, the slide 0.52 s: NavigationRoundTripProbe); here the page is pushed and popped without
/// one, so navigation is free at once, and the card's growing and shrinking is drawn on top:
/// opening, the page itself grows out of the poster over a still of the screen it left; closing, a
/// still of the page shrinks into the poster over the screen it returns to, letting every touch
/// through. Swiping back from the edge stays UIKit's slide. Off with Reduce Motion.
@MainActor enum CardTransition {
    /// How long the card grows (a critically damped spring: no tail after it).
    static let duration: TimeInterval = 0.45
    /// How long it shrinks back into its poster.
    static let closeDuration: TimeInterval = 0.4
    /// The poster's corner radius the card starts from and ends on.
    private static let corner: CGFloat = 12

    /// What a page opened as a card keeps for its way back: the poster (weakly: its view stays laid
    /// out under the page), where it was, and a still of the screen it left (behind the card while it
    /// grows, and while it's swiped).
    @MainActor final class Opening {
        weak var source: UIView?
        let rect: CGRect
        /// When it was set up (a push that never showed its page doesn't play on a later one).
        let at = CACurrentMediaTime()
        let backdrop: UIView?
        /// The navigation it's pushed in, and its top page before (to find the page once pushed).
        weak var navigation: UINavigationController?
        weak var previousTop: UIViewController?
        /// The swipe that closes it (held here: the gesture recogniser doesn't keep its target).
        var swipe: CardSwipe?
        init(source: UIView, rect: CGRect, backdrop: UIView?, navigation: UINavigationController?) {
            self.source = source; self.rect = rect; self.backdrop = backdrop
            self.navigation = navigation; previousTop = navigation?.topViewController
        }
        /// The poster's place on screen now (it's back in the window once the page is gone).
        var currentRect: CGRect {
            guard let source, source.window != nil else { return rect }
            let now = source.convert(source.bounds, to: nil)
            return now.width > 1 ? now : rect
        }
    }

    /// Posters that open their title as a card (CardSourceMarker views).
    private static let sources = NSHashTable<UIView>.weakObjects()
    static func register(_ view: UIView) { sources.add(view) }
    /// The last touch down on the screen, in its window's coordinates (CardTouchSpy).
    static var lastTouch: (point: CGPoint, window: UIWindow?, at: CFTimeInterval)?
    /// The opening the next page to appear plays (set as its push is asked for).
    private static var pending: Opening?
    /// Each page opened as a card, with its opening (for its Back and its swipe).
    private static let openings = NSMapTable<UIViewController, Opening>.weakToStrongObjects()
    /// Stills of pages still shrinking: gone at once if another title opens meanwhile.
    private static var closing: [UIView] = []

    /// A page is about to be pushed: whether it opens as a card from the poster just touched (then
    /// it's pushed without UIKit's animation).
    static func prepareOpen() -> Bool {
        guard !UIAccessibility.isReduceMotionEnabled, let touch = lastTouch, CACurrentMediaTime() - touch.at < 1.0,
              let window = touch.window else { return false }
        var best: (view: UIView, rect: CGRect)?
        for view in sources.allObjects where view.window === window {
            let rect = view.convert(view.bounds, to: nil)
            guard rect.width > 20, rect.height > 20, rect.contains(touch.point) else { continue }
            if let found = best, found.rect.width * found.rect.height <= rect.width * rect.height { continue }
            best = (view, rect)
        }
        guard let best, let navigation = navigationController(of: best.view) else { return false }
        for still in closing { still.removeFromSuperview() }
        closing = []
        lastTouch = nil
        pending = Opening(source: best.view, rect: best.rect, backdrop: window.snapshotView(afterScreenUpdates: false), navigation: navigation)
        #if DEBUG
        NavigationTiming.cardOpened()
        #endif
        return true
    }

    /// After the push was asked for: the page opens as a card even if its own appearing didn't start
    /// it (it starts it itself, NativeNavigationAppearance, for no frame at full size first).
    static func openIfStillPending() {
        guard let opening = pending, let navigation = opening.navigation, let page = navigation.topViewController,
              page !== opening.previousTop else { return }
        _ = open(page: page, navigation: navigation)
    }

    /// The page pushed for that opening has appeared: it grows out of the poster. Returns the opening
    /// (nil: not opened as a card).
    @discardableResult static func open(page: UIViewController, navigation: UINavigationController) -> Opening? {
        guard let opening = pending else { return nil }
        #if DEBUG
        let animationsOff = NavigationTiming.cardAnimationsOff && UIView.areAnimationsEnabled
        if animationsOff { UIView.setAnimationsEnabled(false) }
        defer { if animationsOff { UIView.setAnimationsEnabled(true) } }
        #endif
        // Only for the page just asked for (a page appearing much later, say on a tab switch, isn't it).
        guard CACurrentMediaTime() - opening.at < 1 else { pending = nil; return nil }
        // A real (animated) push after all: it slides.
        if let coordinator = page.transitionCoordinator, coordinator.isAnimated, UIView.areAnimationsEnabled { pending = nil; return nil }
        guard let container = page.view.superview else { return nil }
        pending = nil
        let pageView: UIView = page.view
        // Behind: the screen it left (exactly what's on screen now), dimming as the card grows.
        var behind: [UIView] = []
        if let backdrop = opening.backdrop {
            backdrop.frame = container.convert(CGRect(origin: .zero, size: backdrop.bounds.size), from: nil)
            container.insertSubview(backdrop, belowSubview: pageView)
            behind.append(backdrop)
        }
        let dim = UIView(frame: container.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0
        container.insertSubview(dim, belowSubview: pageView)
        behind.append(dim)
        // Hidden until the push has ended: UIKit may still place the page (its frame) after this, which a
        // scaled page can't take; and SwiftUI pushes without animation with UIKit's animations off (on
        // the owner's iPhone), so a card started inside the push jumped to full size.
        pageView.alpha = 0
        let bar = navigation.navigationBar
        bar.alpha = 0
        let views = behind
        Task { @MainActor in
            guard let container = pageView.superview else {
                pageView.alpha = 1; bar.alpha = 1; views.forEach { $0.removeFromSuperview() }; return
            }
            let bounds = pageView.bounds
            let target = container.convert(opening.rect, from: nil)
            let scale = max(0.05, target.width / max(1, bounds.width))
            // From the poster: the page at the poster's width, its top part showing in the poster's shape.
            let mask = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: target.height / scale))
            mask.backgroundColor = .black
            mask.layer.cornerCurve = .continuous
            mask.layer.cornerRadius = corner / scale
            pageView.mask = mask
            pageView.transform = transform(from: pageView, to: target, scale: scale)
            pageView.alpha = 1
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                pageView.transform = .identity
                mask.frame = bounds
                mask.layer.cornerRadius = 0
                dim.alpha = 0.55
                bar.alpha = 1
            } completion: { _ in
                pageView.mask = nil
                pageView.transform = .identity
                pageView.alpha = 1
                bar.alpha = 1
                views.forEach { $0.removeFromSuperview() }
            }
        }
        // Its way back: Back and a swipe right both close it into the poster.
        openings.setObject(opening, forKey: page)
        page.navigationItem.backAction = UIAction { [weak page, weak navigation] _ in
            guard let page, let navigation else { return }
            close(page: page, navigation: navigation, opening: opening)
        }
        let swipe = CardSwipe(page: page, navigation: navigation, opening: opening)
        opening.swipe = swipe
        swipe.attach()
        #if DEBUG
        NavigationTiming.cardShown()
        #endif
        return opening
    }

    /// A page opened as a card closes: it's popped at once (Home answers taps straight away) and a
    /// still of it shrinks into its poster, letting touches through. `dragged`: from where a swipe
    /// left it (smaller, rounded, the screen behind dimmed `dimmed`).
    static func close(page: UIViewController, navigation: UINavigationController, opening: Opening, dragged: Bool = false, dimmed: CGFloat = 0.55) {
        guard !UIAccessibility.isReduceMotionEnabled, let host = navigation.view.superview else {
            _ = navigation.popViewController(animated: true); return
        }
        let shown: UIView = dragged ? page.view : navigation.view
        guard let still = shown.snapshotView(afterScreenUpdates: false) else { _ = navigation.popViewController(animated: true); return }
        still.bounds = shown.bounds
        still.center = host.convert(shown.center, from: shown.superview)
        still.transform = dragged ? page.view.transform : .identity
        still.isUserInteractionEnabled = false
        let mask = UIView(frame: still.bounds)
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        mask.layer.cornerRadius = dragged ? page.view.layer.cornerRadius : 0
        still.mask = mask
        let dim = UIView(frame: navigation.view.frame)
        dim.backgroundColor = .black
        dim.alpha = dimmed
        dim.isUserInteractionEnabled = false
        host.insertSubview(still, aboveSubview: navigation.view)
        host.insertSubview(dim, belowSubview: still)
        opening.swipe?.detach()
        _ = navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()
        navigation.navigationBar.alpha = 1
        let target = host.convert(opening.currentRect, from: nil)
        let bounds = still.bounds
        let scale = max(0.05, target.width / max(1, bounds.width))
        closing.append(still)
        closing.append(dim)
        #if DEBUG
        NavigationTiming.cardClosed()
        #endif
        UIView.animate(withDuration: closeDuration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            still.transform = transform(from: still, to: target, scale: scale)
            mask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: target.height / scale)
            mask.layer.cornerRadius = corner / scale
            dim.alpha = 0
        } completion: { _ in
            still.removeFromSuperview(); dim.removeFromSuperview()
            closing.removeAll { $0 === still || $0 === dim }
        }
        // Into the poster: it fades as it lands, so the poster itself is what's left.
        UIView.animate(withDuration: closeDuration * 0.35, delay: closeDuration * 0.6, options: [.allowUserInteraction]) { still.alpha = 0 }
    }

    /// The transform that puts `view` (full size, centred where it is) at `target`'s top-left (in the
    /// same coordinates as its centre), `scale` times its size.
    private static func transform(from view: UIView, to target: CGRect, scale: CGFloat) -> CGAffineTransform {
        let center = view.center
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        return CGAffineTransform(translationX: target.minX + size.width / 2 - center.x, y: target.minY + size.height / 2 - center.y)
            .scaledBy(x: scale, y: scale)
    }

    /// The navigation controller a view is shown in (its nearest view controller's).
    static func navigationController(of view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let navigation = current as? UINavigationController { return navigation }
            if let controller = current as? UIViewController, let navigation = controller.navigationController { return navigation }
            responder = current.next
        }
        return nil
    }
}

/// A swipe right on a page opened as a card: the card follows the finger, smaller and rounded with the
/// screen it came from dimmed behind, and on letting go shrinks into its poster (or springs back if it
/// wasn't swiped far). From the left edge anywhere, and across the page except on a sideways list that
/// can still scroll back. UIKit's own swipe back (a slide) waits for it to fail.
@MainActor final class CardSwipe: NSObject, UIGestureRecognizerDelegate {
    private weak var page: UIViewController?
    private weak var navigation: UINavigationController?
    private let opening: CardTransition.Opening
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private var behind: [UIView] = []
    private var dim: UIView?
    private var progress: CGFloat = 0
    init(page: UIViewController, navigation: UINavigationController, opening: CardTransition.Opening) {
        self.page = page; self.navigation = navigation; self.opening = opening
    }
    func attach() {
        guard let view = page?.view else { return }
        pan.delegate = self
        view.addGestureRecognizer(pan)
        navigation?.interactivePopGestureRecognizer?.require(toFail: pan)
        navigation?.interactiveContentPopGestureRecognizer?.require(toFail: pan)
    }
    func detach() { pan.view?.removeGestureRecognizer(pan) }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = pan.view, navigation?.topViewController === page else { return false }
        let velocity = pan.velocity(in: view)
        guard velocity.x > 0, velocity.x > abs(velocity.y) * 1.2 else { return false }
        let point = pan.location(in: view)
        if point.x < 32 { return true }
        // On a sideways list that can still scroll back, the list scrolls.
        var hit = view.hitTest(point, with: nil)
        while let current = hit, current !== view {
            if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 { return false }
            hit = current.superview
        }
        return true
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let page, let navigation, let pageView = page.view, let container = pageView.superview else { return }
        let width = max(1, container.bounds.width)
        switch gesture.state {
        case .began:
            if let backdrop = opening.backdrop {
                backdrop.frame = container.convert(CGRect(origin: .zero, size: backdrop.bounds.size), from: nil)
                backdrop.alpha = 1
                container.insertSubview(backdrop, belowSubview: pageView)
                behind.append(backdrop)
            }
            let dim = UIView(frame: container.bounds)
            dim.backgroundColor = .black
            dim.alpha = 0.55
            container.insertSubview(dim, belowSubview: pageView)
            behind.append(dim)
            self.dim = dim
            pageView.layer.cornerCurve = .continuous
            pageView.layer.masksToBounds = true
        case .changed:
            let moved = gesture.translation(in: container)
            progress = min(1, max(0, moved.x / width))
            let scale = 1 - progress * 0.35
            pageView.transform = CGAffineTransform(translationX: moved.x * 0.45, y: moved.y * 0.25).scaledBy(x: scale, y: scale)
            pageView.layer.cornerRadius = 40 * min(1, progress * 4)
            dim?.alpha = 0.55 * (1 - progress)
            navigation.navigationBar.alpha = max(0, 1 - progress * 3)
        case .ended, .cancelled, .failed:
            let speed = gesture.velocity(in: container).x
            if gesture.state == .ended, progress > 0.22 || speed > 700 {
                let dimmed = dim?.alpha ?? 0
                behind.forEach { $0.removeFromSuperview() }
                behind = []
                CardTransition.close(page: page, navigation: navigation, opening: opening, dragged: true, dimmed: dimmed)
                pageView.transform = .identity
                pageView.layer.cornerRadius = 0
                pageView.layer.masksToBounds = false
            } else {
                let views = behind
                behind = []
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    pageView.transform = .identity
                    pageView.layer.cornerRadius = 0
                    self.dim?.alpha = 0.55
                    navigation.navigationBar.alpha = 1
                } completion: { _ in
                    pageView.layer.masksToBounds = false
                    views.forEach { $0.removeFromSuperview() }
                }
            }
            progress = 0
        default: break
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
}

/// Anything that opens a title (a poster, a card, a row: a library id, a TMDB route or a season), as a
/// card growing out of it (AppRouter.openFromPoster): a NavigationLink's push always slid, whatever the
/// transaction, so the card never opened. Its label is the card's source.
struct CardLink<Value: Hashable, Label: View>: View {
    let value: Value
    @ViewBuilder var label: () -> Label
    @Environment(AppRouter.self) private var router
    var body: some View {
        Button { router.openFromPoster(value) } label: { label().background(CardSourceMarker()) }
    }
}

/// Notes where each touch starts (for the card's poster) and claims none: it fails at once, delaying
/// or cancelling nothing.
final class CardTouchSpy: UIGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { CardTransition.lastTouch = (touch.location(in: nil), touch.window, CACurrentMediaTime()) }
        state = .failed
    }
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Behind a poster that opens its title (`zoomSource`): an empty UIKit view whose frame is read only
/// when a title opens, so the card can grow out of it and shrink back into it.
struct CardSourceMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        CardTransition.register(view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
