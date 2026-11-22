import SwiftUI

/// A person on your Jellyfin server, for the diary's profile of them: found by name (their TMDB name,
/// then their other names: "Yu Jae-seok" may be "Yoo Jae-suk" there) and kept only when the TMDB id
/// Jellyfin has for them is this one, so a namesake never counts. Kept while the app runs.
@MainActor enum JellyPersonLinks {
    struct Found: Sendable {
        let id: String
        let name: String
        let count: Int
        let titles: [JellyfinClient.Item]
    }
    /// By TMDB id; a stored nil means looked up and not on the server.
    private static var known: [Int: Found?] = [:]

    static func find(tmdb: Int, names: [String]) async -> Found? {
        if let cached = known[tmdb] { return cached }
        guard let client = JellySpace.client else { return nil }
        var match: JellyfinClient.Item?
        do {
            for name in names.prefix(4) where match == nil {
                match = try await client.person(tmdb: tmdb, name: name)
            }
        } catch {
            // Out of reach (away from home): no card, and asked again next time.
            return nil
        }
        guard let match else { known[tmdb] = .some(nil); return nil }
        let user = await JellyfinUser.id(client)
        guard let page = try? await client.titles(person: match.Id, user: user), page.TotalRecordCount > 0 else {
            known[tmdb] = .some(nil)
            return nil
        }
        let found = Found(id: match.Id, name: match.Name ?? names.first ?? "", count: page.TotalRecordCount, titles: page.Items)
        known[tmdb] = found
        return found
    }
}

/// "In JellySpace · 2 titles on your server" on the diary's profile, under From: the titles' names and
/// posters; a tap opens their JellySpace page (only what's on your server). Styled as the From card.
struct JellyPersonCard: View {
    let found: JellyPersonLinks.Found
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        let client = JellySpace.client
        NavigationLink(value: JellyListRoute(kind: .person, id: found.id, name: found.name)) {
            HStack(spacing: 12) {
                Image("jellyfin-mark").resizable().scaledToFit().frame(width: 22, height: 22)
                    .frame(width: 36, height: 36).background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("IN JELLYSPACE").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Color(themed: "#a9a7b6"))
                    Text(found.count == 1 ? "1 title on your server" : "\(found.count) titles on your server")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Text(found.titles.prefix(3).compactMap(\.Name).joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color(themed: "#a9a7b6")).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let client {
                    HStack(spacing: 4) {
                        ForEach(found.titles.prefix(2), id: \.Id) { title in
                            ZStack {
                                Rectangle().fill(HomeStyle.card)
                                JellyImage(url: JellyfinClient.posterURL(base: client.base, item: title.Id, tag: title.ImageTags?["Primary"]))
                            }
                            .frame(width: 26, height: 38).clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }.accessibilityHidden(true)
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(themed: "#a9a7b6"))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ProfileCardSurface())
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens their films and shows on your Jellyfin server")
        .accessibilityIdentifier("person-jellyspace")
    }
}
