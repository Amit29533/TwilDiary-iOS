import SwiftUI

/// Press and hold artwork (a poster, a cover, a portrait): it lifts into a large preview card with
/// its title, the page blurs behind it and a short menu opens under it (iOS's own peek, as in
/// Photos or Instagram). View full screen opens the zoomable viewer; Share sends the image.
private struct FullScreenArtworkModifier: ViewModifier {
    let path: String?
    let title: String
    /// Width over height of this kind of artwork: 2:3 posters and portraits, 16:9 covers.
    let aspect: CGFloat
    @State private var shown = false
    func body(content: Content) -> some View {
        if let path, !path.isEmpty {
            content
                .contextMenu {
                    Button("View full screen", systemImage: "arrow.up.left.and.arrow.down.right") { shown = true }
                    if let url = URL(string: path), url.scheme == "https" {
                        ShareLink(item: url, subject: Text(title)) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } preview: {
                    ArtworkPeek(path: path, title: title, aspect: aspect)
                }
                .accessibilityAction(named: "View full screen") { shown = true }
                .fullScreenCover(isPresented: $shown) { FullScreenArtwork(path: path, title: title) }
        } else {
            content
        }
    }
}

/// The lifted card: the title on top, then the artwork whole, at the largest public size.
private struct ArtworkPeek: View {
    let path: String
    let title: String
    let aspect: CGFloat
    var body: some View {
        let width: CGFloat = aspect >= 1 ? 360 : 300
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 44, alignment: .leading)
            Artwork(path: path, title: title, contentMode: .fill, prefersOriginal: true)
                .frame(width: width, height: (width / max(aspect, 0.3)).rounded())
        }.frame(width: width).background(Color(webHex: "#16151b"))
    }
}

extension View {
    /// Press and hold for a peek of `path` (with View full screen and Share).
    func fullScreenArtwork(_ path: String?, title: String, aspect: CGFloat = 2.0 / 3.0) -> some View {
        modifier(FullScreenArtworkModifier(path: path, title: title, aspect: aspect))
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
