import SwiftUI
import UIKit

/// Press and hold artwork (a poster, a cover, a portrait): it pops up as a large card with its title
/// while the page blurs behind it (iOS's own peek, as in Photos or Instagram). Tap the card to open
/// it full screen; the menu under it has View full screen and Share.
private struct FullScreenArtworkModifier: ViewModifier {
    let path: String?
    let title: String
    /// Width over height of this kind of artwork: 2:3 posters and portraits, 16:9 covers.
    let aspect: CGFloat
    @State private var shown = false
    func body(content: Content) -> some View {
        if let path, !path.isEmpty {
            content
                .overlay { ArtworkPeekInteraction(path: path, title: title, aspect: aspect) { open() } }
                .accessibilityAction(named: "View full screen") { open() }
                // No slide up from the bottom: the cover appears at once and the viewer zooms in itself.
                .fullScreenCover(isPresented: $shown) {
                    FullScreenArtwork(path: path, title: title).presentationBackground(.clear)
                }
        } else {
            content
        }
    }
    private func open() {
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { shown = true }
    }
}

/// The popped-up card: just the artwork, whole, at the largest public size (no text over it).
private struct ArtworkPeek: View {
    let path: String
    let title: String
    let aspect: CGFloat
    static func size(aspect: CGFloat) -> CGSize {
        let width: CGFloat = aspect >= 1 ? 360 : 300
        return CGSize(width: width, height: (width / max(aspect, 0.3)).rounded())
    }
    var body: some View {
        let size = Self.size(aspect: aspect)
        Artwork(path: path, title: title, contentMode: .fill, prefersOriginal: true)
            .frame(width: size.width, height: size.height)
            .background(Color(webHex: "#16151b"))
    }
}

/// UIKit's context menu, which (unlike SwiftUI's) lets a tap on the preview do something: here,
/// open the artwork full screen once the peek has closed.
private struct ArtworkPeekInteraction: UIViewRepresentable {
    let path: String
    let title: String
    let aspect: CGFloat
    let open: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: ArtworkPeekInteraction
        init(_ parent: ArtworkPeekInteraction) { self.parent = parent }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            let path = parent.path, title = parent.title, aspect = parent.aspect
            let shareURL = URL(string: path).flatMap { $0.scheme == "https" ? $0 : nil }
            // UIKit calls both on the main thread (their types are main-actor in the SDK).
            return UIContextMenuConfiguration(identifier: nil, previewProvider: {
                let host = UIHostingController(rootView: ArtworkPeek(path: path, title: title, aspect: aspect))
                host.preferredContentSize = ArtworkPeek.size(aspect: aspect)
                host.view.backgroundColor = .clear
                return host
            }, actionProvider: { [weak self, weak interaction] _ in
                var items: [UIMenuElement] = [
                    UIAction(title: "View full screen", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in
                        MainActor.assumeIsolated { self?.parent.open() }
                    }
                ]
                if let shareURL {
                    items.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                        MainActor.assumeIsolated { Coordinator.share(shareURL, from: interaction?.view) }
                    })
                }
                return UIMenu(children: items)
            })
        }
        /// A tap on the card: the peek closes and the artwork opens full screen.
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                    animator: any UIContextMenuInteractionCommitAnimating) {
            // As soon as the peek is gone (iOS won't present over it), then a quick zoom in.
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in
                MainActor.assumeIsolated { self?.parent.open() }
            }
        }
        static func share(_ url: URL, from view: UIView?) {
            guard var top = view?.window?.rootViewController else { return }
            while let next = top.presentedViewController { top = next }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = view
            top.present(sheet, animated: true)
        }
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
    /// Zooms and fades in from the middle on open, and back out on close (no slide from below).
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(appeared ? (scale > 1 ? 1 : max(0.35, 1 - Double(offset.height) / 500)) : 0).ignoresSafeArea()
            Artwork(path: path, title: title, contentMode: .fit, prefersOriginal: true)
                .scaleEffect(scale * (appeared ? 1 : 0.94))
                .opacity(appeared ? 1 : 0)
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
                        else if value.translation.height > 120 { close() }
                        else { withAnimation(reduceMotion ? nil : .snappy) { offset = .zero } }
                    })
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                    }
                }
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isImage)
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.black.opacity(0.55), in: Circle())
            }.padding(16).accessibilityLabel("Close").accessibilityIdentifier("full-screen-artwork-close")
                .opacity(appeared ? 1 : 0)
        }.statusBarHidden()
            .accessibilityIdentifier("full-screen-artwork")
            .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .snappy(duration: 0.16)) { appeared = true } }
    }
    private func reset() { scale = 1; settledScale = 1; offset = .zero; settledOffset = .zero }
    private func close() {
        withAnimation(.easeOut(duration: 0.12)) { appeared = false } completion: {
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { dismiss() }
        }
    }
}
