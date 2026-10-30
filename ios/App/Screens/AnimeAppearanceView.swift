import SwiftUI
import TwilDiaryCore

/// Resolve AniList's anime to an existing diary title or TMDB detail, without importing it.
struct AnimeAppearanceView: View {
    let appearance: AniAppearance
    @Environment(DiaryStore.self) private var store
    @State private var savedID: String?
    @State private var catalog: CatalogRoute?
    @State private var identified: [SearchLibraryTitle] = []
    @State private var choices: [CatalogItem] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var retry = 0
    @State private var generation = UUID()

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
                        if !choices.isEmpty || !identified.isEmpty {
                            Text("Choose the matching title").font(.headline)
                            ForEach(identified) { title in
                                Button { Task { await chooseLibrary(title.id) } } label: {
                                    HStack(spacing: 12) {
                                        Artwork(path: title.artwork, title: title.name)
                                            .frame(width: 56, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(title.name).font(.headline).foregroundStyle(.primary)
                                            Text("In your library").font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.springPress).accessibilityIdentifier("anime-library-" + title.id)
                            }
                            if !choices.isEmpty { CatalogGrid(items: choices, showsLayoutToggle: false) }
                        } else if !loading && failure == nil {
                            Text("No matching title was found in TMDB.").foregroundStyle(.secondary)
                        }
                    }.padding(14).padding(.bottom, 28)
                }.diaryScreenBackground().navigationTitle("Choose title").navigationBarTitleDisplayMode(.inline)
                    .accessibilityIdentifier("anime-appearance-matches")
            }
        }.task(id: retry) { await resolve() }
    }

    private func resolve() async {
        guard savedID == nil, catalog == nil else { return }
        let request = UUID(); generation = request
        failure = nil; choices = []
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let found = try await store.animeNavigation.title(appearance, service: store)
            guard !Task.isCancelled, generation == request else { return }
            switch found.destination {
            case .saved(let id)?: savedID = id
            case .catalog(let route)?: catalog = route
            case nil:
                identified = found.page.library; choices = found.page.online
            }
        } catch {
            if !Task.isCancelled, generation == request { failure = error.localizedDescription }
        }
    }

    private func chooseLibrary(_ id: String) async {
        if store.title(id) == nil { await store.refresh() }
        guard !Task.isCancelled else { return }
        guard store.title(id) != nil else { failure = "This title is no longer available. Refresh your library and try again."; return }
        savedID = id
    }
}
