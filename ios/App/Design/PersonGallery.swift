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
                                Artwork(path: CatalogTools.image(photo.path, size: "w500"), title: name, initialsOnly: false, alignment: .top)
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
                        .overlay { Artwork(path: CatalogTools.image(photo.path, size: "w500"), title: route.name, initialsOnly: false, alignment: .top) }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.springPress).accessibilityLabel(photo.title.map { "Photo from " + $0 } ?? "Photo of " + route.name)
            }
        }.frame(maxWidth: .infinity)
    }
}

/// Full screen, one photo at a time (design page 3): ✕, "3 / 12" and ••• on top; a strip of every
/// photo and Save, Share and Download in the panel below. Swipe or tap a thumbnail to move.
struct PersonPhotoViewer: View {
    let name: String
    let photos: [PersonPhoto]
    @State private var index: Int
    @State private var saved = PersonPhotoLikes.load()
    @State private var message: String?
    @State private var downloading = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    init(name: String, photos: [PersonPhoto], start: Int) { self.name = name; self.photos = photos; _index = State(initialValue: start) }
    private var current: PersonPhoto? { photos.indices.contains(index) ? photos[index] : nil }
    /// TMDB's full-size picture of the current photo.
    private var original: URL? {
        guard let current, CatalogTools.image(current.path, size: "w780") != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/original" + current.path)
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                TabView(selection: $index) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                        Artwork(path: CatalogTools.image(photo.path, size: "w780"), title: name, initialsOnly: false, contentMode: .fit, prefersOriginal: true)
                            .tag(offset)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
                HStack {
                    Button { dismiss() } label: { circle("xmark") }.buttonStyle(.plain).accessibilityLabel("Close")
                    Spacer(minLength: 8)
                    Text("\(index + 1) / \(photos.count)").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 40).background(Color(webHex: "#2b2727").opacity(0.88), in: Capsule())
                        .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
                    Spacer(minLength: 8)
                    Menu {
                        if let title = current?.title { Text("From " + title) }
                        if let original {
                            Link(destination: original) { Label("Open full size", systemImage: "arrow.up.right.square") }
                            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = original; message = "Link copied." }
                        }
                    } label: { circle("ellipsis") }.accessibilityLabel("More photo options")
                }.padding(.horizontal, 16).padding(.top, 8)
            }
            panel
        }.background(Color.black.ignoresSafeArea()).preferredColorScheme(.dark).statusBarHidden()
            .onChange(of: index) { _, _ in message = nil }
    }
    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(Color(webHex: "#1c1a1e").opacity(0.85), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.67)).contentShape(Circle())
    }
    private var panel: some View {
        VStack(spacing: 16) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                            Button { withAnimation(.smooth(duration: 0.3)) { index = offset } } label: {
                                Artwork(path: CatalogTools.image(photo.path, size: "w185"), title: name, initialsOnly: false, alignment: .top)
                                    .frame(width: 58, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(offset == index ? theme.accent : .clear, lineWidth: 2.5))
                                    .opacity(offset == index ? 1 : 0.75)
                            }.buttonStyle(.plain).id(offset).accessibilityLabel("Photo \(offset + 1)")
                                .accessibilityAddTraits(offset == index ? .isSelected : [])
                        }
                    }.padding(.horizontal, 20)
                }.scrollIndicators(.hidden).frame(height: 80)
                    .onAppear { proxy.scrollTo(index, anchor: .center) }
                    .onChange(of: index) { _, value in withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(value, anchor: .center) } }
            }
            HStack(spacing: 0) {
                let liked = current.map { saved.contains($0.path) } ?? false
                Button {
                    guard let current else { return }
                    if liked { saved.remove(current.path) } else { saved.insert(current.path) }
                    PersonPhotoLikes.store(saved)
                } label: { action(liked ? "heart.fill" : "heart", liked ? "Saved" : "Save") }
                    .buttonStyle(.plain).sensoryFeedback(.selection, trigger: liked).accessibilityIdentifier("photo-save")
                Group {
                    if let original { ShareLink(item: original) { action("square.and.arrow.up", "Share") } }
                    else { action("square.and.arrow.up", "Share").opacity(0.4) }
                }.buttonStyle(.plain).accessibilityIdentifier("photo-share")
                Button { Task { await download() } } label: { action(downloading ? "hourglass" : "arrow.down.to.line", "Download") }
                    .buttonStyle(.plain).disabled(original == nil || downloading).accessibilityIdentifier("photo-download")
            }
            Text(message ?? " ").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).frame(height: 14)
        }.padding(.top, 18).padding(.bottom, 4)
            .background(Color(webHex: "#0b0b10"), in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
    }
    private func action(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(theme.accent)
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
        }.frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
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

/// The photos you hearted in the viewer (by TMDB path), kept on this iPhone.
enum PersonPhotoLikes {
    private static let key = "person.savedPhotos"
    static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func store(_ paths: Set<String>) { UserDefaults.standard.set(Array(paths).sorted(), forKey: key) }
}
