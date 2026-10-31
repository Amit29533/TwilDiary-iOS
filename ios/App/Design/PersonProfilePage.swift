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
    var source: ProfileSourceAction? = nil
    @ViewBuilder let content: Content
    @State private var header = CompactHeaderState()
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero(height: max(340, geometry.size.width) + (dynamicType.isAccessibilitySize ? 100 : 0), topInset: geometry.safeAreaInsets.top)
                    content.padding(.horizontal, 14)
                }.padding(.bottom, 28)
            }.coordinateSpace(name: "profile-scroll")
                .ignoresSafeArea(.container, edges: .top)
                .background(.black).tint(Color(webHex: "#e6e2ec"))
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) { ProfileHeaderBackdrop(state: header, topInset: geometry.safeAreaInsets.top) }
                .toolbar {
                    ToolbarItem(placement: .principal) { ProfileCompactName(name: name, state: header) }
                    ToolbarItem(placement: .topBarTrailing) {
                        ProfileFavourite(name: name, image: image, kind: kind, ref: ref,
                                         subtitle: favouriteSubtitle, identifier: identifier + "-favourite")
                    }
                }
        }.toolbarBackground(.hidden, for: .navigationBar)
            .modifier(ProfileNativeLinks(kind: kind, ref: ref))
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
            if ProfileText.line(role) != nil || source != nil {
                HStack(alignment: .center, spacing: 12) {
                    if let role = ProfileText.line(role) { Text(role).font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 0)
                    if let source { source }
                }
            }
        }.padding(.horizontal, 14).padding(.bottom, 16)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
            .background {
                GeometryReader { proxy in
                    Artwork(path: image, title: name).frame(width: proxy.size.width, height: proxy.size.height)
                        .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.14), location: 0),
                            .init(color: .black.opacity(0.15), location: 0.45), .init(color: .black.opacity(0.8), location: 0.82),
                            .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                        .overlay(LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing))
                        .clipped().allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

private struct ProfileHeaderBackdrop: View {
    let state: CompactHeaderState
    let topInset: CGFloat
    var body: some View {
        Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.22))
            .opacity(Double(state.progress)).frame(height: topInset).offset(y: -topInset)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ProfileCompactName: View {
    let name: String
    let state: CompactHeaderState
    var body: some View {
        Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            .foregroundStyle(.white).opacity(Double(state.progress))
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
            Image(systemName: saved ? "heart.fill" : "heart").foregroundStyle(theme.accent)
        }.accessibilityLabel(saved ? "Remove from favourites" : "Add to favourites")
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
                    }.buttonStyle(.plain).foregroundStyle(Color(webHex: "#e6e2ec"))
                        .accessibilityLabel(expanded ? "Collapse " + (identifier == "profile-aliases" ? "names" : "biography") : "Expand " + (identifier == "profile-aliases" ? "names" : "biography"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: String(text.characters)) { _, _ in expanded = false }
        }
    }
    private var prose: some View {
        Text(text).font(style).lineSpacing(5).foregroundStyle(.secondary)
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

struct ProfileSourceLogo: View {
    var loading = false
    var body: some View {
        Image("tmdb-logo").renderingMode(.original).resizable().scaledToFit()
            .frame(width: 30, height: 14).opacity(loading ? 0.3 : 1)
            .frame(width: 44, height: 44)
            .background(Color(webHex: "#1b1b20"), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
            .overlay { if loading { ProgressView().controlSize(.small).tint(.white) } }
    }
}
