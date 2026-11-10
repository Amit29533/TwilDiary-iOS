import SwiftUI
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

/// Full screen, one photo at a time: swipe between them, tap ✕ to close.
struct PersonPhotoViewer: View {
    let name: String
    let photos: [PersonPhoto]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss
    init(name: String, photos: [PersonPhoto], start: Int) { self.name = name; self.photos = photos; _index = State(initialValue: start) }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    Artwork(path: CatalogTools.image(photo.path, size: "w780"), title: name, initialsOnly: false, contentMode: .fit, prefersOriginal: true)
                        .tag(offset).ignoresSafeArea()
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                Button { dismiss() } label: { RoundTool(icon: "x", tint: .white) }.buttonStyle(.plain).accessibilityLabel("Close")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(index + 1) of \(photos.count)").font(.system(size: 15, weight: .semibold))
                    if photos.indices.contains(index), let title = photos[index].title { Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
                }.padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.5), in: Capsule())
            }.padding(.horizontal, 16).padding(.top, 8)
        }.preferredColorScheme(.dark).statusBarHidden()
    }
}
