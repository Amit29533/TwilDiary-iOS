import Observation
import SwiftUI
import TwilDiaryCore

struct SearchAwardsShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .awards)
            SearchAwardGrid {
                ForEach(SearchAwardCeremony.featured) { AwardCeremonyLink(ceremony: $0) }
            }
        }
    }
}

struct SearchAwardsPage: View {
    @Environment(DiaryStore.self) private var store
    @State private var ceremonies = SearchAwardCeremony.featured
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                SearchAwardGrid {
                    ForEach(ceremonies) { AwardCeremonyLink(ceremony: $0) }
                }
                if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Loading award ceremonies")
                }
                AwardsAttribution()
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle("Awards").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { if !loaded { await load() } }
    }

    private func load() async {
        failure = nil
        if store.isPreview { loaded = true; return }
        guard let key = TVDBDirect.key(store) else {
            failure = "Connect TheTVDB in Profile → Connections to load all ceremonies."
            return
        }
        do {
            let available = try await SearchAwardsArchiveService.ceremonies(key: key)
            try Task.checkCancellation()
            ceremonies = available
            loaded = true
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

private struct SearchAwardGrid<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                  count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
            content
        }
    }
}

private struct AwardCeremonyLink: View {
    let ceremony: SearchAwardCeremony

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.ceremony(ceremony)) {
            let style = ceremony.style
            SearchBrowseArtworkTile(title: ceremony.displayName, symbol: style.symbol, tint: style.tint, artwork: ceremony.artwork)
        }.buttonStyle(.springPress).accessibilityIdentifier("search-award-ceremony-\(ceremony.id)")
    }
}

private struct AwardsAttribution: View {
    var body: some View {
        Link(destination: URL(string: "https://www.thetvdb.com/awards")!) {
            Label("Awards data from TheTVDB", systemImage: "arrow.up.right.square")
                .font(.footnote).frame(minHeight: 44)
        }.foregroundStyle(ThemeStore.accent)
    }
}

@MainActor @Observable private final class AwardArchiveLoader {
    private(set) var archive: SearchAwardArchive? {
        didSet { editions = archive.map { SearchAwardEditionIndex($0) } }
    }
    private(set) var editions: SearchAwardEditionIndex?
    private(set) var failure: String?
    private(set) var loading = false
    private(set) var progress: (finished: Int, total: Int)?

    func load(_ ceremony: SearchAwardCeremony, store: DiaryStore, refresh: Bool = false) async {
        guard !loading else { return }
        loading = true
        failure = nil
        progress = nil
        defer { loading = false }
        #if DEBUG
        if store.isPreview { archive = SearchAwardArchive.preview; return }
        #endif
        let cached = await SearchAwardCache.shared.read(ceremony.id)
        guard !Task.isCancelled else { return }
        archive = cached
        guard let key = TVDBDirect.key(store) else {
            failure = "Connect TheTVDB in Profile → Connections to refresh this archive."
            return
        }
        do {
            let available = try await SearchAwardsArchiveService.load(ceremony, key: key, refresh: refresh) { finished, total in
                progress = (finished, total)
            }
            try Task.checkCancellation()
            archive = available
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    var progressLabel: String {
        if let progress, progress.total > 0 { return "Loading awards · \(progress.finished) of \(progress.total) categories" }
        return "Loading awards"
    }
}

struct SearchAwardCeremonyPage: View {
    private struct Subcategory: Identifiable {
        let name: String?
        let nominees: [SearchAwardNominee]
        var id: String { name ?? "" }
    }

    let ceremony: SearchAwardCeremony
    @Environment(DiaryStore.self) private var store
    @State private var loader = AwardArchiveLoader()
    @State private var selectedEdition: SearchAwardEditionIndex.Edition?
    @State private var medium: MediaKind = .tv
    @State private var awardType: SearchAwardCategory.AwardType?
    @State private var categoryID: Int?
    @State private var winnersOnly = false

    private var edition: SearchAwardEditionIndex.Edition? {
        guard let editions = loader.editions?.editions else { return nil }
        if let selectedEdition, editions.contains(selectedEdition) { return selectedEdition }
        return editions.first
    }

    private var pageTitle: String {
        if case let .year(year)? = edition { return "\(ceremony.displayName) \(year)" }
        return ceremony.displayName
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let editions = loader.editions {
                    if let edition, let groups = editions.sections[edition] {
                        awardResults(groups, edition: edition, editions: editions.editions)
                    } else if let archive = loader.archive, archive.incompleteCount == 0,
                              !loader.loading, loader.failure == nil {
                        ContentUnavailableView("Results unavailable", systemImage: "trophy",
                                               description: Text("TheTVDB has no winners or nominees for this ceremony."))
                        if !archive.categories.isEmpty {
                            DisclosureGroup("Categories listed by TheTVDB") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(archive.categories) { category in
                                        Text(category.name).font(.subheadline)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.padding(12).cardSurface(14)
                        }
                    }
                }
                if let failure = loader.failure {
                    RetryNotice(message: failure) { Task { await loader.load(ceremony, store: store) } }
                } else if loader.loading || loader.archive == nil {
                    DiaryLoadingPlaceholder(label: loader.progressLabel)
                } else if let archive = loader.archive, archive.incompleteCount > 0 {
                    RetryNotice(message: "TheTVDB couldn’t refresh \(archive.incompleteCount) categories.") {
                        Task { await loader.load(ceremony, store: store) }
                    }
                }
                AwardsAttribution()
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground()
            .navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { if loader.archive == nil { await loader.load(ceremony, store: store) } }
            .refreshable { await loader.load(ceremony, store: store, refresh: true) }
    }

    @ViewBuilder private func awardResults(_ groups: [SearchAwardEditionIndex.Section],
                                           edition: SearchAwardEditionIndex.Edition,
                                           editions: [SearchAwardEditionIndex.Edition]) -> some View {
        let media = groups.reduce(into: Set<MediaKind>()) { $0.formUnion($1.media) }
        let mixed = !ceremony.televisionOnly && media.contains(.movie) && media.contains(.tv)
        let scoped = groups.compactMap { $0.matching(mixed ? medium : nil) }
        let availableTypes = Set(scoped.map { $0.category.awardType })
        let type = awardType.flatMap { availableTypes.contains($0) ? $0 : nil }
        let categories = scoped.filter { group in type.map { $0 == group.category.awardType } ?? true }
        let selectedCategory = categories.first { $0.id == categoryID }?.category
        let sections = categories.filter { selectedCategory == nil || $0.id == selectedCategory?.id }

        filterBar(edition: edition, editions: editions, types: availableTypes, type: type,
                  categories: categories.map(\.category), selectedCategory: selectedCategory)
        if mixed {
            Picker("Movies or shows", selection: mediumSelection) {
                Text("Movies").tag(MediaKind.movie)
                Text("Shows").tag(MediaKind.tv)
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("search-award-medium-filter")
        }

        let results = sections.compactMap { section -> SearchAwardEditionIndex.Section? in
            let nominees = section.nominees.filter { !winnersOnly || $0.isWinner == true }
            guard !nominees.isEmpty else { return nil }
            let winners = nominees.filter { $0.isWinner == true }
            let others = nominees.filter { $0.isWinner != true }
            return SearchAwardEditionIndex.Section(category: section.category, nominees: winners + others)
        }
        if results.isEmpty, !loader.loading {
            ContentUnavailableView("No matching results", systemImage: "trophy",
                                   description: Text("Change a filter or choose another year."))
        }
        ForEach(results) { section in
            VStack(alignment: .leading, spacing: 8) {
                Text(section.category.name).font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(subcategories(section)) { group in
                    if let name = group.name {
                        Text(name).font(.subheadline.weight(.semibold))
                            .foregroundStyle(HomeStyle.secondary).accessibilityAddTraits(.isHeader)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(group.nominees) { nominee in AwardNomineeRow(nominee: nominee) }
                    }.cardSurface(14)
                }
            }
        }
    }

    private var mediumSelection: Binding<MediaKind> {
        Binding(get: { medium }, set: { choice in
            guard choice != medium else { return }
            medium = choice
            awardType = nil
            categoryID = nil
        })
    }

    private func filterBar(edition: SearchAwardEditionIndex.Edition, editions: [SearchAwardEditionIndex.Edition],
                           types: Set<SearchAwardCategory.AwardType>,
                           type: SearchAwardCategory.AwardType?, categories: [SearchAwardCategory],
                           selectedCategory: SearchAwardCategory?) -> some View {
        SearchBrowseFilterStrip {
            Menu {
                Picker("Year", selection: Binding(get: { edition }, set: { choice in
                    guard choice != edition else { return }
                    selectedEdition = choice
                    awardType = nil
                    categoryID = nil
                })) {
                    ForEach(editions, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                AwardFilterPill(label: edition.label, icon: "calendar")
            }.accessibilityIdentifier("search-award-year-filter")
            Menu {
                Picker("Type", selection: Binding(get: { type }, set: { choice in
                    guard choice != type else { return }
                    awardType = choice
                    categoryID = nil
                })) {
                    Text("All").tag(nil as SearchAwardCategory.AwardType?)
                    ForEach(SearchAwardCategory.AwardType.allCases.filter { types.contains($0) }) {
                        Text($0.rawValue).tag(Optional($0))
                    }
                }
            } label: {
                AwardFilterPill(label: type?.rawValue ?? "Type", icon: "line.3.horizontal.decrease", active: type != nil)
            }.accessibilityIdentifier("search-award-type-filter")
            Menu {
                Picker("Category", selection: Binding(get: { selectedCategory?.id }, set: { categoryID = $0 })) {
                    Text("All").tag(nil as Int?)
                    ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                }
            } label: {
                let name = selectedCategory?.name
                let shortName = name.map { $0.count > 22 ? String($0.prefix(21)) + "…" : $0 }
                AwardFilterPill(label: shortName ?? "Category", icon: "list.bullet", active: selectedCategory != nil)
            }.accessibilityIdentifier("search-award-category-filter")
            Button { winnersOnly.toggle() } label: {
                AwardFilterPill(label: "Winners only", icon: "trophy", active: winnersOnly, hasMenu: false)
            }.buttonStyle(.springPress)
                .accessibilityAddTraits(winnersOnly ? .isSelected : [])
                .accessibilityIdentifier("search-award-winners-filter")
        }
    }

    private func subcategories(_ section: SearchAwardEditionIndex.Section) -> [Subcategory] {
        let grouped = Dictionary(grouping: section.nominees) { nominee -> String? in
            guard let label = nominee.subcategory, label.caseInsensitiveCompare(section.category.name) != .orderedSame else { return nil }
            return label
        }
        let labels = grouped.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let ordered = [nil as String?] + labels.map(Optional.some)
        return ordered.compactMap { label in
            grouped[label].map { Subcategory(name: label, nominees: $0) }
        }
    }
}

private struct AwardFilterPill: View {
    let label: String
    let icon: String
    var active = false
    var hasMenu = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(label).lineLimit(1)
            if hasMenu {
                Image(systemName: "chevron.down").font(.caption2.bold()).accessibilityHidden(true)
            }
        }.font(.caption.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .foregroundStyle(active ? HomeStyle.chipText : HomeStyle.primary)
            .background(active ? HomeStyle.chip : HomeStyle.card, in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
    }
}

private struct AwardNomineeRow: View {
    let nominee: SearchAwardNominee
    @Environment(DiaryStore.self) private var store
    @Environment(\.locale) private var locale
    @State private var englishWorkTitle: String?

    private var title: String {
        nominee.creditedName == nil ? englishWorkTitle ?? nominee.title : nominee.title
    }

    private var subtitle: String? {
        nominee.creditedName == nil ? nominee.subtitle : englishWorkTitle ?? nominee.subtitle
    }

    var body: some View {
        Group {
            if nominee.work != nil || nominee.character?.peopleId != nil {
                NavigationLink(value: SearchBrowseRoute.awardNominee(nominee)) { row }.buttonStyle(.springPress)
            } else {
                row
            }
        }.accessibilityIdentifier("search-award-nominee-\(nominee.id)")
        .task(id: locale.identifier) {
            guard locale.language.languageCode?.identifier == "en" else { englishWorkTitle = nil; return }
            guard englishWorkTitle == nil, nominee.hasKoreanWorkTitle, let work = nominee.work,
                  !store.isPreview, let key = TVDBDirect.key(store) else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let entry = TVDBDirect.ListEntry(providerID: work.id, kind: work.kind)
                let name = try await TVDBDirect.englishAwardTitle(entry, key: key)
                try Task.checkCancellation()
                englishWorkTitle = name
            } catch { /* The original title is available throughout. */ }
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            Artwork(path: nominee.image, title: title)
                .frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HomeStyle.primary)
                if let detail = subtitle {
                    Text(detail).font(.subheadline).foregroundStyle(HomeStyle.secondary)
                }
                if let note = nominee.note, note != subtitle {
                    Text(note).font(.caption).foregroundStyle(HomeStyle.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if nominee.isWinner == true {
                Image(systemName: "trophy.fill").foregroundStyle(Color(themed: "#e7ca90"))
                    .accessibilityLabel("Winner")
            }
        }.padding(10).frame(minHeight: 44).contentShape(Rectangle())
    }
}

struct SearchAwardNomineePage: View {
    let nominee: SearchAwardNominee
    @Environment(DiaryStore.self) private var store
    @State private var titleRoute: CatalogRoute?
    @State private var savedID: String?
    @State private var personID: Int?
    @State private var loading = true
    @State private var failure: String?

    private var entry: TVDBDirect.ListEntry? {
        nominee.work.map { TVDBDirect.ListEntry(providerID: $0.id, kind: $0.kind) }
    }

    var body: some View {
        Group {
            if let savedID { TitleDetailView(id: savedID) }
            else if let titleRoute { CatalogDetailView(route: titleRoute) }
            else if let personID { PersonView(route: PersonRoute(id: personID)) }
            else { resolving }
        }.task { if loading { await load() } }
    }

    private var resolving: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    DiaryLoadingPlaceholder(label: "Opening \(nominee.title)")
                } else {
                    if let note = nominee.note { Text(note).foregroundStyle(HomeStyle.secondary) }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    if let entry { Link("View title on TheTVDB", destination: entry.webLink) }
                    if let id = nominee.character?.peopleId, id > 0,
                       let url = URL(string: "https://www.thetvdb.com/dereferrer/people/\(id)") {
                        Link("View person on TheTVDB", destination: url)
                    }
                }
            }.padding(14)
        }.diaryScreenBackground().navigationTitle(nominee.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        #if DEBUG
        if store.isPreview, entry?.providerID == 75299 {
            titleRoute = CatalogRoute(kind: .tv, id: 900002)
            return
        }
        #endif
        guard !store.isPreview, let key = TVDBDirect.key(store) else { return }
        if let work = entry {
            do {
                let matched = try await TVDBDirect.title(work, key: key)
                try Task.checkCancellation()
                var tmdbID = matched.tmdbID
                if tmdbID == nil, let imdb = matched.imdbID, let token = TMDBDirect.token(store) {
                    let page = try await TMDBDirect.search(imdb, page: 1, token: token)
                    try Task.checkCancellation()
                    let items = page.items.filter { $0.mediaType == work.kind }
                    if items.count == 1 { tmdbID = items.first?.id }
                }
                if let id = tmdbID {
                    savedID = store.libraryIdentity(CatalogItem(id: id, mediaType: work.kind, name: matched.name))
                    titleRoute = CatalogRoute(kind: work.kind, id: id)
                    return
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        if let id = nominee.character?.peopleId, id > 0, !Task.isCancelled {
            do {
                let matched = try await TVDBDirect.awardPersonTMDB(id, key: key)
                try Task.checkCancellation()
                personID = matched
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
