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
    /// How long the card grows or shrinks (a critically damped spring: no tail after it).
    static let duration: TimeInterval = 0.36
    /// The poster's corner radius the card starts from and ends on.
    private static let corner: CGFloat = 12

    /// What a page opened as a card keeps for its way back: the poster (weakly: its view stays laid
    /// out under the page) and where it was.
    @MainActor final class Opening {
        weak var source: UIView?
        let rect: CGRect
        /// The still of the screen it left, behind the card while it grows (let go after: it's a
        /// screen-sized picture).
        var backdrop: UIView?
        init(source: UIView, rect: CGRect, backdrop: UIView?) { self.source = source; self.rect = rect; self.backdrop = backdrop }
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
    /// The last touch down on the screen, in window coordinates (CardTouchSpy).
    static var lastTouch: (point: CGPoint, at: CFTimeInterval)?
    /// The opening the next page to appear plays (set as its push is asked for).
    private static var pending: Opening?
    /// Stills of pages still shrinking: gone at once if another title opens meanwhile.
    private static var closing: [UIView] = []

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// A page is about to be pushed: whether it opens as a card from the poster just touched (then
    /// it's pushed without UIKit's animation).
    static func prepareOpen() -> Bool {
        guard !UIAccessibility.isReduceMotionEnabled, let touch = lastTouch, CACurrentMediaTime() - touch.at < 1.0,
              let window = keyWindow else { return false }
        var best: (view: UIView, rect: CGRect)?
        for view in sources.allObjects where view.window === window {
            let rect = view.convert(view.bounds, to: nil)
            guard rect.width > 20, rect.height > 20, rect.contains(touch.point) else { continue }
            if let found = best, found.rect.width * found.rect.height <= rect.width * rect.height { continue }
            best = (view, rect)
        }
        guard let best else { return false }
        for still in closing { still.removeFromSuperview() }
        closing = []
        lastTouch = nil
        pending = Opening(source: best.view, rect: best.rect, backdrop: window.snapshotView(afterScreenUpdates: false))
        #if DEBUG
        NavigationTiming.cardOpened()
        #endif
        return true
    }

    /// The page pushed for that opening has appeared: it grows out of the poster. Returns the opening
    /// for the page's way back (nil: not opened as a card).
    static func open(page: UIViewController, navigation: UINavigationController) -> Opening? {
        guard let opening = pending else { return nil }
        pending = nil
        if let coordinator = page.transitionCoordinator, coordinator.isAnimated { return nil }
        guard let container = page.view.superview else { return nil }
        let pageView: UIView = page.view
        let bounds = pageView.bounds
        let target = container.convert(opening.rect, from: nil)
        let scale = max(0.05, target.width / max(1, bounds.width))
        // Behind: the screen it left, dimming as the card grows.
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
        // From the poster: the page at the poster's width, its top part showing in the poster's shape.
        let mask = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: target.height / scale))
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        mask.layer.cornerRadius = corner / scale
        pageView.mask = mask
        pageView.transform = transform(from: pageView, to: target, scale: scale, in: container)
        let bar = navigation.navigationBar
        bar.alpha = 0
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
            bar.alpha = 1
            behind.forEach { $0.removeFromSuperview() }
            opening.backdrop = nil
        }
        return opening
    }

    /// Back on a page opened as a card: it's popped at once (Home answers taps straight away) and a
    /// still of it shrinks into its poster, letting touches through.
    static func close(page: UIViewController, navigation: UINavigationController, opening: Opening) {
        guard !UIAccessibility.isReduceMotionEnabled, let host = navigation.view.superview,
              let still = navigation.view.snapshotView(afterScreenUpdates: false) else {
            _ = navigation.popViewController(animated: true); return
        }
        still.frame = navigation.view.frame
        still.isUserInteractionEnabled = false
        let dim = UIView(frame: navigation.view.frame)
        dim.backgroundColor = .black
        dim.alpha = 0.55
        dim.isUserInteractionEnabled = false
        host.insertSubview(still, aboveSubview: navigation.view)
        host.insertSubview(dim, belowSubview: still)
        _ = navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()
        let target = host.convert(opening.currentRect, from: nil)
        let bounds = still.bounds
        let scale = max(0.05, target.width / max(1, bounds.width))
        let mask = UIView(frame: bounds)
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        still.mask = mask
        closing.append(still)
        closing.append(dim)
        #if DEBUG
        NavigationTiming.cardClosed()
        #endif
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            still.transform = transform(from: still, to: target, scale: scale, in: host)
            mask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: target.height / scale)
            mask.layer.cornerRadius = corner / scale
            dim.alpha = 0
        } completion: { _ in
            still.removeFromSuperview(); dim.removeFromSuperview()
            closing.removeAll { $0 === still || $0 === dim }
        }
        // Into the poster: it fades as it lands, so the poster itself is what's left.
        UIView.animate(withDuration: duration * 0.35, delay: duration * 0.6, options: [.allowUserInteraction]) { still.alpha = 0 }
    }

    /// The transform that puts `view` (full size, centred where it is in `container`) at `target`'s
    /// top-left, `scale` times its size.
    private static func transform(from view: UIView, to target: CGRect, scale: CGFloat, in container: UIView) -> CGAffineTransform {
        let center = view.center
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        return CGAffineTransform(translationX: target.minX + size.width / 2 - center.x, y: target.minY + size.height / 2 - center.y)
            .scaledBy(x: scale, y: scale)
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
        if let touch = touches.first { CardTransition.lastTouch = (touch.location(in: nil), CACurrentMediaTime()) }
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
