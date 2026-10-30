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
                .overlay(alignment: .top) { CompactHeaderBackdrop(state: header, topInset: geometry.safeAreaInsets.top) }
                .toolbar {
                    ToolbarItem(placement: .principal) { ProfileCompactName(name: name, state: header) }
                    ToolbarItem(placement: .topBarTrailing) {
                        ProfileFavourite(name: name, image: image, kind: kind, ref: ref,
                                         subtitle: favouriteSubtitle, identifier: identifier + "-favourite")
                    }
                }
        }
    }

    private func hero(height: CGFloat, topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 150)
            Text(name).font(.system(size: 34, weight: .bold)).tracking(-0.9)
                .foregroundStyle(LinearGradient(colors: [.white, theme.accent], startPoint: .leading, endPoint: .trailing))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + "-name")
                .onGeometryChange(for: CGFloat.self) { proxy in
                    CompactHeaderTransition.progress(nameBottom: proxy.frame(in: .named("profile-scroll")).maxY - topInset)
                } action: { header.update($0) }
            if let nativeName, !nativeName.isEmpty, nativeName != name {
                Text(nativeName).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }
            if let role, !role.isEmpty { Text(role).font(.subheadline).foregroundStyle(.white.opacity(0.7)) }
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
    @State private var feedback = 0
    private var saved: Bool { FavouritesStore.shared.contains(kind, ref) }
    var body: some View {
        Button {
            FavouritesStore.shared.toggle(kind, ref: ref, name: name, image: image, subtitle: subtitle, store: store)
            feedback += 1
        } label: {
            Image(systemName: saved ? "heart.fill" : "heart").foregroundStyle(.white)
        }.accessibilityLabel(saved ? "Remove from favourites" : "Add to favourites")
            .accessibilityValue(saved ? "Saved" : "Not saved").accessibilityIdentifier(identifier)
            .sensoryFeedback(.selection, trigger: feedback)
    }
}

/// Wrapping intrinsic chips rather than a table or fixed-width columns. Long
/// places and accessibility text can wrap without colliding with the source button.
struct ProfileDetailChip: View {
    let icon: String
    let label: String
    let value: String
    var identifier = ""
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 19)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }.foregroundStyle(Color(webHex: "#e6e2ec")).padding(10).frame(minHeight: 52)
            .background(Color(webHex: "#17171c"), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
}

struct ProfileDetailLine: View {
    let label: String
    let value: String
    var body: some View {
        Text(label + ": " + value).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ProfileBiography: View {
    let text: AttributedString
    @Binding var expanded: Bool
    var identifier = "profile-biography"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if !text.characters.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 16)).lineSpacing(5).foregroundStyle(.secondary)
                    .tint(Color(webHex: "#d1cdd8")).lineLimit(expanded ? nil : 4)
                    .accessibilityIdentifier(identifier)
                Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { expanded.toggle() } } label: {
                    HStack(spacing: 5) { Text(expanded ? "Less" : "More"); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption) }
                        .font(.subheadline).frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(Color(webHex: "#e6e2ec"))
                    .accessibilityLabel(expanded ? "Collapse biography" : "Expand biography")
            }
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
                            .background(Color(webHex: "#1b1b20"), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                    }.buttonStyle(.plain).accessibilityLabel(link.label)
                        .accessibilityHint("Opens website").accessibilityIdentifier("profile-site-" + link.id)
                }
            }
        }
    }
}

struct ProfileSourceLogo: View {
    var loading = false
    var body: some View {
        Image("tmdb-logo").renderingMode(.original).resizable().scaledToFit()
            .frame(width: 40, height: 18).opacity(loading ? 0.3 : 1)
            .frame(width: 64, height: 52)
            .background(Color(webHex: "#1b1b20"), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .overlay { if loading { ProgressView().controlSize(.small).tint(.white) } }
    }
}
