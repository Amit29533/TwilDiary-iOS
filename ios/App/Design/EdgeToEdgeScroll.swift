import SwiftUI
import UIKit

/// The same material and feather used by Cast/Character/Voice Actor pages.
/// Only this leaf reads scroll progress, keeping large shelves out of scroll updates.
struct FeatheredHeaderBackdrop: View {
    let state: CompactHeaderState
    let height: CGFloat
    // A pushed page's geometry also includes its navigation bar. The reference
    // only blurs the status area, so cap against the actual window safe inset.
    private var statusHeight: CGFloat {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        return min(height, max(0, window?.safeAreaInsets.top ?? 0))
    }
    var body: some View {
        Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.22))
            .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                .init(color: .white, location: 0.55), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom))
            .opacity(Double(state.progress)).frame(height: statusHeight)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Preserve the initial content position, then let scrolled content reach under
/// the status/navigation area. Keyboard insets and horizontal shelves remain native.
struct EdgeToEdgeScroll<Content: View>: View {
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
                        FeatheredHeaderBackdrop(state: header, height: geometry.safeAreaInsets.top)
                            .offset(y: -geometry.safeAreaInsets.top)
                    }
                }
        }.toolbarBackground(.hidden, for: .navigationBar)
    }
}
