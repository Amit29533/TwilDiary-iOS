import SwiftUI
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

/// The content follows the finger a little (rubber band), then springs to the next category.
private struct CategorySwipe: ViewModifier {
    @Binding var selection: LibraryCategory
    let enabled: Bool
    let exempt: CGRect
    /// Springs back (the bounce) when the finger lifts; follows the finger exactly while dragging.
    @GestureState(resetTransaction: Transaction(animation: Motion.spring)) private var pull: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        // The whole area takes the swipe, including the gaps around a short category's cards.
        content.contentShape(Rectangle()).coordinateSpace(.named(Motion.swipeSpace)).offset(x: reduceMotion ? 0 : pull)
            .simultaneousGesture(swipe, including: enabled ? .all : .subviews)
    }
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .named(Motion.swipeSpace))
            .updating($pull) { value, state, _ in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.6, !exempt.contains(value.startLocation) else { return }
                // Resistance: the page moves a fraction of the finger, more so at the ends.
                let atEnd = neighbour(dx < 0 ? 1 : -1) == nil
                state = dx * (atEnd ? 0.12 : 0.28)
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > 64, abs(dx) > abs(dy) * 1.6, !exempt.contains(value.startLocation), let next = neighbour(dx < 0 ? 1 : -1) else { return }
                withAnimation(Motion.spring(reduceMotion)) { selection = next }
            }
    }
    private func neighbour(_ step: Int) -> LibraryCategory? {
        let all = LibraryCategory.allCases
        guard let index = all.firstIndex(of: selection), all.indices.contains(index + step) else { return nil }
        return all[index + step]
    }
}
