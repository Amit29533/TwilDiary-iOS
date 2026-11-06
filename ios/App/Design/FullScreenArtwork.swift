import SwiftUI

/// Press and hold artwork (a poster, a cover, a portrait) to see it full screen.
private struct FullScreenArtworkModifier: ViewModifier {
    let path: String?
    let title: String
    @State private var shown = false
    func body(content: Content) -> some View {
        if let path, !path.isEmpty {
            content
                .onLongPressGesture(minimumDuration: 0.4) { shown = true }
                .sensoryFeedback(.impact(weight: .medium), trigger: shown) { _, now in now }
                .accessibilityAction(named: "View full screen") { shown = true }
                .fullScreenCover(isPresented: $shown) { FullScreenArtwork(path: path, title: title) }
        } else {
            content
        }
    }
}

extension View {
    /// Press and hold to see `path` full screen, at its largest public size.
    func fullScreenArtwork(_ path: String?, title: String) -> some View {
        modifier(FullScreenArtworkModifier(path: path, title: title))
    }
}

/// The whole image on black: pinch or double-tap to zoom, drag to look around when zoomed,
/// swipe down (or the close button) to go back.
struct FullScreenArtwork: View {
    let path: String?
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(scale > 1 ? 1 : max(0.35, 1 - Double(offset.height) / 500)).ignoresSafeArea()
            Artwork(path: path, title: title, contentMode: .fit, prefersOriginal: true)
                .scaleEffect(scale)
                .offset(offset)
                .ignoresSafeArea()
                .gesture(MagnifyGesture()
                    .onChanged { value in scale = min(5, max(1, settledScale * value.magnification)) }
                    .onEnded { _ in
                        settledScale = scale
                        if scale <= 1 { reset() }
                    })
                .simultaneousGesture(DragGesture()
                    .onChanged { value in
                        if scale > 1 {
                            offset = CGSize(width: settledOffset.width + value.translation.width,
                                            height: settledOffset.height + value.translation.height)
                        } else {
                            offset = CGSize(width: 0, height: max(0, value.translation.height))
                        }
                    }
                    .onEnded { value in
                        if scale > 1 { settledOffset = offset }
                        else if value.translation.height > 120 { dismiss() }
                        else { withAnimation(reduceMotion ? nil : .snappy) { offset = .zero } }
                    })
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                    }
                }
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isImage)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.black.opacity(0.55), in: Circle())
            }.padding(16).accessibilityLabel("Close").accessibilityIdentifier("full-screen-artwork-close")
        }.statusBarHidden()
            .accessibilityIdentifier("full-screen-artwork")
    }
    private func reset() { scale = 1; settledScale = 1; offset = .zero; settledOffset = .zero }
}
