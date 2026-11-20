import SwiftUI
import UIKit

/// Which photo of a set is open.
struct JellyPhotoSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

/// A folder's photos as small squares, three across; a tap opens the viewer on that photo.
struct JellyPhotoGrid: View {
    let photos: [JellyfinClient.Item]
    let client: JellyfinClient
    @State private var open: JellyPhotoSelection?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(photos.indices, id: \.self) { index in
                Button { open = JellyPhotoSelection(index: index) } label: {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay {
                            ZStack {
                                Rectangle().fill(HomeStyle.card)
                                JellyImage(url: JellyPhotos.url(photos[index], base: client.base, width: 400))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(photos[index].Name ?? "Photo").accessibilityIdentifier("jellyspace-photo-" + photos[index].Id)
            }
        }
        .fullScreenCover(item: $open) { JellyPhotoViewer(photos: photos, client: client, start: $0.index) }
    }
}

/// Photos full screen: swipe between them, pinch or double-tap to zoom, a tap shows or hides the bar.
struct JellyPhotoViewer: View {
    let photos: [JellyfinClient.Item]
    let client: JellyfinClient
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chrome = true

    init(photos: [JellyfinClient.Item], client: JellyfinClient, start: Int) {
        self.photos = photos
        self.client = client
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(photos.indices, id: \.self) { position in
                    JellyPhotoPage(url: JellyPhotos.url(photos[position], base: client.base, width: 2400)) {
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    }
                    .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if chrome {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle()).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("jellyspace-photo-close")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(photos.indices.contains(index) ? (photos[index].Name ?? "Photo") : "Photo")
                            .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("\(index + 1) of \(photos.count)").font(.system(size: 12)).opacity(0.7)
                    }.foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 4)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
    }
}

/// One photo, loaded at screen size and zoomable.
private struct JellyPhotoPage: View {
    let url: URL?
    let tapped: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            if let image {
                JellyZoomImage(image: image, tapped: tapped)
            } else if failed {
                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).onTapGesture(perform: tapped)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).onTapGesture(perform: tapped)
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            // Full-size photos aren't kept in the poster memory (they're large): loaded per page.
            if let fetched = try? await URLSession.shared.data(from: url),
               (fetched.1 as? HTTPURLResponse)?.statusCode == 200, let loaded = UIImage(data: fetched.0) {
                image = await loaded.byPreparingForDisplay() ?? loaded
            } else if !Task.isCancelled {
                failed = true
            }
        }
    }
}

/// Pinch and double-tap zoom (UIKit's scroll view does it best); a single tap goes to `tapped`.
private struct JellyZoomImage: UIViewRepresentable {
    let image: UIImage
    let tapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.tapped = tapped
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scroll.zoomScale = 1
        }
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var tapped: () -> Void = {}
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func singleTapped() { tapped() }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

@MainActor enum JellyPhotos {
    /// A photo at a given width (Jellyfin serves the photo itself as its Primary image).
    static func url(_ photo: JellyfinClient.Item, base: URL, width: Int) -> URL? {
        JellyfinClient.imageURL(base: base, item: photo.Id, type: "Primary", tag: photo.ImageTags?["Primary"], width: width)
    }
}
