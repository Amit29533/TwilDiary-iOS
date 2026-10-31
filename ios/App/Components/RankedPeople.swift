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
}

struct MostWatchedSection<Content: View>: View {
    var user: String? = nil
    var ranking: PeopleRankingRoute? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Most watched").font(.system(size: 20, weight: .semibold))
                    .accessibilityValue(ranking?.status ?? "")
                Spacer(minLength: 4)
                if let user {
                    NavigationLink(value: AppDestination.anilist) {
                        Image("site-anilist").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 18, height: 18).frame(width: 36, height: 44)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("AniList profile " + user + ", change in Settings").accessibilityIdentifier("anilist-user")
                }
                if let ranking, !ranking.people.isEmpty {
                    NavigationLink(value: ranking) {
                        HStack(spacing: 4) {
                            Text("View all \(ranking.people.count)")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }.font(.system(size: 13)).foregroundStyle(.secondary).frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityIdentifier(ranking.identifier + "-more")
                }
            }
            content
        }
    }
}

struct MostWatchedShelf: View {
    let ranking: PeopleRankingRoute
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(ranking.people.enumerated()), id: \.element.id) { index, person in
                    RankedPersonLink(person: person, identifier: ranking.identifier) {
                        VStack(alignment: .leading, spacing: 5) {
                            Artwork(path: person.row.image, title: person.row.name).aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .bottomLeading) {
                                    Text("#\(index + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(.white).padding(.horizontal, 6).frame(minHeight: 22)
                                        .background(.black.opacity(0.78), in: Capsule()).padding(6)
                                }
                            Text(person.row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                            Text([person.row.count, person.row.extra].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                        }.multilineTextAlignment(.leading).contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                    }.containerRelativeFrame(.horizontal) { width, _ in min(144, max(96, (width - 36) / 3.2)) }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(route.category).font(.system(size: 24, weight: .bold)).accessibilityIdentifier("people-ranking-category")
                if let status = route.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(route.people.enumerated()), id: \.element.id) { index, person in
                    RankedPersonLink(person: person, identifier: "ranking-" + route.identifier) {
                        HStack(alignment: .center, spacing: 10) {
                            Text(String(index + 1)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 22)
                            Artwork(path: person.row.image, title: person.row.name).frame(width: 52, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.row.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                if let detail = person.row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                Text([person.row.count, person.row.extra].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(12).background(Color(webHex: "#121116"), in: RoundedRectangle(cornerRadius: 14))
                            .multilineTextAlignment(.leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
                    }
                }
            }.padding(.horizontal, 14).padding(.top, 8)
        }.contentMargins(.bottom, 100, for: .scrollContent).diaryScreenBackground().tint(Color(webHex: "#e6e2ec"))
            .navigationTitle("Most watched").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
