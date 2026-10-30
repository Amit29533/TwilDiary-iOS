import SwiftUI
import TwilDiaryCore

/// Resolve AniList's anime to an existing diary title or TMDB detail, without importing it.
struct AnimeAppearanceView: View {
    let appearance: AniAppearance
    @Environment(DiaryStore.self) private var store
    @State private var savedID: String?
    @State private var catalog: CatalogRoute?
    @State private var choices: [CatalogItem] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let savedID { TitleDetailView(id: savedID) }
            else if let catalog { CatalogDetailView(route: catalog) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            Artwork(path: appearance.cover, title: appearance.title)
                                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(appearance.title).font(.title2.weight(.semibold))
                                if let year = appearance.year { Text(String(year)).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if loading { DiaryLoadingPlaceholder(label: "Finding this anime") }
                        if let failure { RetryNotice(message: failure) { retry += 1 } }
                        if !choices.isEmpty {
                            Text("Choose the matching title").font(.headline)
                            CatalogGrid(items: choices, showsLayoutToggle: false)
                        } else if !loading && failure == nil {
                            Text("No matching title was found in TMDB.").foregroundStyle(.secondary)
                        }
                        Link("View on AniList", destination: URL(string: "https://anilist.co/anime/\(appearance.id)")!)
                            .font(.system(size: 14)).frame(minHeight: 44)
                    }.padding(14).padding(.bottom, 28)
                }.diaryScreenBackground().navigationTitle("Find anime").navigationBarTitleDisplayMode(.inline)
                    .accessibilityIdentifier("anime-appearance-matches")
            }
        }.task(id: retry) { await resolve() }
    }

    private func resolve() async {
        guard savedID == nil, catalog == nil else { return }
        let local = AnimeTitleMatching.saved(store.workspace.activeTitles, names: appearance.names,
                                            year: appearance.year, kind: appearance.kind)
        if local.count == 1 { savedID = local[0].id; return }
        loading = true; failure = nil; choices = []
        defer { loading = false }
        var searched = Set<String>()
        do {
            for name in appearance.names {
                let query = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                guard query.count >= 2, searched.insert(query.lowercased()).inserted else { continue }
                let page = try await store.searchDiary(query)
                guard !Task.isCancelled else { return }
                if !page.onlineError.isEmpty { failure = page.onlineError; return }
                choices = CatalogTools.merging(choices, page.online).filter {
                    appearance.kind == nil || $0.mediaType == appearance.kind
                }
                if let match = AnimeTitleMatching.catalog(choices, names: appearance.names,
                                                         year: appearance.year, kind: appearance.kind) {
                    if let id = store.libraryIdentity(match) { savedID = id }
                    else { catalog = match.route }
                    return
                }
                // At most two distinct names (English and romaji) per tap.
                if searched.count >= 2 { break }
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
