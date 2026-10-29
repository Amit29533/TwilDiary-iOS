import SwiftUI
import UIKit
import TwilDiaryCore

/// One spring for the whole app: quick to settle, with a little bounce.
enum Motion {
    static var spring: Animation { .spring(duration: 0.42, bounce: 0.3) }
    static var press: Animation { .spring(duration: 0.28, bounce: 0.45) }
    /// `nil` under Reduce Motion, so changes simply appear.
    static func spring(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : spring }
    /// The coordinate space a category swipe measures in; rows that scroll sideways report their frame in it.
    static let swipeSpace = "category-swipe"
}

/// Sheet heights that follow their content: short text gets a short sheet, long text a tall one.
/// Capped below full screen, so the sheet stays on the system glass (the opaque full-height sheet
/// is what made text colours jump); longer content scrolls inside.
enum SheetFit {
    @MainActor static var maxHeight: CGFloat {
        ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800) * 0.88
    }
    /// `content` is the measured scroll content; `chrome` the title bar and bottom inset around it.
    @MainActor static func detent(_ content: CGFloat, chrome: CGFloat) -> PresentationDetent {
        .height(min(max(content, 160) + chrome, maxHeight))
    }
}

/// Source IDs for the zoom from a poster into its title page.
enum ZoomID {
    static func title(_ id: String) -> String { "title:" + id }
    static func catalog(_ route: CatalogRoute) -> String { "catalog:\(route.kind.rawValue):\(route.id)" }
    static func scoped(_ scope: String, _ id: String) -> String { scope + "/" + id }
}

private struct ZoomNamespaceKey: EnvironmentKey {
    static var defaultValue: Namespace.ID? { nil }
}
private struct ZoomScopeKey: EnvironmentKey {
    static var defaultValue: String { "" }
}
extension EnvironmentValues {
    /// The app's navigation namespace; posters zoom into the pages they open.
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
    /// The tab a source belongs to, so the same title in two tabs never zooms from the wrong one.
    var zoomScope: String {
        get { self[ZoomScopeKey.self] }
        set { self[ZoomScopeKey.self] = newValue }
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.zoomNamespace) private var namespace
    @Environment(\.zoomScope) private var scope
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: ZoomID.scoped(scope, id), in: namespace) } else { content }
    }
}

extension View {
    /// Marks the artwork a title page zooms out of, and back into on return.
    func zoomSource(_ id: String) -> some View { modifier(ZoomSource(id: id)) }
    /// A sideways swipe moves between All, Movies, Shows and Anime; it never changes app tabs.
    /// `ignoring` is a sideways-scrolling row (in `Motion.swipeSpace`): drags that start there scroll it instead.
    func categorySwipe(_ selection: Binding<LibraryCategory>, enabled: Bool = true, ignoring exempt: CGRect = .null) -> some View {
        modifier(CategorySwipe(selection: selection, enabled: enabled, exempt: exempt))
    }
}

/// Cards and posters sink slightly under the finger and spring back.
struct SpringPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration) }
    private struct Pressed: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}
extension ButtonStyle where Self == SpringPressStyle {
    static var springPress: SpringPressStyle { SpringPressStyle() }
}

/// A side swipe moves to the next category. The page itself stays still (no rubber band, no
/// bounce): the cards swap in place and only the category pill slides, as a segmented control does.
private struct CategorySwipe: ViewModifier {
    @Binding var selection: LibraryCategory
    let enabled: Bool
    let exempt: CGRect
    func body(content: Content) -> some View {
        // The whole area takes the swipe, including the gaps around a short category's cards.
        content.contentShape(Rectangle()).coordinateSpace(.named(Motion.swipeSpace))
            .gesture(SidePan(enabled: enabled, exempt: exempt) { forward in
                if let next = neighbour(forward ? 1 : -1) { selection = next }
            })
    }
    private func neighbour(_ step: Int) -> LibraryCategory? {
        let all = LibraryCategory.allCases
        guard let index = all.firstIndex(of: selection), all.indices.contains(index + step) else { return nil }
        return all[index + step]
    }
}

/// A UIKit pan for side swipes. SwiftUI's drag gesture inside a scroll view competed with scrolling,
/// so a scroll could end as a tap on a poster. This one only begins when the finger moves
/// sideways; a vertical drag fails it at once and the scroll view keeps the touch, and it never
/// cancels or delays touches meant for the cards.
private struct SidePan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let exempt: CGRect
    let onSwipe: (_ forward: Bool) -> Void
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false; pan.delaysTouchesBegan = false; pan.delaysTouchesEnded = false
        return pan
    }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began:
            // Where the finger first went down, in the same space as the exempt row's frame.
            let now = context.converter.location(in: .named(Motion.swipeSpace))
            context.coordinator.start = CGPoint(x: now.x - translation.x, y: now.y - translation.y)
        case .ended:
            guard abs(translation.x) > 64, abs(translation.x) > abs(translation.y) * 1.6,
                  !exempt.contains(context.coordinator.start) else { return }
            onSwipe(translation.x < 0)
        default: break
        }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true
        var start = CGPoint.zero
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.6
        }
        // Side by side with the scroll view and the cards' own buttons.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
