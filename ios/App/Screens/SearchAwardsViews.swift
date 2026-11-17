import SwiftUI
import TwilDiaryCore

struct SearchAwardsShelf: View {
    var body: some View {
        let editions = SearchAwardEdition.all
        if !editions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SearchBrowseHeading(shelf: .awards)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(editions.prefix { $0.year == editions.first?.year }) { edition in
                            SearchAwardCard(edition: edition)
                                .containerRelativeFrame(.horizontal) { width, _ in min(215, width * 0.44) }
                        }
                    }.padding(.horizontal, 14)
                }.padding(.horizontal, -14).scrollIndicators(.hidden)
            }
        }
    }
}

struct SearchAwardsPage: View {
    @State private var ceremony: SearchAwardCeremony?
    @State private var year: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var editions: [SearchAwardEdition] {
        SearchAwardEdition.all.filter { (ceremony == nil || $0.ceremony == ceremony) && (year == nil || $0.year == year) }
    }
    private var coverage: String? {
        let years = SearchAwardEdition.all.map(\.year)
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { filters }
                } else {
                    HStack(spacing: 8) { filters }
                }
                if let coverage {
                    Text("Selected categories · \(coverage)").font(.subheadline).foregroundStyle(HomeStyle.secondary)
                }
                if editions.isEmpty {
                    ContentUnavailableView("No matching ceremonies", systemImage: "trophy",
                                           description: Text("Choose another ceremony or year."))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(editions) { SearchAwardCard(edition: $0) }
                    }
                }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle("Awards").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    @ViewBuilder private var filters: some View {
        Menu {
            Picker("Ceremony", selection: $ceremony) {
                Text("All ceremonies").tag(SearchAwardCeremony?.none)
                ForEach(SearchAwardCeremony.allCases.filter { item in SearchAwardEdition.all.contains { $0.ceremony == item } }) {
                    Text($0.title).tag(Optional($0))
                }
            }
        } label: {
            filterLabel(ceremony?.title ?? "Ceremony", symbol: "trophy")
        }.accessibilityIdentifier("search-award-ceremony-filter")
        Menu {
            Picker("Year", selection: $year) {
                Text("All years").tag(Int?.none)
                ForEach(Set(SearchAwardEdition.all.map(\.year)).sorted(by: >), id: \.self) {
                    Text(String($0)).tag(Optional($0))
                }
            }
        } label: {
            filterLabel(year.map(String.init) ?? "Year", symbol: "calendar")
        }.accessibilityIdentifier("search-award-year-filter")
    }

    private func filterLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Label(title, systemImage: symbol).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
        }.font(.subheadline.weight(.medium)).foregroundStyle(HomeStyle.primary)
            .padding(.horizontal, 13).frame(minHeight: 44)
            .background(HomeStyle.round, in: Capsule())
    }
}

private struct SearchAwardCard: View {
    let edition: SearchAwardEdition
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 100

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.ceremony(edition)) {
            VStack(alignment: .leading, spacing: 8) {
                let tint = Color(webHex: edition.ceremony.tint)
                Image(systemName: edition.ceremony.symbol).font(.title2.weight(.semibold))
                    .foregroundStyle(tint).accessibilityHidden(true)
                Text(edition.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(
                        LinearGradient(colors: [Color(webHex: edition.ceremony.tint).opacity(0.25), Color(webHex: "#171620")],
                                       startPoint: .topTrailing, endPoint: .bottomLeading)
                    ).background(Color(webHex: "#171620"), in: RoundedRectangle(cornerRadius: 14))
                }.contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.springPress).accessibilityIdentifier("search-award-" + edition.id)
    }
}

struct SearchAwardEditionPage: View {
    let edition: SearchAwardEdition

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Featured categories").font(.subheadline).foregroundStyle(HomeStyle.secondary)
                ForEach(edition.categories) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.title).font(.headline).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(category.winners, id: \.self) { awardRow($0, kind: category.kind, winner: true) }
                            Divider().padding(.horizontal, 12)
                            Text("Nominees").font(.caption.weight(.semibold)).foregroundStyle(HomeStyle.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 10)
                            ForEach(category.nominees, id: \.self) { awardRow($0, kind: category.kind, winner: false) }
                        }.cardSurface(14)
                    }
                }
                Link(destination: edition.source) {
                    Label("Official results", systemImage: "arrow.up.right.square")
                        .frame(minHeight: 44)
                }.foregroundStyle(ThemeStore.accent)
            }.padding(14).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle(edition.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    private func awardRow(_ name: String, kind: MediaKind, winner: Bool) -> some View {
        NavigationLink(value: SearchBrowseRoute.awardTitle(name, kind, ceremonyYear: edition.year)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.subheadline.weight(.medium)).foregroundStyle(HomeStyle.primary)
                    if winner {
                        Label("Winner", systemImage: "trophy.fill").font(.caption.weight(.semibold))
                            .foregroundStyle(Color(themed: "#e7ca90"))
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HomeStyle.secondary)
                    .accessibilityHidden(true)
            }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SearchAwardTitlePage: View {
    let title: String
    let kind: MediaKind
    let ceremonyYear: Int
    @Environment(DiaryStore.self) private var store
    @State private var online: [CatalogItem] = []
    @State private var library: [SearchLibraryTitle] = []
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if !library.isEmpty {
                    Text("In your library").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(library) { item in
                        NavigationLink(value: item.id) {
                            HStack(spacing: 12) {
                                Artwork(path: item.artwork, title: item.name).frame(width: 42, height: 63)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.headline)
                                    if let year = item.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(10).cardSurface(14).contentShape(Rectangle())
                        }.buttonStyle(.springPress)
                            .accessibilityIdentifier("search-award-library-" + item.id)
                    }
                }
                if !online.isEmpty {
                    if (online.count + library.count) > 1 {
                        Text("Catalog matches").font(.headline).accessibilityAddTraits(.isHeader)
                        Text("Use the title and release year to choose the credited work.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    CatalogGrid(items: online, showsLayoutToggle: false, forceGrid: true)
                }
                if let failure { RetryNotice(message: failure) { Task { await load() } } }
                else if !loaded {
                    DiaryLoadingPlaceholder(label: "Finding title", layout: .posterGrid(columns: 3, rows: 1))
                } else if library.isEmpty && online.isEmpty {
                    ContentUnavailableView("No catalog match", systemImage: "film")
                }
            }.padding(14)
        }.diaryScreenBackground().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { if !loaded { await load() } }
    }

    private func load() async {
        failure = nil
        let aliases = [title] + (Self.alternateTitles[title] ?? [])
        let names = Set(aliases.map(Self.matchKey))
        library = store.activeTitles.map { SearchLibraryTitle($0) }.filter { matches($0, names: names) }
        do {
            var found: [CatalogItem] = []
            for alias in aliases {
                let page = try await store.searchDiary(alias, page: 1)
                try Task.checkCancellation()
                if !page.onlineError.isEmpty { throw APIError.message(page.onlineError) }
                library = DiarySearchTools.merging(library, page.library.filter { matches($0, names: names) })
                found = CatalogTools.merging(found, page.online.filter {
                    $0.mediaType == kind && names.contains(Self.matchKey($0.name)) && ($0.year ?? 0) <= ceremonyYear
                })
                online = found.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                if !found.isEmpty || !library.isEmpty { break }
            }
            loaded = true
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func matches(_ item: SearchLibraryTitle, names: Set<String>) -> Bool {
        let movie = item.category == "movie" || item.category == "anime-movie"
        return movie == (kind == .movie) && (item.year ?? 0) <= ceremonyYear
            && [item.name, item.matchedName].compactMap { $0 }.contains { names.contains(Self.matchKey($0)) }
    }

    private static let alternateTitles = ["F1": ["F1 The Movie"], "Wolf Hall: The Mirror and the Light": ["Wolf Hall"]]

    nonisolated private static func matchKey(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
