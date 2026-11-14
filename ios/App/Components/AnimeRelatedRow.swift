import SwiftUI
import TwilDiaryCore

/// "Related" on an anime's page, above More like this (owner's design): its sequels, prequels,
/// side stories and the like from AniList, each poster labelled with how it relates ("Sequel",
/// "Side story", "Other"). One already in your diary shows your score and, when completed, a
/// tick. A tap opens it as other anime posters do (your diary's copy, else TMDB's page).
struct AnimeRelatedRow: View {
    let title: String
    let year: Int?
    let movie: Bool
    @Environment(DiaryStore.self) private var store
    @State private var items: [AniRelated] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Related").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                        .frame(minHeight: 44)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(items) { item in
                                AnimeAppearanceButton(appearance: item.appearance) { card(item) }
                                    .buttonStyle(.springPress).accessibilityIdentifier("related-anime-" + String(item.id))
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled().accessibilityIdentifier("related-anime-shelf")
                }
            }
        }.task(id: title) { items = (try? await AniListClient.shared.related(title: title, year: year, movie: movie)) ?? [] }
    }

    /// The poster with its relation over a dark fade at the bottom, and your score and tick on top.
    private func card(_ item: AniRelated) -> some View {
        let saved = diaryTitle(item.appearance)
        return Artwork(path: item.appearance.cover, title: item.appearance.title, initialsOnly: false)
            .frame(width: 128, height: 184).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    Text(item.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                }.clipShape(RoundedRectangle(cornerRadius: 18)).allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if let saved {
                    HStack(spacing: -6) {
                        if let score = saved.score, score > 0 {
                            Text(String(Int(score.rounded()))).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Color(webHex: "#3b4a9c"), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        }
                        if saved.status == "completed" {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Color(webHex: "#3f9a4f"), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        }
                    }.padding(8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([item.label, item.appearance.title, saved.map { $0.status == "completed" ? "completed" : "in your diary" }].compactMap { $0 }.joined(separator: ", "))
    }

    /// Your diary's copy of it: the same name (any of AniList's titles), released within a year.
    private func diaryTitle(_ appearance: AniAppearance) -> MediaTitle? {
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let names = Set(appearance.names.map(plain).filter { !$0.isEmpty })
        return store.activeTitles.first { title in
            guard title.category == "anime" || title.category == "anime-movie", names.contains(plain(title.name)) else { return false }
            guard let a = appearance.year, let b = title.year else { return true }
            return abs(a - b) <= 1
        }
    }
}
