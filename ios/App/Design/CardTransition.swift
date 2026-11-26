import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Title pages open as a card from their poster and close back into it, as Netflix's do (owner's
/// choice). UIKit's own transitions keep the next page or Back waiting until they've ended (the zoom
/// 0.87 s, the slide 0.52 s: NavigationRoundTripProbe); here the page is pushed and popped without
/// one, so navigation is free at once, and the card's growing and shrinking is drawn on top, always
/// as stills (pictures): opening, a still of the new page grows out of the poster over a still of the
/// screen it left, the live page loading under them; closing, a still of the page shrinks into the
/// poster over the screen it returns to, letting every touch through. A swipe right closes it the
/// same way, the card following the finger (CardSwipe). (The live page grown under a moving rounded
/// mask was drawn again on every frame, and stuttered on the owner's iPhone.) Off with Reduce Motion.
@MainActor enum CardTransition {
    /// How long the card grows (a critically damped spring: no tail after it).
    static let duration: TimeInterval = 0.45
    /// How long it shrinks back into its poster.
    static let closeDuration: TimeInterval = 0.4
    /// The poster's corner radius the card starts from and ends on.
    private static let corner: CGFloat = 12

    /// What a page opened as a card keeps for its way back: the poster (weakly: its view stays laid
    /// out under the page), where it was, and a still of the screen it left, kept over the page
    /// (hidden once the card has grown) for the card's growing and its swipe. Hidden rather than taken
    /// out: a still taken out of the window and put back showed black (owner's recording).
    @MainActor final class Opening {
        weak var source: UIView?
        let rect: CGRect
        /// When it was set up (a push that never showed its page doesn't play on a later one).
        let at = CACurrentMediaTime()
        let backdrop: UIView
        /// The navigation it's pushed in, and its top page before (to find the page once pushed).
        weak var navigation: UINavigationController?
        weak var previousTop: UIViewController?
        /// The page it opened (once shown), and the views of its card still growing.
        weak var page: UIViewController?
        var growing: [UIView] = []
        /// The swipe that closes it (held here: the gesture recogniser doesn't keep its target).
        var swipe: CardSwipe?
        init(source: UIView, rect: CGRect, backdrop: UIView, navigation: UINavigationController?) {
            self.source = source; self.rect = rect; self.backdrop = backdrop
            self.navigation = navigation; previousTop = navigation?.topViewController
        }
        /// The poster's place on screen now (it's back in the window once the page is gone).
        var currentRect: CGRect {
            guard let source, source.window != nil else { return rect }
            let now = source.convert(source.bounds, to: nil)
            return now.width > 1 ? now : rect
        }
        /// The screen it left shown over the page (`page`, in `container`).
        func showBackdrop(over page: UIView, in container: UIView) {
            if let navigation { backdrop.frame = container.convert(navigation.view.bounds, from: navigation.view) }
            container.insertSubview(backdrop, aboveSubview: page)
            backdrop.isHidden = false
        }
        /// Everything it put on screen taken away (its page is gone).
        func clear() {
            growing.forEach { $0.removeFromSuperview() }
            growing = []
            backdrop.removeFromSuperview()
        }
    }

    /// Posters that open their title as a card (CardSourceMarker views).
    private static let sources = NSHashTable<UIView>.weakObjects()
    static func register(_ view: UIView) { sources.add(view) }
    /// The last touch down on the screen, in its window's coordinates (CardTouchSpy).
    static var lastTouch: (point: CGPoint, window: UIWindow?, at: CFTimeInterval)?
    /// The opening the next page to appear plays (set as its push is asked for).
    private static var pending: Opening?
    /// Each page shown as a card, with its opening (until it closes, or its page is found gone).
    private static var live: [Opening] = []
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
        // Pages that went another way (back to the tab's first page, say): their stills go.
        live.removeAll { opening in
            guard opening.page?.navigationController == nil else { return false }
            opening.clear()
            return true
        }
        lastTouch = nil
        // The screen without the tab bar (the window's still had one, which the glass tab bar on top
        // showed as a ghost while the card grew).
        let backdrop = navigation.view.snapshotView(afterScreenUpdates: false) ?? {
            let plain = UIView()
            plain.backgroundColor = .black
            return plain
        }()
        pending = Opening(source: best.view, rect: best.rect, backdrop: backdrop, navigation: navigation)
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
        // Until its card has grown, the screen it left covers the page (which goes on loading under it),
        // dimming as the card grows.
        opening.showBackdrop(over: pageView, in: container)
        let dim = UIView(frame: container.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        container.insertSubview(dim, aboveSubview: opening.backdrop)
        opening.growing = [dim]
        let bar = navigation.navigationBar
        bar.alpha = 0
        // Started once the push has ended: SwiftUI pushes without animation with UIKit's animations off
        // (on the owner's iPhone), and a card started inside the push jumped to full size.
        Task { @MainActor in
            let backdrop = opening.backdrop
            // The page as it first shows, as a still: the card is that picture.
            guard let container = pageView.superview, opening.growing.contains(dim),
                  let still = pageView.snapshotView(afterScreenUpdates: true) else {
                dim.removeFromSuperview(); backdrop.isHidden = true; bar.alpha = 1; return
            }
            let bounds = pageView.bounds
            still.bounds = bounds
            still.center = pageView.center
            still.isUserInteractionEnabled = false
            let target = container.convert(opening.rect, from: nil)
            let scale = max(0.05, target.width / max(1, bounds.width))
            // From the poster: the page at the poster's width, its top part showing in the poster's shape.
            let mask = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: target.height / scale))
            mask.backgroundColor = .black
            mask.layer.cornerCurve = .continuous
            mask.layer.cornerRadius = corner / scale
            still.mask = mask
            container.insertSubview(still, aboveSubview: dim)
            opening.growing.append(still)
            still.transform = transform(from: still, to: target, scale: scale)
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                still.transform = .identity
                mask.frame = bounds
                mask.layer.cornerRadius = 0
                dim.alpha = 0.55
                bar.alpha = 1
            } completion: { _ in
                still.removeFromSuperview()
                dim.removeFromSuperview()
                opening.growing.removeAll { $0 === still || $0 === dim }
                backdrop.isHidden = true
                bar.alpha = 1
            }
        }
        // Its way back: Back and a swipe right both close it into the poster.
        opening.page = page
        live.append(opening)
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
    /// still of it shrinks into its poster, letting touches through. `dragged`: the still a swipe was
    /// moving, from where the finger left it (smaller, rounded, the screen behind dimmed `dimmed`).
    static func close(page: UIViewController, navigation: UINavigationController, opening: Opening, dragged: UIView? = nil, dimmed: CGFloat = 0.55) {
        opening.swipe?.detach()
        live.removeAll { $0 === opening }
        guard !UIAccessibility.isReduceMotionEnabled, let host = navigation.view.superview else {
            dragged?.removeFromSuperview(); opening.clear()
            _ = navigation.popViewController(animated: true); return
        }
        let still: UIView
        let mask = UIView()
        if let dragged {
            let center = host.convert(dragged.center, from: dragged.superview)
            host.insertSubview(dragged, aboveSubview: navigation.view)
            dragged.center = center
            mask.frame = dragged.bounds
            mask.layer.cornerRadius = dragged.layer.cornerRadius
            dragged.layer.cornerRadius = 0
            dragged.layer.masksToBounds = false
            still = dragged
        } else {
            guard let shot = navigation.view.snapshotView(afterScreenUpdates: false) else {
                opening.clear(); _ = navigation.popViewController(animated: true); return
            }
            shot.bounds = navigation.view.bounds
            shot.center = navigation.view.center
            host.insertSubview(shot, aboveSubview: navigation.view)
            mask.frame = shot.bounds
            still = shot
        }
        still.isUserInteractionEnabled = false
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        still.mask = mask
        let dim = UIView(frame: navigation.view.frame)
        dim.backgroundColor = .black
        dim.alpha = dimmed
        dim.isUserInteractionEnabled = false
        host.insertSubview(dim, belowSubview: still)
        opening.clear()
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

/// A swipe right on a page opened as a card: a still of the page follows the finger, smaller and
/// rounded, over the screen it came from (dimmed), and on letting go shrinks into its poster (or
/// springs back if it wasn't swiped far, the live page under it all along). From the left edge
/// anywhere, and across the page except on a sideways list that can still scroll back. UIKit's own
/// swipe back (a slide) waits for it to fail.
@MainActor final class CardSwipe: NSObject, UIGestureRecognizerDelegate {
    private weak var page: UIViewController?
    private weak var navigation: UINavigationController?
    private let opening: CardTransition.Opening
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    /// The card being swiped, and the dark over the screen behind it.
    private var still: UIView?
    private var dim: UIView?
    /// The bar's alpha as the swipe began (none while a trailer hides it, say).
    private var barAlpha: CGFloat = 1
    private var progress: CGFloat = 0
    init(page: UIViewController, navigation: UINavigationController, opening: CardTransition.Opening) {
        self.page = page; self.navigation = navigation; self.opening = opening
    }
    func attach() {
        guard let view = page?.view else { return }
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }
    func detach() { pan.view?.removeGestureRecognizer(pan) }

    /// UIKit's swipes back wait for this one to fail (asked each time: nothing stays on them once the
    /// page is gone, as `require(toFail:)` would).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let navigation else { return false }
        return other === navigation.interactivePopGestureRecognizer || other === navigation.interactiveContentPopGestureRecognizer
    }

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
            // The page as a still over the screen it came from; the live page stays put under them.
            guard let still = pageView.snapshotView(afterScreenUpdates: false) else { return }
            still.bounds = pageView.bounds
            still.center = pageView.center
            still.isUserInteractionEnabled = false
            still.layer.cornerCurve = .continuous
            still.layer.masksToBounds = true
            opening.showBackdrop(over: pageView, in: container)
            let dim = UIView(frame: container.bounds)
            dim.backgroundColor = .black
            dim.alpha = 0.55
            dim.isUserInteractionEnabled = false
            container.insertSubview(dim, aboveSubview: opening.backdrop)
            container.insertSubview(still, aboveSubview: dim)
            self.still = still
            self.dim = dim
            barAlpha = navigation.navigationBar.alpha
        case .changed:
            guard let still else { return }
            let moved = gesture.translation(in: container)
            progress = min(1, max(0, moved.x / width))
            let scale = 1 - progress * 0.35
            still.transform = CGAffineTransform(translationX: moved.x * 0.45, y: moved.y * 0.25).scaledBy(x: scale, y: scale)
            still.layer.cornerRadius = 40 * min(1, progress * 4)
            dim?.alpha = 0.55 * (1 - progress)
            navigation.navigationBar.alpha = barAlpha * max(0, 1 - progress * 3)
        case .ended, .cancelled, .failed:
            guard let still else { return }
            let dim = self.dim
            self.still = nil
            self.dim = nil
            let speed = gesture.velocity(in: container).x
            if gesture.state == .ended, progress > 0.22 || speed > 700 {
                let dimmed = dim?.alpha ?? 0
                dim?.removeFromSuperview()
                CardTransition.close(page: page, navigation: navigation, opening: opening, dragged: still, dimmed: dimmed)
            } else {
                let backdrop = opening.backdrop
                let bar = barAlpha
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    still.transform = .identity
                    still.layer.cornerRadius = 0
                    dim?.alpha = 0.55
                    navigation.navigationBar.alpha = bar
                } completion: { _ in
                    still.removeFromSuperview()
                    dim?.removeFromSuperview()
                    backdrop.isHidden = true
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
