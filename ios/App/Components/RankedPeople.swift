import SwiftUI
import TwilDiaryCore

/// The existing ranking projection, kept separate from its shelf/list layout.
struct RankedRow: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String?
    let image: String?
    let number: Int
    let count: String
    let extra: String?
}

enum RankedProfileDestination: Hashable {
    case cast(Int)
    case character(Int)
    case voice(VoiceActorRoute)
}

struct RankedPerson: Identifiable, Hashable {
    let row: RankedRow
    let destination: RankedProfileDestination
    var id: Int { row.id }

    static func diary(_ row: RankedRow, voice: Bool, staffID: Int? = nil) -> Self {
        Self(row: row, destination: voice
             ? .voice(VoiceActorRoute(id: staffID, name: row.name, tmdbID: row.id, watchedCount: row.number)) : .cast(row.id))
    }
    static func aniList(_ row: RankedRow, voice: Bool) -> Self {
        Self(row: row, destination: voice
             ? .voice(VoiceActorRoute(id: row.id, name: row.name, watchedCount: row.number)) : .character(row.id))
    }
}

/// Carry the confirmed snapshot and provider identities into View all. Opening
/// the complete list never repeats the server ranking or AniList name lookup.
struct PeopleRankingRoute: Hashable {
    let category: String
    let identifier: String
    let people: [RankedPerson]
    var status: String? = nil
    /// "AniList" when the ranking comes from your AniList profile (shown as a pill).
    var source: String? = nil
}

/// "ANILIST": a small outlined pill naming where a ranking comes from.
struct RankingSourcePill: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(HomeStyle.secondary)
            .padding(.horizontal, 11).frame(height: 28).background(HomeStyle.round, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: 1))
    }
}

/// The heart on a person's card: outlined until hearted, then filled lilac. Tapping adds or removes
/// them from Favourites at once.
struct FavouriteHeartButton: View {
    let kind: Favourite.Kind
    let ref: Int
    let name: String
    let image: String?
    let subtitle: String?
    var size: CGFloat = 34
    var tinted = false
    @Environment(DiaryStore.self) private var store
    @State private var feedback = 0
    var body: some View {
        let saved = FavouritesStore.shared.contains(kind, ref)
        Button {
            FavouritesStore.shared.toggle(kind, ref: ref, name: name, image: image, subtitle: subtitle, store: store)
            feedback += 1
        } label: {
            Image(systemName: saved ? "heart.fill" : "heart").font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(saved ? HomeStyle.chipText : .white)
                .frame(width: size, height: size)
                .background(tinted ? AnyShapeStyle(HomeStyle.chip) : AnyShapeStyle(Color.black.opacity(0.55)), in: Circle())
                .frame(width: max(44, size), height: max(44, size)).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(saved ? "Remove " + name + " from favourites" : "Add " + name + " to favourites")
            .accessibilityValue(saved ? "Saved" : "Not saved").sensoryFeedback(.selection, trigger: feedback)
    }
}

extension RankedPerson {
    /// What a heart on this person saves: cast by TMDB id, characters and voice actors by AniList id.
    var favourite: (kind: Favourite.Kind, ref: Int)? {
        switch destination {
        case .cast(let id): (.cast, id)
        case .character(let id): (.character, id)
        case .voice(let route): route.id.map { (.voice, $0) }
        }
    }
}

struct MostWatchedSection<Content: View>: View {
    var heading: String? = "Most watched"
    var user: String? = nil
    var ranking: PeopleRankingRoute? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if heading != nil || !(ranking?.people.isEmpty ?? true) {
            HStack(spacing: 8) {
                if let heading {
                    Text(heading).font(.system(size: 24, weight: .bold)).tracking(-0.4).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        .accessibilityValue(ranking?.status ?? "").accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 4)
                if let ranking, !ranking.people.isEmpty {
                    SectionMoreLink(label: "View all \(ranking.people.count)", value: ranking, identifier: ranking.identifier + "-more")
                }
            }
            }
            content
        }
    }
}

struct MostWatchedShelf: View {
    let ranking: PeopleRankingRoute
    /// Three round photos with name and count, then a round See all (Statistics' reference design).
    var round = false
    var body: some View {
        if round { roundRow } else { shelf }
    }
    private var roundRow: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(ranking.people.prefix(3))) { person in
                RankedPersonLink(person: person, identifier: ranking.identifier) {
                    VStack(spacing: 6) {
                        Artwork(path: person.row.image, title: person.row.name, alignment: .top).frame(width: 64, height: 64).clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                        Text(person.row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            .multilineTextAlignment(.center).lineLimit(2).truncationMode(.tail)
                        Text(person.row.count).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle()).accessibilityElement(children: .combine)
                }
            }
            NavigationLink(value: ranking) {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                        .frame(width: 64, height: 64).background(HomeStyle.round, in: Circle())
                        .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    Text("See all").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("See all \(ranking.people.count)").accessibilityIdentifier(ranking.identifier + "-more")
        }
    }
    private var shelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(ranking.people.enumerated()), id: \.element.id) { index, person in
                    RankedPersonLink(person: person, identifier: ranking.identifier) {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear.aspectRatio(0.83, contentMode: .fit)
                                .overlay { Artwork(path: person.row.image, title: person.row.name, alignment: .top) }
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
                                .overlay(alignment: .topLeading) {
                                    Text("#\(index + 1)").font(.system(size: 12, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(Color(webHex: "#1a1030")).padding(.horizontal, 8).frame(height: 24)
                                        .background(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .top, endPoint: .bottom), in: Capsule())
                                        .padding(8)
                                }
                                .padding(.bottom, 6)
                            Text(person.row.name).font(.system(size: 16, weight: .bold)).foregroundStyle(HomeStyle.primary)
                                .lineLimit(1).truncationMode(.tail)
                            Text([person.row.count, person.row.extra].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
                        }.multilineTextAlignment(.leading).contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let saved = person.favourite {
                            FavouriteHeartButton(kind: saved.kind, ref: saved.ref, name: person.row.name, image: person.row.image, subtitle: person.row.detail)
                                .padding(-2)
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in min(150, max(100, (width - 36) / 2.85)) }
                }
            }.scrollTargetLayout()
        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            .accessibilityIdentifier(ranking.identifier + "-shelf")
    }
}

private struct RankedPersonLink<Label: View>: View {
    let person: RankedPerson
    let identifier: String
    @ViewBuilder let label: Label
    var body: some View {
        Group {
            switch person.destination {
            case .cast(let id): NavigationLink(value: PersonRoute(id: id)) { label }
            case .character(let id): NavigationLink(value: CharacterRoute(id: id)) { label }
            case .voice(let route): NavigationLink(value: route) { label }
            }
        }.buttonStyle(.plain).accessibilityIdentifier(identifier + "-" + String(person.id))
    }
}

struct PeopleRankingView: View {
    let route: PeopleRankingRoute
    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(route.category).font(.system(size: 34, weight: .bold)).tracking(-0.8).foregroundStyle(HomeStyle.primary)
                        .lineLimit(1).minimumScaleFactor(0.8).accessibilityIdentifier("people-ranking-category")
                }.padding(.bottom, 4)
                if let status = route.status { Text(status).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary) }
                ForEach(Array(route.people.enumerated()), id: \.element.id) { index, person in
                    RankedPersonLink(person: person, identifier: "ranking-" + route.identifier) {
                        HStack(alignment: .center, spacing: 14) {
                            Text(String(index + 1)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                                .foregroundStyle(index < 3 ? HomeStyle.chipText : HomeStyle.secondary).frame(width: 30)
                            Artwork(path: person.row.image, title: person.row.name, alignment: .top).frame(width: 52, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.row.name).font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                                if let detail = person.row.detail, !detail.isEmpty {
                                    Text(detail).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
                                }
                                Text([person.row.count, person.row.extra].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.chipText).lineLimit(1)
                                    .padding(.horizontal, 10).frame(height: 26).background(HomeStyle.chip, in: Capsule())
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        }.padding(.horizontal, 14).padding(.vertical, 12)
                            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                            .multilineTextAlignment(.leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().tint(Color(webHex: "#e6e2ec"))
            .navigationTitle("Most watched").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
