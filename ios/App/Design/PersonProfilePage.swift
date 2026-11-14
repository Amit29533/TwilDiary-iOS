import SwiftUI
import TwilDiaryCore

/// One profile shell for TMDB cast, AniList characters and voice actors. Only
/// the small toolbar observes scroll progress; shelves never re-render per frame.
struct PersonProfilePage<Content: View>: View {
    let name: String
    var nativeName: String? = nil
    var role: String? = nil
    let image: String?
    let kind: Favourite.Kind
    let ref: Int
    var favouriteSubtitle: String? = nil
    let identifier: String
    /// The same person's other identity on this merged page: links to it don't push another page.
    var sameVoice: Int? = nil
    var samePerson: Int? = nil
    /// Born, age, birthplace, favourites, blood type…: as many as fit sit beside the photo (with
    /// the name); the rest follow in a card under it. A page with none keeps the full-width portrait.
    var heroFacts: [ProfileFact] = []
    /// The gallery under the header.
    var photos: [PersonPhoto] = []
    /// False when the page places the Photos shelf itself (a person: after About, as designed).
    var showsPhotoShelf = false
    /// Cover art of their best-known title behind the header (owner's request), with the title
    /// page's soft wash under it; nil keeps the plain accent glow.
    var backdrop: String? = nil
    @ViewBuilder let content: Content
    @State private var header = CompactHeaderState()
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // The photo card with the name beside it, for everyone: a person TMDB knows no
                    // facts about (no birthday, birthplace…) used to get the older full-photo header.
                    let fit = ProfileHeroFit(width: geometry.size.width, name: name, nativeName: nativeName, role: role, facts: heroFacts,
                                             largeText: dynamicType.isAccessibilitySize)
                    cardHero(width: geometry.size.width, topInset: geometry.safeAreaInsets.top, fit: fit)
                    let below = heroFacts.indices.filter { !fit.beside.contains($0) }.map { heroFacts[$0] }
                    if !below.isEmpty {
                        ProfileFacts(items: below).padding(.horizontal, 14).padding(.bottom, 6)
                    }
                    if showsPhotoShelf { PersonPhotoShelf(name: name, photos: photos).padding(.horizontal, 14).padding(.bottom, 6) }
                    content.padding(.horizontal, 14)
                }.padding(.bottom, 28)
            }.coordinateSpace(name: "profile-scroll")
                .ignoresSafeArea(.container, edges: .top)
                // iOS 26's scroll-edge material is independent of the toolbar
                // background. It otherwise blurs a hard strip over the portrait.
                .scrollEdgeEffectHidden(true, for: .top)
                .background(ThemeStore.current.canvas).tint(Color(themed: "#e6e2ec"))
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) { FeatheredHeaderBackdrop(state: header, height: geometry.safeAreaInsets.top).offset(y: -geometry.safeAreaInsets.top) }
                .toolbar {
                    ToolbarItem(placement: .principal) { ProfileCompactName(name: name, image: image, state: header) }
                    ToolbarItem(placement: .topBarTrailing) {
                        ProfileFavourite(name: name, image: image, kind: kind, ref: ref,
                                         subtitle: favouriteSubtitle, identifier: identifier + "-favourite")
                    }
                }
        }.toolbarBackground(.hidden, for: .navigationBar)
            // Native: an Apple Music artist page, dark in light mode too, its header and toolbar included.
            .nativeArtworkPage()
            .modifier(ProfileNativeLinks(kind: kind, ref: ref, sameVoice: sameVoice, samePerson: samePerson))
    }

    /// The photo as a card, the name (second part in the accent) with the role, and the top facts
    /// beside it, divided like a list. The photo's Photos button opens the gallery.
    private func cardHero(width: CGFloat, topInset: CGFloat, fit: ProfileHeroFit) -> some View {
        let photoWidth = fit.photoWidth
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        return HStack(alignment: .top, spacing: 16) {
            Artwork(path: image, title: name, alignment: .top, prefersOriginal: true)
                .frame(width: photoWidth, height: photoWidth * 1.45).clipShape(RoundedRectangle(cornerRadius: 24))
                .contentShape(RoundedRectangle(cornerRadius: 24)).fullScreenArtwork(image, title: name)
                .overlay(alignment: .bottomTrailing) {
                    if photos.count >= 2 {
                        NavigationLink(value: PersonPhotosRoute(name: name, photos: photos)) {
                            HStack(spacing: 6) { Image(systemName: "square.on.square").font(.system(size: 13, weight: .semibold)); Text("Photos").font(.system(size: 14, weight: .semibold)) }
                                .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 36).background(.black.opacity(0.6), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                        }.buttonStyle(.springPress).padding(10).accessibilityIdentifier(identifier + "-photos")
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(parts.first ?? name).foregroundStyle(.white)
                    if parts.count > 1 { Text(parts[1]).foregroundStyle(theme.accent) }
                }.font(.system(size: fit.nameSize, weight: .bold)).tracking(-0.9).lineLimit(3).truncationMode(.tail).minimumScaleFactor(0.8)
                    .shadow(color: .black.opacity(0.55), radius: 10, y: 2)
                    .accessibilityElement(children: .combine).accessibilityIdentifier(identifier + "-name")
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        CompactHeaderTransition.progress(nameBottom: proxy.frame(in: .named("profile-scroll")).maxY - topInset)
                    } action: { header.update($0) }
                if let native = ProfileText.line(nativeName), native != ProfileText.line(name) {
                    Text(native).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8)).lineLimit(2).truncationMode(.tail).padding(.top, 4)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                }
                if let role = ProfileText.line(role) {
                    Text(role).font(.system(size: 17)).foregroundStyle(.white.opacity(0.62)).lineLimit(1).padding(.top, 4)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                }
                ForEach(Array(fit.beside.map { heroFacts[$0] }.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: HomeStyle.hairline) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Image(systemName: fact.icon).font(.system(size: 12)); Text(fact.label) }.font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                        Text(fact.value).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(2).truncationMode(.tail).minimumScaleFactor(0.85)
                    }.padding(.vertical, 9).accessibilityElement(children: .combine).accessibilityIdentifier(fact.id)
                }.padding(.top, heroFacts.isEmpty ? 0 : 8)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 14).padding(.top, topInset + 64).padding(.bottom, 8)
            .background(alignment: .top) {
                if ProfileHeaderDebug.showsPattern {
                    // UI tests: stripes under the toolbar prove the header stays sharp there.
                    #if DEBUG
                    ProfileHeaderTestPattern().frame(height: topInset + 320).allowsHitTesting(false).accessibilityHidden(true)
                    #endif
                } else if let backdrop {
                    // The cover stays clear around the buttons; below that it darkens behind the name so
                    // a white first name never sits on bright artwork (owner's fix).
                    TitleArtworkBackdrop(path: backdrop, name: name)
                        .overlay(alignment: .top) {
                            LinearGradient(stops: [
                                .init(color: Color(themed: "#0a0a0e").opacity(0), location: 0),
                                .init(color: Color(themed: "#0a0a0e").opacity(0.08), location: 0.28),
                                .init(color: Color(themed: "#0a0a0e").opacity(0.55), location: 0.45),
                                .init(color: Color(themed: "#0a0a0e").opacity(0.78), location: 0.65),
                                .init(color: Color(themed: "#0a0a0e").opacity(0.88), location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                            .frame(height: topInset + 64 + photoWidth * 1.45).allowsHitTesting(false).accessibilityHidden(true)
                        }
                        // Press and hold the cover for a peek and View full screen, as on posters.
                        .overlay(alignment: .top) {
                            Color.clear.frame(width: width, height: TitleCover.artworkHeight(width: width)).contentShape(Rectangle())
                                .fullScreenArtwork(backdrop, title: name, aspect: 16.0 / 9.0)
                                .accessibilityElement().accessibilityLabel("Cover art").accessibilityHint("Press and hold to see it whole")
                                .accessibilityAddTraits(.isImage)
                        }
                } else {
                    RadialGradient(colors: [theme.accent.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: width * 0.9)
                        .frame(height: topInset + 320).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }

}

/// The name with a small round photo, as title pages show their poster, once the big name scrolls away.
private struct ProfileCompactName: View {
    let name: String
    let image: String?
    let state: CompactHeaderState
    var body: some View {
        HStack(spacing: 8) {
            Artwork(path: image, title: name, alignment: .top).frame(width: 28, height: 28).clipShape(Circle())
            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }.frame(height: 28)
            .foregroundStyle(.white).opacity(Double(state.progress))
            .accessibilityElement(children: .ignore).accessibilityLabel(name)
            .accessibilityIdentifier("profile-compact-name").accessibilityHidden(state.progress < 0.5)
    }
}

private struct ProfileFavourite: View {
    let name: String
    let image: String?
    let kind: Favourite.Kind
    let ref: Int
    let subtitle: String?
    let identifier: String
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var feedback = 0
    private var saved: Bool { FavouritesStore.shared.contains(kind, ref) }
    var body: some View {
        Button {
            FavouritesStore.shared.toggle(kind, ref: ref, name: name, image: image, subtitle: subtitle, store: store)
            feedback += 1
        } label: {
            // The bar's own Liquid Glass (same as the back button beside it).
            Image(systemName: saved ? "heart.fill" : "heart").contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce, value: saved).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
        }.buttonStyle(.plain).accessibilityLabel(saved ? "Remove from favourites" : "Add to favourites")
            .accessibilityValue(saved ? "Saved" : "Not saved").accessibilityIdentifier(identifier)
            .sensoryFeedback(.selection, trigger: feedback)
    }
}

struct ProfileBiography: View {
    let text: AttributedString
    @Binding var expanded: Bool
    var identifier = "profile-biography"
    var collapsedLines = 4
    var style: Font = .body
    var moreLabel = "More"
    var lessLabel = "Less"
    @State private var fullHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > previewHeight + 1 }
    var body: some View {
        if !text.characters.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // The page never grows: "More" opens the whole text in a sheet, so nothing below jumps.
                prose.lineLimit(collapsedLines)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(identifier)
                    .background(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            prose.lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                            prose.lineLimit(collapsedLines).fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                        }.hidden().allowsHitTesting(false).accessibilityHidden(true)
                    }
                if overflows {
                    Button { expanded = true } label: {
                        HStack(spacing: 5) { Text(moreLabel); Image(systemName: "chevron.right").font(.caption) }
                            .font(.subheadline).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(ThemeStore.current.native ? Color(uiColor: .label) : HomeStyle.chipText).fontWeight(.semibold)
                        .accessibilityLabel("Read the whole " + (identifier == "profile-aliases" ? "list of names" : "biography"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .modifier(BiographyCard())
                .onChange(of: String(text.characters)) { _, _ in expanded = false }
                .sheet(isPresented: $expanded) {
                    NavigationStack {
                        ScrollView { prose.lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(20) }
                            .background(Color(themed: "#111116"))
                            .navigationTitle(identifier == "profile-aliases" ? "Other names" : "About").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } } }
                    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
        }
    }
    private var prose: some View {
        Text(text).font(style).lineSpacing(5).foregroundStyle(ThemeStore.current.native ? Color(uiColor: .label).opacity(0.86) : Color(themed: "#cfccda"))
            .tint(Color(themed: "#d1cdd8")).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A website button's face: the original dark tile, or a Liquid Glass circle in Native.
private struct WebsiteButtonSurface: ViewModifier {
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(Color(themed: "#1b1b20"), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

/// Native: the biography in a card, as the About card of an Apple Music artist page.
private struct BiographyCard: ViewModifier {
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            content.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6).nativeCard(radius: 20)
        } else {
            content
        }
    }
}

struct ProfileWebsiteButtons: View {
    let links: [ProfileWebsiteLink]
    var body: some View {
        if !links.isEmpty {
            InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Group {
                            if let asset = link.asset { Image(asset).renderingMode(.template).resizable().scaledToFit() }
                            else { Image(systemName: link.symbol).resizable().scaledToFit() }
                        }.frame(width: 20, height: 20).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .modifier(WebsiteButtonSurface())
                    }.buttonStyle(.plain).accessibilityLabel(link.label)
                        .accessibilityHint(ProfileDeepLink.parse(link.url) == nil ? "Opens website" : "Opens inside TwilDiary").accessibilityIdentifier("profile-site-" + link.id)
                }
            }
        }
    }
}


/// How a profile header lays out at this width: the photo's size, the name's size, and how many
/// facts fit beside the photo without running past it. Long names step down a size, and long
/// values (a birthplace, "Favourites 12,345") take two lines; facts that don't fit go below.
struct ProfileHeroFit {
    let photoWidth: CGFloat
    let nameSize: CGFloat
    /// The facts (by position) that sit beside the photo: in order, each that still fits, at most
    /// four; one too tall (a two-line value) is skipped for a shorter one after it, not the end.
    let beside: [Int]
    /// With accessibility text sizes every fact goes to the full-width card below, not the narrow column.
    init(width: CGFloat, name: String, nativeName: String?, role: String?, facts: [ProfileFact], largeText: Bool = false) {
        photoWidth = min(220, (width - 28) * 0.47)
        let column = max(120, width - 28 - photoWidth - 16)
        let photoHeight = photoWidth * 1.45
        // The name: the first word on its own line, the rest in the accent (as drawn).
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        func lines(_ text: String, size: CGFloat) -> Int {
            let perLine = max(4, Int(column / (size * 0.56)))
            return max(1, Int(ceil(Double(text.count) / Double(perLine))))
        }
        func nameLines(_ size: CGFloat) -> Int { parts.reduce(0) { $0 + lines($1, size: size) } }
        var size: CGFloat = 32
        for candidate in [32.0, 28, 24] as [CGFloat] { size = candidate; if nameLines(candidate) <= 3 { break } }
        nameSize = size
        var used = CGFloat(min(3, nameLines(size))) * size * 1.18
        if let native = ProfileText.line(nativeName), native != ProfileText.line(name) { used += CGFloat(min(2, lines(native, size: 14))) * 18 + 4 }
        if ProfileText.line(role) != nil { used += 26 }
        used += 8
        var chosen: [Int] = []
        for (index, fact) in facts.enumerated() where !largeText && chosen.count < 4 {
            let valueLines = CGFloat(min(2, lines(fact.value, size: 19)))
            let height = 17 + 4 + valueLines * 23 + 18
            // The column fills the space beside the photo, and may run a little past its bottom;
            // a fact that would sit far below it goes to the card underneath instead.
            guard used + height <= photoHeight + 40 else { continue }
            used += height; chosen.append(index)
        }
        beside = chosen
    }
}

/// UI tests can swap the header artwork for stripes (`--ui-profile-header-pattern`); never in Release.
enum ProfileHeaderDebug {
    static var showsPattern: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-profile-header-pattern")
        #else
        false
        #endif
    }
}
