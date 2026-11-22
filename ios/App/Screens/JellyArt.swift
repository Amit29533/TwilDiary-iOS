import SwiftUI

/// The shape a card wants its picture in.
enum JellyArtShape { case portrait, landscape }

/// A Jellyfin picture placed by its own shape against the card's, so nothing is cut off:
/// - the same shape (within about 1.4×): fills the card, as before;
/// - a DVD cover scan (back, spine and front side by side, about 1.3 to 1.6 wide) in a portrait card:
///   its right-hand side, the front cover;
/// - anything else far from the card's shape: the whole picture over a blurred copy of itself.
/// Given several pictures (a backdrop, Thumb art, the poster), it takes the first that suits the shape
/// asked for: a 147×200 "backdrop" is skipped for a wide card.
struct JellyArt<Fallback: View>: View {
    let urls: [URL]
    var shape: JellyArtShape? = nil
    @ViewBuilder let fallback: () -> Fallback
    /// The picture chosen, and from which addresses (given others, it chooses again).
    @State private var picked: (urls: [URL], image: UIImage)?

    var body: some View {
        if let image = chosen ?? kept {
            JellyArtPicture(image: image)
        } else {
            fallback().task(id: urls) {
                let asked = urls
                if let image = await choose() { picked = (asked, image) }
            }
        }
    }
    private var chosen: UIImage? {
        guard let picked, picked.urls == urls else { return nil }
        return picked.image
    }

    /// A picture already in memory that will do, without waiting (nil: one has to load first).
    private var kept: UIImage? {
        var first: UIImage?
        for url in urls {
            guard let image = JellyfinPosterCache.shared.resident(url) else { return nil }
            if Self.suits(image, shape) { return image }
            if first == nil { first = image }
        }
        return first
    }
    /// The first picture that suits the shape, loading them in turn; else the first there is.
    private func choose() async -> UIImage? {
        var first: UIImage?
        for url in urls {
            guard let image = await JellyfinPosterCache.shared.image(url) else { continue }
            if Self.suits(image, shape) { return image }
            if first == nil { first = image }
        }
        return first
    }
    static func suits(_ image: UIImage, _ shape: JellyArtShape?) -> Bool {
        guard let shape, image.size.height > 0 else { return true }
        let ratio = image.size.width / image.size.height
        return shape == .landscape ? ratio >= 1.2 : ratio <= 0.95
    }
}

/// One picture in its card: filled, its front cover, or whole over a blur (see JellyArt).
struct JellyArtPicture: View {
    let image: UIImage

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            switch Self.placement(picture: image.size, card: size) {
            case .fill:
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            case .front:
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height, alignment: .trailing).clipped()
            case .whole:
                ZStack {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                        .blur(radius: 18).opacity(0.75)
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: size.width, height: size.height)
                }
                .clipped()
            }
        }
    }

    enum Placement { case fill, front, whole }
    static func placement(picture: CGSize, card: CGSize) -> Placement {
        guard picture.width > 0, picture.height > 0, card.width > 0, card.height > 0 else { return .fill }
        let ratio = picture.width / picture.height, frame = card.width / card.height
        if max(ratio / frame, frame / ratio) <= 1.4 { return .fill }
        if frame < 1, (1.3...1.62).contains(ratio) { return .front }
        return .whole
    }
}

extension JellyfinClient.Item {
    /// Its poster's shape (width over height), when Jellyfin said: under 1 upright, over 1 wide.
    /// An episode's poster is its show's, so its own picture's shape doesn't count.
    var posterRatio: Double? {
        guard kind != "Episode" || SeriesPrimaryImageTag == nil else { return nil }
        return PrimaryImageAspectRatio
    }
    /// A landscape poster (a cover scan, a video frame): better shown on a wide card.
    var landscapePoster: Bool { (posterRatio ?? 0) >= 1.2 }
}

extension JellySpace {
    /// A wide card's pictures in order of preference (JellyArt takes the first that's landscape): an
    /// episode's still, the backdrop, its show's backdrop, Thumb art, then the poster.
    static func widePictures(_ item: JellyfinClient.Item, base: URL) -> [URL] {
        var urls: [URL?] = []
        // Its own poster when that's landscape (a cover scan shows whole, not a stray backdrop).
        if item.landscapePoster, let tag = item.ImageTags?["Primary"] {
            urls.append(JellyfinClient.imageURL(base: base, item: item.Id, type: "Primary", tag: tag, width: 900))
        }
        if item.kind == "Episode", let still = item.ImageTags?["Primary"] {
            urls.append(JellyfinClient.imageURL(base: base, item: item.Id, type: "Primary", tag: still))
        }
        if let tag = item.BackdropImageTags?.first { urls.append(JellyfinClient.imageURL(base: base, item: item.Id, type: "Backdrop", tag: tag)) }
        if let parent = item.ParentBackdropItemId, let tag = item.ParentBackdropImageTags?.first {
            urls.append(JellyfinClient.imageURL(base: base, item: parent, type: "Backdrop", tag: tag))
        }
        if let thumb = item.ImageTags?["Thumb"] { urls.append(JellyfinClient.imageURL(base: base, item: item.Id, type: "Thumb", tag: thumb)) }
        if item.kind != "Episode", let tag = item.ImageTags?["Primary"] {
            urls.append(JellyfinClient.imageURL(base: base, item: item.Id, type: "Primary", tag: tag, width: 900))
        }
        urls.append(poster(item, base: base))
        var seen = Set<URL>()
        return urls.compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}
