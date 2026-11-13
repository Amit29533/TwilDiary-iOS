import SwiftUI
import Photos
import TwilDiaryCore

/// A person's Photos page: all their pictures, filtered by kind.
struct PersonPhotosRoute: Hashable {
    let name: String
    let photos: [PersonPhoto]
}

/// "Photos · See all": tall cards in a sideways row; a tap opens the picture full screen.
struct PersonPhotoShelf: View {
    let name: String
    let photos: [PersonPhoto]
    @State private var viewing: Int?
    var body: some View {
        if photos.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Photos").font(.system(size: 24, weight: .bold)).tracking(-0.6)
                    Spacer(minLength: 8)
                    SeeAllLink(value: PersonPhotosRoute(name: name, photos: photos), identifier: "profile-photos-all")
                }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(photos.prefix(12).enumerated()), id: \.element.id) { index, photo in
                            Button { viewing = index } label: {
                                Artwork(path: photo.link(size: "w500"), title: name, initialsOnly: false, alignment: .top)
                                    .frame(width: 156, height: 200).clipShape(RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.springPress).accessibilityLabel(photo.title.map { "Photo from " + $0 } ?? "Photo of " + name)
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
            }.fullScreenCover(item: Binding(get: { viewing.map(PhotoIndex.init) }, set: { viewing = $0?.value })) { start in
                PersonPhotoViewer(name: name, photos: photos, start: start.value)
            }
        }
    }
}
struct PhotoIndex: Identifiable { let value: Int; var id: Int { value } }

/// Every photo, in two staggered columns, with All / Posters / Stills / Off set.
struct PersonPhotosPage: View {
    let route: PersonPhotosRoute
    private enum Filter: String, CaseIterable { case all = "All", posters = "Posters", stills = "Stills", portraits = "Off set" }
    @State private var filter = Filter.all
    @State private var viewing: Int?
    private var shown: [PersonPhoto] {
        switch filter {
        case .all: route.photos
        case .posters: route.photos.filter { $0.kind == "poster" }
        case .stills: route.photos.filter { $0.kind == "still" }
        case .portraits: route.photos.filter { $0.kind == "portrait" }
        }
    }
    var body: some View {
        let shown = shown
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases, id: \.self) { item in
                            if item == .all || !photos(for: item).isEmpty { ShowFilterChip(label: item.rawValue, on: filter == item) { filter = item } }
                        }
                    }
                }.scrollIndicators(.hidden)
                HStack(alignment: .top, spacing: 12) {
                    column(shown, even: true)
                    column(shown, even: false)
                }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ShowPageTitle(title: "Photos", subtitle: route.name) }
            .fullScreenCover(item: Binding(get: { viewing.map(PhotoIndex.init) }, set: { viewing = $0?.value })) { start in
                PersonPhotoViewer(name: route.name, photos: shown, start: start.value)
            }
    }
    private func photos(for filter: Filter) -> [PersonPhoto] {
        switch filter {
        case .all: route.photos
        case .posters: route.photos.filter { $0.kind == "poster" }
        case .stills: route.photos.filter { $0.kind == "still" }
        case .portraits: route.photos.filter { $0.kind == "portrait" }
        }
    }
    private func column(_ photos: [PersonPhoto], even: Bool) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(Array(photos.enumerated()).filter { ($0.offset % 2 == 0) == even }, id: \.element.id) { index, photo in
                Button { viewing = index } label: {
                    Color.clear.aspectRatio(max(0.55, min(1.8, photo.aspectRatio)), contentMode: .fit)
                        .overlay { Artwork(path: photo.link(size: "w500"), title: route.name, initialsOnly: false, alignment: .top) }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.springPress).accessibilityLabel(photo.title.map { "Photo from " + $0 } ?? "Photo of " + route.name)
            }
        }.frame(maxWidth: .infinity)
    }
}

/// Full screen, one photo at a time: the picture fills the screen. A tap hides or shows the
/// controls (✕, "3 / 12" and ••• with Save, Share and Download); swiping to the next photo leaves
/// them as they are. Pinch or double-tap to zoom; drag to look around while zoomed.
struct PersonPhotoViewer: View {
    let name: String
    let photos: [PersonPhoto]
    @State private var index: Int
    @State private var saved = PersonPhotoLikes.load()
    @State private var message: String?
    @State private var downloading = false
    @State private var controls = true
    @State private var zoomed = false
    /// How far a photo is pulled down to close it (0…1): the page fades and the controls step aside.
    @State private var pulled: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    init(name: String, photos: [PersonPhoto], start: Int) { self.name = name; self.photos = photos; _index = State(initialValue: start) }
    private var current: PersonPhoto? { photos.indices.contains(index) ? photos[index] : nil }
    /// TMDB's full-size picture of the current photo.
    private var original: URL? { current?.originalURL }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(Double(1 - pulled * 0.7)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    ZoomablePhoto(path: photo.link(size: "w780"), name: name, active: offset == index, zoomed: $zoomed,
                                  onTap: { withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() } },
                                  onPull: { pulled = $0 }, onClose: { dismiss() })
                        // Each page fills the whole screen (not just the safe area), so a zoomed
                        // photo reaches the edges instead of being clipped to an inner box.
                        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
                        .tag(offset)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never)).scrollDisabled(zoomed).ignoresSafeArea()
            if controls && pulled == 0 { topBar.transition(.opacity) }
            if controls, let message {
                VStack {
                    Spacer()
                    Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36).background(Color(webHex: "#1c1a1e").opacity(0.9), in: Capsule()).padding(.bottom, 30)
                }.transition(.opacity).allowsHitTesting(false)
            }
        }.presentationBackground(.clear).preferredColorScheme(.dark).statusBarHidden().persistentSystemOverlays(controls ? .automatic : .hidden)
            .onChange(of: index) { _, _ in message = nil; zoomed = false }
    }
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { circle("xmark") }.buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("photo-close")
            Spacer(minLength: 8)
            // One picture (a poster, a cover, character art): no "1 / 1".
            if photos.count > 1 {
                Text("\(index + 1) / \(photos.count)").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 40).background(Color(webHex: "#2b2727").opacity(0.88), in: Capsule())
                    .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
            }
            Spacer(minLength: 8)
            menu
        }.padding(.horizontal, 16).padding(.top, 8)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140).ignoresSafeArea().allowsHitTesting(false)
            }
    }
    /// Save, Share, Download and the rest, all under •••.
    private var menu: some View {
        let liked = current.map { saved.contains($0.path) } ?? false
        return Menu {
            if let title = current?.title { Text("From " + title) }
            Button(liked ? "Saved" : "Save", systemImage: liked ? "heart.fill" : "heart") {
                guard let current else { return }
                if liked { saved.remove(current.path); message = "Removed from saved." } else { saved.insert(current.path); message = "Saved." }
                PersonPhotoLikes.store(saved)
            }.accessibilityIdentifier("photo-save")
            if let original {
                ShareLink(item: original) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(downloading ? "Downloading…" : "Download", systemImage: "arrow.down.to.line") { Task { await download() } }
                    .disabled(downloading).accessibilityIdentifier("photo-download")
                Link(destination: original) { Label("Open full size", systemImage: "arrow.up.right.square") }
                Button("Copy link", systemImage: "link") { UIPasteboard.general.url = original; message = "Link copied." }
            }
        } label: { circle("ellipsis") }.accessibilityLabel("More photo options").accessibilityIdentifier("photo-menu")
    }
    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(Color(webHex: "#1c1a1e").opacity(0.85), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.67)).contentShape(Circle())
    }
    /// Photos runs the change on its own queue: written in this (main-actor) view, the block was
    /// main-actor isolated and Swift 6 stopped the app when Photos ran it there (the crash on
    /// Download). Here it isn't tied to any actor.
    nonisolated private static func addToPhotos(_ data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
    /// Saves the full-size picture to Photos (asking once for permission to add).
    private func download() async {
        guard let original else { return }
        downloading = true; defer { downloading = false }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { message = "Allow TwilDiary to add photos in Settings to download."; return }
            let (data, _) = try await URLSession.shared.data(from: original)
            try await Self.addToPhotos(data)
            message = "Saved to Photos."
        } catch { message = error.localizedDescription }
    }
}

/// One photo in the system's zooming scroll view (as Photos does it, so it stays smooth): pinch up
/// to 5×, double-tap to 2.5× on that spot and again to fit, pan while zoomed. A single tap is passed
/// up (show or hide the controls). Not zoomed, dragging down moves the photo with the finger and
/// closes the viewer when let go far enough or flicked. Leaving the page zooms back out.
private struct ZoomablePhoto: UIViewRepresentable {
    let path: String?
    let name: String
    let active: Bool
    @Binding var zoomed: Bool
    let onTap: () -> Void
    /// How far the photo is pulled down (0…1), while closing by a drag.
    let onPull: (CGFloat) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.showsVerticalScrollIndicator = false; view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.decelerationRate = .fast
        view.isAccessibilityElement = true; view.accessibilityLabel = "Photo of " + name; view.accessibilityTraits = .image
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        let pull = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pull(_:)))
        pull.delegate = context.coordinator
        [double, single, pull].forEach(view.addGestureRecognizer)
        context.coordinator.load(path, into: view)
        return view
    }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        context.coordinator.parent = self
        if !active, view.zoomScale != 1 { view.setZoomScale(1, animated: false) }
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomablePhoto
        init(_ parent: ZoomablePhoto) { self.parent = parent }

        func load(_ path: String?, into view: PhotoScrollView) {
            guard let request = PublicArtworkRequest(path: path, pixels: 1536, prefersOriginal: true) else { return }
            if let bitmap = PublicArtworkCache.shared.cached(request) { view.show(UIImage(cgImage: bitmap.image)); return }
            Task { [weak view] in
                guard let bitmap = await PublicArtworkCache.shared.image(request) else { return }
                view?.show(UIImage(cgImage: bitmap.image))
            }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? PhotoScrollView)?.center() }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            parent.zoomed = scale > 1.01
        }
        @objc func singleTap() { parent.onTap() }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PhotoScrollView else { return }
            if view.zoomScale > 1.01 { view.setZoomScale(1, animated: true); parent.zoomed = false; return }
            let point = gesture.location(in: view.imageView)
            let size = CGSize(width: view.bounds.width / 2.5, height: view.bounds.height / 2.5)
            view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            parent.zoomed = true
        }
        /// Drag down to close: only when not zoomed, and only a mostly downward drag (sideways swipes page).
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view as? UIScrollView else { return true }
            guard view.zoomScale <= 1.01 else { return false }
            let velocity = pan.velocity(in: view)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.4
        }
        @objc func pull(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? PhotoScrollView else { return }
            let drag = gesture.translation(in: view.superview)
            let progress = min(1, max(0, drag.y / 320))
            switch gesture.state {
            case .changed:
                view.transform = CGAffineTransform(translationX: drag.x * 0.4, y: max(0, drag.y)).scaledBy(x: 1 - progress * 0.12, y: 1 - progress * 0.12)
                parent.onPull(progress)
            case .ended, .cancelled:
                if gesture.state == .ended, drag.y > 110 || gesture.velocity(in: view).y > 900 {
                    parent.onClose()
                } else {
                    UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { view.transform = .identity }
                    parent.onPull(0)
                }
            default: break
            }
        }
    }
}

/// The scroll view behind one photo: the picture sized to fit, kept in the middle as it zooms.
final class PhotoScrollView: UIScrollView {
    let imageView = UIImageView()
    private var fittedTo: CGSize = .zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func show(_ image: UIImage) {
        imageView.image = image
        fittedTo = .zero
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, image.size.width > 0, bounds.width > 0 else { return }
        if zoomScale == 1, fittedTo != bounds.size {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            fittedTo = bounds.size
        }
        center()
    }
    /// Keeps the picture centred while it's smaller than the screen.
    func center() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2), vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

/// The photos you hearted in the viewer (by TMDB path), kept on this iPhone.
enum PersonPhotoLikes {
    private static let key = "person.savedPhotos"
    static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func store(_ paths: Set<String>) { UserDefaults.standard.set(Array(paths).sorted(), forKey: key) }
}
