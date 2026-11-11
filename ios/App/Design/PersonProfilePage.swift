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
                    if fit.besidePhoto < heroFacts.count {
                        ProfileFacts(items: Array(heroFacts.dropFirst(fit.besidePhoto))).padding(.horizontal, 14).padding(.bottom, 6)
                    }
                    if showsPhotoShelf { PersonPhotoShelf(name: name, photos: photos).padding(.horizontal, 14).padding(.bottom, 6) }
                    content.padding(.horizontal, 14)
                }.padding(.bottom, 28)
            }.coordinateSpace(name: "profile-scroll")
                .ignoresSafeArea(.container, edges: .top)
                // iOS 26's scroll-edge material is independent of the toolbar
                // background. It otherwise blurs a hard strip over the portrait.
                .scrollEdgeEffectHidden(true, for: .top)
                .background(.black).tint(Color(webHex: "#e6e2ec"))
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
            .modifier(ProfileNativeLinks(kind: kind, ref: ref, sameVoice: sameVoice, samePerson: samePerson))
    }

    private func hero(height: CGFloat, topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 150)
            Text(name).font(.largeTitle.bold()).tracking(-0.9)
                .foregroundStyle(LinearGradient(colors: [.white, theme.accent], startPoint: .leading, endPoint: .trailing))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + "-name")
                .onGeometryChange(for: CGFloat.self) { proxy in
                    CompactHeaderTransition.progress(nameBottom: proxy.frame(in: .named("profile-scroll")).maxY - topInset)
                } action: { header.update($0) }
            if let native = ProfileText.line(nativeName), native != ProfileText.line(name) {
                Text(native).font(.subheadline).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }
            if let role = ProfileText.line(role) {
                Text(role).font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 14).padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
            // Press and hold the photo to see it whole, full screen.
            .contentShape(Rectangle()).fullScreenArtwork(image, title: name)
            .background {
                GeometryReader { proxy in
                    portrait.frame(width: proxy.size.width, height: proxy.size.height)
                        .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.14), location: 0),
                            .init(color: .black.opacity(0.15), location: 0.45), .init(color: .black.opacity(0.8), location: 0.82),
                            .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                        .overlay(LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing))
                        .clipped().allowsHitTesting(false).accessibilityHidden(true)
                }
            }
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
                                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
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
                ForEach(Array(heroFacts.prefix(fit.besidePhoto).enumerated()), id: \.element.id) { index, fact in
                    if index > 0 { Rectangle().fill(.white.opacity(0.1)).frame(height: HomeStyle.hairline) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Image(systemName: fact.icon).font(.system(size: 12)); Text(fact.label) }.font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                        Text(fact.value).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).lineLimit(2).truncationMode(.tail).minimumScaleFactor(0.85)
                    }.padding(.vertical, 11).accessibilityElement(children: .combine).accessibilityIdentifier(fact.id)
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
                                .init(color: Color(webHex: "#0a0a0e").opacity(0), location: 0),
                                .init(color: Color(webHex: "#0a0a0e").opacity(0.08), location: 0.28),
                                .init(color: Color(webHex: "#0a0a0e").opacity(0.55), location: 0.45),
                                .init(color: Color(webHex: "#0a0a0e").opacity(0.78), location: 0.65),
                                .init(color: Color(webHex: "#0a0a0e").opacity(0.88), location: 1)
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

    @ViewBuilder private var portrait: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-profile-header-pattern") {
            ProfileHeaderTestPattern()
        } else { framedPortrait }
        #else
        framedPortrait
        #endif
    }
    /// The portrait fills the header's width. The header is shorter than a 2:3 photo, so the
    /// bottom is trimmed (under the fade and the name); the top, where the face is, stays.
    /// TMDB's original rendition (and a TMDB photo for AniList voice actors linked through
    /// Wikidata) keeps it sharp at full width.
    private var framedPortrait: some View {
        Artwork(path: image, title: name, alignment: .top, prefersOriginal: true)
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
            Image(systemName: saved ? "heart.fill" : "heart").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > previewHeight + 1 }
    var body: some View {
        if !text.characters.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                prose.lineLimit(expanded ? nil : collapsedLines)
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
                    Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { expanded.toggle() } } label: {
                        HStack(spacing: 5) { Text(expanded ? lessLabel : moreLabel); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption) }
                            .font(.subheadline).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(HomeStyle.chipText).fontWeight(.semibold)
                        .accessibilityLabel(expanded ? "Collapse " + (identifier == "profile-aliases" ? "names" : "biography") : "Expand " + (identifier == "profile-aliases" ? "names" : "biography"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: String(text.characters)) { _, _ in expanded = false }
        }
    }
    private var prose: some View {
        Text(text).font(style).lineSpacing(5).foregroundStyle(Color(webHex: "#cfccda"))
            .tint(Color(webHex: "#d1cdd8")).frame(maxWidth: .infinity, alignment: .leading)
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
                            .background(Color(webHex: "#1b1b20"), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
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
    let besidePhoto: Int
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
        var count = 0
        for fact in facts.prefix(largeText ? 0 : 4) {
            let valueLines = CGFloat(min(2, lines(fact.value, size: 19)))
            let height = 18 + 4 + valueLines * 24 + 22
            // A little past the photo's bottom is fine; a fact that would sit far below it isn't.
            guard used + height <= photoHeight + 18 else { break }
            used += height; count += 1
        }
        besidePhoto = count
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
