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
    @Environment(\.dismiss) private var dismiss
    init(name: String, photos: [PersonPhoto], start: Int) { self.name = name; self.photos = photos; _index = State(initialValue: start) }
    private var current: PersonPhoto? { photos.indices.contains(index) ? photos[index] : nil }
    /// TMDB's full-size picture of the current photo.
    private var original: URL? { current?.originalURL }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    ZoomablePhoto(path: photo.link(size: "w780"), name: name, active: offset == index, zoomed: $zoomed) {
                        withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }
                    }.tag(offset)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never)).scrollDisabled(zoomed).ignoresSafeArea()
            if controls { topBar.transition(.opacity) }
            if controls, let message {
                VStack {
                    Spacer()
                    Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36).background(Color(webHex: "#1c1a1e").opacity(0.9), in: Capsule()).padding(.bottom, 30)
                }.transition(.opacity).allowsHitTesting(false)
            }
        }.preferredColorScheme(.dark).statusBarHidden().persistentSystemOverlays(controls ? .automatic : .hidden)
            .onChange(of: index) { _, _ in message = nil; zoomed = false }
    }
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { circle("xmark") }.buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("photo-close")
            Spacer(minLength: 8)
            Text("\(index + 1) / \(photos.count)").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 40).background(Color(webHex: "#2b2727").opacity(0.88), in: Capsule())
                .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
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
    /// Saves the full-size picture to Photos (asking once for permission to add).
    private func download() async {
        guard let original else { return }
        downloading = true; defer { downloading = false }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { message = "Allow TwilDiary to add photos in Settings to download."; return }
            let (data, _) = try await URLSession.shared.data(from: original)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            message = "Saved to Photos."
        } catch { message = error.localizedDescription }
    }
}

/// One photo that zooms: pinch (up to 5×) or double-tap (2.5×, again to fit), drag while zoomed.
/// A single tap is passed up (show or hide the controls). Leaving the page zooms back out.
private struct ZoomablePhoto: View {
    let path: String?
    let name: String
    let active: Bool
    @Binding var zoomed: Bool
    let onTap: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Artwork(path: path, title: name, initialsOnly: false, contentMode: .fit, prefersOriginal: true)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale).offset(offset)
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .onChanged { value in scale = min(5, max(1, lastScale * value.magnification)); offset = clamped(offset, in: size) }
                    .onEnded { _ in settle(in: size) })
                .highPriorityGesture(scale > 1.01 ? DragGesture()
                    .onChanged { value in
                        offset = clamped(CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height), in: size)
                    }
                    .onEnded { _ in lastOffset = offset } : nil)
                .onTapGesture(count: 2) { location in
                    withAnimation(.snappy(duration: 0.28)) {
                        if scale > 1.01 { reset() } else {
                            scale = 2.5; lastScale = 2.5
                            // Zoom in on the tapped spot.
                            let point = CGSize(width: (size.width / 2 - location.x) * 1.5, height: (size.height / 2 - location.y) * 1.5)
                            offset = clamped(point, in: size); lastOffset = offset
                        }
                    }
                    zoomed = scale > 1.01
                }
                .onTapGesture { onTap() }
        }
        .onChange(of: active) { _, now in if !now { reset() } }
        .accessibilityElement().accessibilityLabel("Photo of " + name).accessibilityAddTraits(.isImage)
    }
    private func settle(in size: CGSize) {
        if scale < 1.05 { withAnimation(.snappy(duration: 0.25)) { reset() } } else { lastScale = scale; offset = clamped(offset, in: size); lastOffset = offset }
        zoomed = scale > 1.01
    }
    private func reset() { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero; if active { zoomed = false } }
    /// Keeps the zoomed picture covering the screen (no panning past its edges).
    private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, (scale - 1) * size.width / 2), maxY = max(0, (scale - 1) * size.height / 2)
        return CGSize(width: min(maxX, max(-maxX, value.width)), height: min(maxY, max(-maxY, value.height)))
    }
}

/// The photos you hearted in the viewer (by TMDB path), kept on this iPhone.
enum PersonPhotoLikes {
    private static let key = "person.savedPhotos"
    static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func store(_ paths: Set<String>) { UserDefaults.standard.set(Array(paths).sorted(), forKey: key) }
}
