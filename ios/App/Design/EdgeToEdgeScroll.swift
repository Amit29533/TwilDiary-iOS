import SwiftUI
import UIKit

/// The same material and feather used by Cast/Character/Voice Actor pages.
/// Only this leaf reads scroll progress, keeping large shelves out of scroll updates.
struct FeatheredHeaderBackdrop: View {
    let state: CompactHeaderState
    let height: CGFloat
    /// Pages whose title or switcher lives in the bar keep it frosted from the start.
    var always = false
    // `height` is the page's top inset: the status bar, plus the navigation bar on pushed pages.
    // Covering all of it (and feathering a little below) keeps scrolled text from showing through
    // under the compact title and the toolbar buttons.
    var body: some View {
        Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.35))
            .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                .init(color: .white, location: 0.78), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom))
            .opacity(always ? 1 : Double(state.progress)).frame(height: height + 14)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Preserve the initial content position, then let scrolled content reach under
/// the status/navigation area. Keyboard insets and horizontal shelves remain native.
struct EdgeToEdgeScroll<Content: View>: View {
    /// Keep the top bar frosted even at the top (for pages with a title or switcher in the bar).
    var frosted = false
    @ViewBuilder let content: Content
    @State private var header = CompactHeaderState()
    var body: some View {
        GeometryReader { geometry in
            ScrollView { content }
                .contentMargins(.top, geometry.safeAreaInsets.top, for: .scrollContent)
                .contentMargins(.bottom, geometry.safeAreaInsets.bottom, for: .scrollContent)
                .ignoresSafeArea(.container, edges: .vertical)
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollGeometryChange(for: CGFloat.self, of: { value in
                    (min(1, max(0, (value.contentOffset.y + value.contentInsets.top) / 48)) * 32).rounded() / 32
                }) { _, progress in header.update(progress) }
                .overlay(alignment: .top) {
                    if geometry.safeAreaInsets.top > 0 {
                        FeatheredHeaderBackdrop(state: header, height: geometry.safeAreaInsets.top, always: frosted)
                            .offset(y: -geometry.safeAreaInsets.top)
                    }
                }
        }.toolbarBackground(.hidden, for: .navigationBar)
    }
}
