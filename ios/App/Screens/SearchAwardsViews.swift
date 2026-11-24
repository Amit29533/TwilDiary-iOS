import Observation
import SwiftUI
import TwilDiaryCore

struct SearchAwardsShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .awards)
            // One row of posters, as the other shelves.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Gap.item) {
                    ForEach(SearchAwardCeremony.featured.filter { !SearchAwardCeremony.withoutRecords.contains($0.id) }) { ceremony in
                        // The genre tiles' size, so the rows on Search line up.
                        AwardCeremonyLink(ceremony: ceremony).containerRelativeFrame(.horizontal) { width, _ in min(210, width * 0.44) }
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
}

struct SearchAwardsPage: View {
    @Environment(DiaryStore.self) private var store
    @State private var ceremonies = SearchAwardCeremony.featured
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        ExploreBrowsePage(title: "Awards", symbol: "trophy") {
            VStack(alignment: .leading, spacing: 14) {
                // A ceremony with no winners or nominees recorded isn't listed.
                SearchAwardGrid {
                    ForEach(ceremonies.filter { !SearchAwardCeremony.withoutRecords.contains($0.id) }) { AwardCeremonyLink(ceremony: $0) }
                }
                if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else if !loaded {
                    DiaryLoadingPlaceholder(label: "Loading award ceremonies", layout: .list(rows: 5))
                }
                AwardsAttribution()
            }.padding(14).padding(.bottom, 32)
        }
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
            if !Task.isCancelled { failure = FriendlyError.message(error) }
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
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 100

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.ceremony(ceremony)) {
            if let art = AwardLogoArt(ceremony: ceremony) {
                // The ceremony's own logo on its own background colour: the Search page's small rectangle.
                art.frame(height: height).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                    // A hairline edge, so dark logos (the Oscars) don't melt into a black page.
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .accessibilityElement().accessibilityLabel(ceremony.displayName)
            } else {
                SearchBrowseArtworkTile(title: ceremony.displayName, symbol: ceremony.symbol, tint: "#8a6a2a", artwork: nil)
            }
        }.buttonStyle(.springPress).accessibilityIdentifier("search-award-ceremony-\(ceremony.id)")
    }

    /// The bundled logos, read once.
    private static var images: [String: UIImage] = [:]
    static func image(_ file: String) -> UIImage? {
        if let kept = images[file] { return kept }
        let parts = file.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let path = Bundle.main.path(forResource: parts[0], ofType: parts[1]), let image = UIImage(contentsOfFile: path) else { return nil }
        images[file] = image
        return image
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

    func load(_ ceremony: SearchAwardCeremony, store: DiaryStore, tmdbFile: String?, refresh: Bool = false) async {
        guard !loading else { return }
        loading = true
        failure = nil
        progress = nil
        defer { loading = false }
        #if DEBUG
        if store.isPreview { archive = SearchAwardArchive.preview; return }
        #endif
        if let tmdbFile {
            // Negative keys keep these archives separate from TheTVDB’s positive ceremony IDs.
            let cacheKey = -ceremony.id
            if let cached = await SearchAwardCache.shared.read(cacheKey) {
                archive = cached
                if !refresh && Date.now.timeIntervalSince(cached.updatedAt) < 21_600 { return }
            }
            do {
                let available = try await TMDBAwardArchive.load(file: tmdbFile, refresh: refresh)
                try Task.checkCancellation()
                archive = available
                await SearchAwardCache.shared.save(available, ceremony: cacheKey)
            } catch {
                if !Task.isCancelled { failure = FriendlyError.message(error) }
            }
            return
        }
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
            if !Task.isCancelled { failure = FriendlyError.message(error) }
        }
    }

    var progressLabel: String {
        if let progress, progress.total > 0 { return "Loading awards · \(progress.finished) of \(progress.total) categories" }
        return "Loading awards"
    }
}

struct SearchAwardCeremonyPage: View {
    let ceremony: SearchAwardCeremony
    @Environment(DiaryStore.self) private var store
    @State private var useTMDB: Bool?

    var body: some View {
        let canUseTMDB = ceremony.tmdbArchiveFile != nil && TMDBDirect.token(store) != nil && !store.isPreview
        let selected = canUseTMDB && (useTMDB ?? true)
        // TMDB's awards archive where there is one, TheTVDB's when it can't be read.
        AwardEditionPage(ceremony: ceremony, tmdbFile: selected ? ceremony.tmdbArchiveFile : nil,
                         fallback: selected && useTMDB == nil && TVDBDirect.key(store) != nil ? { useTMDB = false } : nil)
            .id(selected)
    }
}

private struct AwardEditionPage: View {
    let ceremony: SearchAwardCeremony
    let tmdbFile: String?
    let fallback: (() -> Void)?

    init(ceremony: SearchAwardCeremony, tmdbFile: String?, fallback: (() -> Void)?) {
        self.ceremony = ceremony
        self.tmdbFile = tmdbFile
        self.fallback = fallback
    }

    private struct Subcategory: Identifiable {
        let name: String?
        let nominees: [SearchAwardNominee]
        var id: String { name ?? "" }
    }

    @Environment(DiaryStore.self) private var store
    @State private var loader = AwardArchiveLoader()
    @State private var selectedEdition: SearchAwardEditionIndex.Edition?
    @State private var medium: MediaKind?
    @State private var awardType: SearchAwardCategory.AwardType?
    @State private var categoryID: Int?
    @State private var winnersOnly = false

    private var edition: SearchAwardEditionIndex.Edition? {
        guard let editions = loader.editions?.editions else { return nil }
        if let selectedEdition, editions.contains(selectedEdition) { return selectedEdition }
        return editions.first
    }

    var body: some View {
        ExploreBrowsePage(title: ceremony.displayName, symbol: ceremony.symbol, subtitle: "Awards ceremony",
                          banner: AwardLogoArt(ceremony: ceremony, large: true).map { AnyView($0) }) {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let editions = loader.editions {
                    if let edition, let groups = editions.sections[edition] {
                        awardResults(groups, edition: edition, editions: editions.editions)
                    } else if let archive = loader.archive, archive.incompleteCount == 0,
                              !loader.loading, loader.failure == nil {
                        // No records at all: nothing to list (and the ceremony leaves the Awards lists).
                        ContentUnavailableView("No records", systemImage: "trophy", description: Text("No winners or nominees are recorded for this ceremony."))
                    }
                }
                if let failure = loader.failure {
                    RetryNotice(message: failure) { Task { await loader.load(ceremony, store: store, tmdbFile: tmdbFile) } }
                } else if loader.loading || loader.archive == nil {
                    DiaryLoadingPlaceholder(label: loader.progressLabel)
                } else if let archive = loader.archive, archive.incompleteCount > 0 {
                    RetryNotice(message: "TheTVDB couldn’t refresh \(archive.incompleteCount) categories.") {
                        Task { await loader.load(ceremony, store: store, tmdbFile: tmdbFile) }
                    }
                }
                if tmdbFile != nil {
                    Link("Source: TMDB Awards Database", destination: TMDBAwardArchive.repository).font(.footnote)
                } else { AwardsAttribution() }
            }.padding(14).padding(.bottom, 32)
        }
            .task { if loader.archive == nil { await loader.load(ceremony, store: store, tmdbFile: tmdbFile) } }
            .onChange(of: loader.loading) { _, loading in
                // Fully read: remember whether it has any records, for the Awards lists.
                guard !loading, loader.failure == nil, let archive = loader.archive, archive.incompleteCount == 0 else { return }
                SearchAwardCeremony.noteRecords(ceremony.id, found: !(loader.editions?.sections.isEmpty ?? true))
            }
            .onChange(of: loader.failure) { _, error in
                if error != nil && loader.archive == nil { fallback?() }
            }
            .refreshable { await loader.load(ceremony, store: store, tmdbFile: tmdbFile, refresh: true) }
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
                Text("All").tag(nil as MediaKind?)
                Text("Movies").tag(Optional(MediaKind.movie))
                Text("Shows").tag(Optional(MediaKind.tv))
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
                    AwardRecipientGroup(nominees: group.nominees, filmYear: filmYear(section.category, edition))
                        .id(edition)
                }
            }
        }
    }

    /// The release year of the films a film award's edition honours (the year before it).
    private func filmYear(_ category: SearchAwardCategory, _ edition: SearchAwardEditionIndex.Edition) -> Int? {
        guard case .year(let year) = edition else { return nil }
        return ceremony.id == 1 || ceremony.id == 11 || category.media == [.movie] ? year - 1 : nil
    }

    private var mediumSelection: Binding<MediaKind?> {
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
        HStack {
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
                }.pickerStyle(.menu).accessibilityIdentifier("search-award-type-filter")
                Picker("Category", selection: Binding(get: { selectedCategory?.id }, set: { categoryID = $0 })) {
                    Text("All").tag(nil as Int?)
                    ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("search-award-category-filter")
                Toggle("Winners only", isOn: $winnersOnly).accessibilityIdentifier("search-award-winners-filter")
            } label: {
                let count = [type != nil, selectedCategory != nil, winnersOnly].filter { $0 }.count
                AwardFilterPill(label: count == 0 ? "Filters" : "Filters (\(count))",
                                icon: "line.3.horizontal.decrease", active: count > 0)
            }.accessibilityIdentifier("search-award-filters")
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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(label).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.bold()).accessibilityHidden(true)
        }.font(.caption.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .foregroundStyle(active ? HomeStyle.chipText : HomeStyle.primary)
            .background(active ? HomeStyle.chip : HomeStyle.card, in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
    }
}

private struct AwardRecipientGroup: View {
    let nominees: [SearchAwardNominee]
    var filmYear: Int? = nil

    var body: some View {
        // The winner first, then the nominees: one row of standard posters.
        let ordered = nominees.filter { $0.isWinner == true } + nominees.filter { $0.isWinner != true }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(ordered) { AwardNomineeRow(nominee: $0, filmYear: filmYear).id($0).containerRelativeFrame(.horizontal, count: 3, spacing: 12) }
            }
        }.scrollIndicators(.hidden).scrollClipDisabled()
    }
}

private struct AwardNomineeRow: View {
    let nominee: SearchAwardNominee
    var filmYear: Int? = nil
    @Environment(DiaryStore.self) private var store
    @Environment(\.locale) private var locale
    @State private var englishWorkTitle: String?

    @State private var tmdbLabel: TMDBAwardLabels.LabelData?
    @State private var labelFailed = false

    private var title: String {
        if let subject = nominee.tmdb {
            return tmdbLabel?.title ?? tmdbLabel?.name ?? (labelFailed ? "Open \(subject.kind.rawValue) details" : "Loading name…")
        }
        return nominee.creditedName == nil ? englishWorkTitle ?? nominee.title : nominee.title
    }

    private var subtitle: String? {
        if nominee.tmdb?.kind == .person {
            return filmYear.flatMap { tmdbLabel?.onlyFilm(released: $0) }.map { "for " + $0 }
        }
        return nominee.creditedName == nil ? nominee.subtitle : englishWorkTitle ?? nominee.subtitle
    }

    var body: some View {
        Group {
            if let subject = nominee.tmdb {
                if subject.kind == .person {
                    NavigationLink(value: PersonRoute(id: subject.id)) { row }.buttonStyle(.springPress)
                } else {
                    let route = CatalogRoute(kind: subject.kind == .movie ? .movie : .tv, id: subject.id)
                    if let saved = store.libraryIdentity(CatalogItem(id: route.id, mediaType: route.kind, name: title)) {
                        NavigationLink(value: saved) { row }.buttonStyle(.springPress)
                    } else {
                        NavigationLink(value: route) { row }.buttonStyle(.springPress)
                    }
                }
            } else if nominee.work != nil || nominee.character?.peopleId != nil {
                NavigationLink(value: SearchBrowseRoute.awardNominee(nominee)) { row }.buttonStyle(.springPress)
            } else {
                row
            }
        }.accessibilityIdentifier("search-award-nominee-\(nominee.id)")
        .preference(key: BrowseCoverPreference.self, value: CatalogTools.image(tmdbLabel?.poster_path, size: "w780") ?? nominee.image)
        .task(id: locale.identifier) {
            if let subject = nominee.tmdb, let token = TMDBDirect.token(store) {
                do {
                    tmdbLabel = try await TMDBAwardLabels.resolve(subject, token: token,
                        language: locale.identifier.replacingOccurrences(of: "_", with: "-"))
                    labelFailed = false
                } catch { if !Task.isCancelled { labelFailed = true } }
                return
            }
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

    /// The standard poster: the picture (a trophy on the winner's), the name, and the film or
    /// "Winner" / "Nominee" under it.
    private var row: some View {
        let winner = nominee.isWinner == true
        return VStack(alignment: .leading, spacing: 0) {
            Artwork(path: CatalogTools.image(tmdbLabel?.profile_path ?? tmdbLabel?.poster_path, size: "w342") ?? nominee.image, title: title, initialsOnly: false)
                .posterAspect()
                .overlay(alignment: .topLeading) {
                    if winner {
                        Image(systemName: "trophy.fill").font(.app(size: 12, weight: .bold)).foregroundStyle(Color(themed: "#e7ca90"))
                            .frame(width: 26, height: 26).background(.black.opacity(0.75), in: Circle()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(.app(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).frame(minHeight: 20.25).padding(.top, 8)
            Text(subtitle ?? nominee.note ?? (winner ? "Winner" : "Nominee"))
                .font(.app(size: 12, weight: winner ? .semibold : .regular)).foregroundStyle(winner ? Color(themed: "#e7ca90") : .secondary)
                .lineLimit(1).frame(height: 18).padding(.top, 4)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine).accessibilityLabel(title + (winner ? ", winner" : ", nominee"))
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
        if let id = nominee.character?.peopleId, id > 0, !Task.isCancelled {
            do {
                let matched = try await TVDBDirect.awardPersonTMDB(id, key: key)
                try Task.checkCancellation()
                if let matched { personID = matched; return }
            } catch {
                if !Task.isCancelled { failure = FriendlyError.message(error) }
            }
        }
        guard !Task.isCancelled else { return }
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
                if !Task.isCancelled { failure = FriendlyError.message(error) }
            }
        }

    }
}

/// A ceremony's logo on its own background colour (or, for a caption, a trophy beside the name
/// in gold): the Search tile, and the top of the ceremony's page (`large`).
struct AwardLogoArt: View {
    let file: UIImage
    let background: String
    let caption: String?
    let large: Bool

    init?(ceremony: SearchAwardCeremony, large: Bool = false) {
        guard let logo = ceremony.logo, let image = AwardCeremonyLink.image(logo.file) else { return nil }
        file = image; background = logo.background; caption = logo.caption; self.large = large
    }

    var body: some View {
        ZStack {
            Color(webHex: background)
            if let caption {
                LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: large ? 18 : 10) {
                    Image(uiImage: file).resizable().scaledToFit().padding(.vertical, large ? 28 : 10)
                    Text(caption).font(.app(size: large ? 24 : 13, weight: .semibold, design: .serif)).tracking(large ? 2 : 1.2)
                        .foregroundStyle(LinearGradient(colors: [Color(webHex: "#f3d9a0"), Color(webHex: "#c79a4a")], startPoint: .top, endPoint: .bottom))
                        // Each word on its own line, never split: smaller type before a word breaks.
                        .lineSpacing(1).lineLimit(caption.split(separator: "\n").count)
                        .minimumScaleFactor(0.4).allowsTightening(true).layoutPriority(1)
                }.padding(.horizontal, large ? 28 : 12)
            } else {
                // On the page's top: the logo whole, a little in from the edges and clear of the back button.
                Image(uiImage: file).resizable().scaledToFit().padding(.top, large ? 44 : 0).padding(.horizontal, large ? 12 : 0)
            }
        }
    }
}
