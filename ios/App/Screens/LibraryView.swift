import SwiftUI
import TwilDiaryCore

/// Library (approved design): header with Select and Search, category pills, status chips
/// with live counts, a sort row with the filter sheet and a Grid → List → Shelves toggle,
/// then posters, rows or genre shelves. Select mode swaps the header for Cancel · N selected · All
/// and shows a glass action bar.
struct LibraryView: View {
    enum Layout: String { case grid, list, shelves }
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(AppRouter.self) private var router
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @SceneStorage("library.category") private var categoryRaw = LibraryCategory.all.rawValue
    @SceneStorage("library.status") private var status = "all"
    @SceneStorage("library.genres") private var genresRaw = ""
    @SceneStorage("library.drive") private var drive = ""
    @SceneStorage("library.favorites") private var favoritesOnly = false
    @State private var showSearch = false
    @State private var showAdd = false
    @State private var showFilters = false
    @State private var addedTitle: String?
    @State private var addedCatalog: CatalogRoute?
    @AppStorage("library.list") private var list = false
    @AppStorage("library.genreRows") private var genreRows = false
    @AppStorage("library.sort") private var sort = LibraryQuery.Sort.added
    @State private var initializedStorage = false
    private var category: LibraryCategory {
        get { LibraryCategory(rawValue: categoryRaw) ?? .all }
        nonmutating set { categoryRaw = newValue.rawValue }
    }
    private var genres: Set<String> {
        get { Set(genresRaw.split(separator: "\n").map(String.init)) }
        nonmutating set { genresRaw = newValue.sorted().joined(separator: "\n") }
    }
    private var layout: Layout { genreRows ? .shelves : list ? .list : .grid }
    @State private var appliedShortcutRevision = 0
    @State private var visibleLimit = 48
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var review: CollectionReview?
    var body: some View {
        VStack(spacing: 0) {
            if selecting { selectionHeader }
            else { PageHeader(name: "Library", count: "\(collection.count) \(collection.count == 1 ? "title" : "titles")", onSearch: { showSearch.toggle() }, onSelect: { selecting = true; selected = [] }, height: 54) }
            if showSearch && !selecting {
                ScrollView { CatalogSearchView(onClose: { showSearch = false }).padding(.top, 2) }
            } else {
                CategoryPicker(selection: Binding(get: { category }, set: { category = $0 }))
                collectionContent
            }
        }.background(theme == .glass ? .clear : Color(webHex: "#0e0d13")).diaryScreenBackground()
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar.padding(.horizontal, 16).padding(.bottom, 8) } }
            .task(id: collection.map(\.id).sorted().joined(separator: ",") + ratingSource.rawValue) { await store.loadPublicRatings(collection, source: ratingSource) }
            .onChange(of: router.libraryRevision) { _, _ in applyShortcut() }
            .onAppear { initializeStorage(); applyShortcut() }
            .onChange(of: filterScope) { _, _ in selected.formIntersection(filtered.map(\.id)); visibleLimit = 48 }
            .onChange(of: filtered.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .sheet(isPresented: $showFilters) { filterSheet.presentationDetents([.large]).presentationDragIndicator(.visible) }
            .sheet(isPresented: $showAdd, onDismiss: {
                if let id = addedTitle { addedTitle = nil; router.openTitle(id, tab: .library) }
                else if let route = addedCatalog { addedCatalog = nil; router.paths[.library, default: NavigationPath()].append(route) }
            }) {
                NavigationStack {
                    ScrollView {
                        CatalogSearchView(onLibraryChoose: { id in addedTitle = id; showAdd = false },
                            onCatalogChoose: { route in addedCatalog = route; showAdd = false },
                            onClose: { showAdd = false }).padding(.top, 14)
                    }.navigationTitle("Add title").navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(item: $review) { value in CollectionReviewView(review: value) { selecting = false; selected = [] } }
    }

    // MARK: Header, chips and sort row

    private var selectionHeader: some View {
        HStack {
            Button("Cancel") { selecting = false; selected = [] }.accessibilityIdentifier("selection-cancel")
            Spacer(minLength: 8)
            Text("\(selected.count) selected").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7")).accessibilityIdentifier("selection-count")
            Spacer(minLength: 8)
            Button("All") { selected = Set(filtered.prefix(CollectionRequest.limit).map(\.id)) }.accessibilityLabel("Select all shown").accessibilityIdentifier("selection-all")
        }.font(.system(size: 16, weight: .semibold)).tint(theme.accent).padding(.horizontal, 18).frame(height: 54)
    }
    private static let statuses = [("all", "All"), ("watching", "Watching"), ("planned", "Planned"), ("completed", "Completed"), ("dropped", "Dropped"), ("queue", "Queue")]
    private var statusChips: some View {
        let counts = statusCounts
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.statuses, id: \.0) { key, name in
                    let on = status == key
                    Button { status = key } label: {
                        HStack(spacing: 5) {
                            Text(name).foregroundStyle(on ? theme.accent : Color(webHex: "#c5c0cf"))
                            Text("\(counts[key] ?? 0)").fontWeight(.semibold).foregroundStyle(on ? theme.accent : Color(webHex: "#f3f0f7"))
                        }.font(.system(size: 14)).padding(.horizontal, 12).frame(height: 34)
                            .background(on ? theme.accent.opacity(0.12) : .clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.7) : .white.opacity(0.14)))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(name).accessibilityValue("\(counts[key] ?? 0) titles")
                        .accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("library-status-" + key)
                }
            }.padding(.horizontal, 14)
        }.scrollIndicators(.hidden).padding(.vertical, 6)
    }
    private var sortRow: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Order", selection: $sort) {
                    Text("Recently added").tag(LibraryQuery.Sort.added); Text("Library order").tag(LibraryQuery.Sort.library)
                    Text("Title A–Z").tag(LibraryQuery.Sort.title); Text("Newest year").tag(LibraryQuery.Sort.year)
                    Text("Highest " + ratingSource.label + " rating").tag(LibraryQuery.Sort.score)
                }
            } label: {
                HStack(spacing: 6) { Text(sortLabel).lineLimit(1); DiaryIcon(name: "chevron-down", size: 13) }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color(webHex: "#c5c0cf")).frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("Sort").accessibilityValue(sortLabel).accessibilityIdentifier("library-order")
            Spacer(minLength: 0)
            Button { showFilters = true } label: {
                roundTool("sliders-horizontal").overlay(alignment: .topTrailing) {
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.ink)
                            .frame(minWidth: 18, minHeight: 18).background(theme.accent, in: Circle()).offset(x: 3, y: -3)
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel("Filters").accessibilityValue(activeFilterCount == 0 ? "None" : "\(activeFilterCount) active").accessibilityIdentifier("library-filters")
            if !selecting {
                Button { cycleLayout() } label: { roundTool(layout == .grid ? "layout-grid" : layout == .list ? "list" : "rows-3") }
                    .buttonStyle(.plain).accessibilityLabel(nextLayoutLabel).accessibilityValue(layout.rawValue.capitalized).accessibilityIdentifier("library-layout")
            }
        }.padding(.leading, 18).padding(.trailing, 14).padding(.bottom, 6)
    }
    private func roundTool(_ icon: String) -> some View {
        DiaryIcon(name: icon, size: 19).foregroundStyle(Color(webHex: "#c5c0cf")).frame(width: 44, height: 44)
            .background(.white.opacity(0.08), in: Circle()).contentShape(Circle())
    }
    /// The toggle names what it switches to: Grid → List → Shelves → Grid.
    private var nextLayoutLabel: String { switch layout { case .grid: "List layout"; case .list: "Genre sections"; case .shelves: "Grid layout" } }
    private func cycleLayout() {
        switch layout { case .grid: list = true; genreRows = false; case .list: list = false; genreRows = true; case .shelves: list = false; genreRows = false }
    }
    private var sortLabel: String {
        switch sort { case .added: "Recently added"; case .title: "Title A–Z"; case .year: "Newest year"; case .score: "Highest " + ratingSource.label + " rating"; case .library: "Library order" }
    }

    // MARK: Content

    private var collectionContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                statusChips
                sortRow
                if ratingSource == .trakt {
                    if store.communityRatings.loading { ratingStatus("Loading Trakt community ratings…") }
                    else if store.communityRatings.unavailable {
                        HStack(alignment: .top, spacing: 8) {
                            Text("Some Trakt ratings are unavailable.").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Retry") { Task { await store.loadPublicRatings(collection, source: ratingSource, retry: true) } }.font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("ratings-retry")
                        }.padding(.horizontal, 14).padding(.bottom, 10)
                    }
                }
                if !store.hasLoadedWorkspace && collection.isEmpty { skeleton }
                else if collection.isEmpty { DiaryEmptyState(title: "Nothing here just yet", description: "Add a movie or show to start your library.").padding(.horizontal, 14).padding(.top, 20) }
                else if filtered.isEmpty { noMatches }
                else {
                    switch selecting ? (layout == .shelves ? .grid : layout) : layout {
                    case .shelves:
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(LibraryShelf.make(filtered)) { shelf in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Text(shelf.genre).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                                        Text("\(shelf.titles.count)").font(.system(size: 14)).foregroundStyle(.secondary)
                                        Spacer()
                                        if shelf.genre != "Without a genre" {
                                            Button("See all") { genres = [shelf.genre]; genreRows = false; list = false }
                                                .font(.system(size: 14, weight: .semibold)).tint(theme.accent).accessibilityLabel("See all \(shelf.genre) titles")
                                        }
                                    }
                                    ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 10) { ForEach(shelf.titles) { title in poster(title).frame(width: 112) } } }
                                        .scrollIndicators(.hidden).scrollClipDisabled()
                                }
                            }
                        }.padding(.horizontal, 14)
                    case .list:
                        LazyVStack(spacing: 8) { ForEach(shown) { title in poster(title, row: true).onAppear { revealMore(after: title) } } }.padding(.horizontal, 14)
                    case .grid:
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                            ForEach(shown) { title in poster(title).onAppear { revealMore(after: title) } }
                        }.padding(.horizontal, 14)
                    }
                }
            }.padding(.bottom, selecting ? 90 : 24)
        }.refreshable { await store.refresh(); await store.loadPublicRatings(collection, source: ratingSource) }
    }
    private func ratingStatus(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
    }
    /// Names the filters that hide everything and clears them in one tap.
    private var noMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 30)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("No titles match").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
            Text(activeFilterNames.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Clear filters") { clearFilters() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink)
                .padding(.horizontal, 18).frame(height: 40).background(theme.accent, in: Capsule()).buttonStyle(.plain).padding(.top, 6)
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
    private var skeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 16) {
            ForEach(0..<9, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).aspectRatio(2 / 3, contentMode: .fit)
                    Capsule().fill(.white.opacity(0.06)).frame(height: 8)
                }
            }
        }.padding(.horizontal, 14).accessibilityLabel("Loading your library")
    }
    @ViewBuilder private func poster(_ title: MediaTitle, row: Bool = false) -> some View {
        if selecting {
            let on = selected.contains(title.id)
            Button { if on { selected.remove(title.id) } else if selected.count < CollectionRequest.limit { selected.insert(title.id) } } label: {
                Group {
                    if row { LibraryListRow(title: title, selected: on) }
                    else { LibraryPosterCard(title: title, selecting: true).overlay(alignment: .topTrailing) { checkCircle(on).padding(6) } }
                }
            }.buttonStyle(.plain).disabled(store.busy || (!on && selected.count >= CollectionRequest.limit))
                .accessibilityIdentifier("select-title-" + title.id).accessibilityAddTraits(on ? .isSelected : [])
        } else {
            NavigationLink(value: title.id) { if row { LibraryListRow(title: title) } else { LibraryPosterCard(title: title) } }
                .buttonStyle(.plain).contentShape(Rectangle()).accessibilityIdentifier("title-" + title.id)
                .contextMenu {
                    Button("Select", systemImage: "checkmark.circle") { selecting = true; selected = [title.id] }
                    Button(title.favorite ? "Remove favorite" : "Favorite", systemImage: title.favorite ? "heart.slash" : "heart") { review = CollectionReview(titles: [title], change: .favorite(!title.favorite)) }
                    Button(title.queued == true ? "Remove from Queue" : "Add to Queue", systemImage: "text.badge.plus") { review = CollectionReview(titles: [title], change: .queue(title.queued != true)) }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) { review = CollectionReview(titles: [title], change: .trash) }
                }
        }
    }
    private func checkCircle(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
            .foregroundStyle(on ? theme.accent : .white).shadow(color: .black.opacity(0.7), radius: 3)
    }

    // MARK: Select mode

    /// Favorite · Queue · Status · Trash; each opens the existing review and confirmation.
    private var selectionBar: some View {
        let chosen = filtered.filter { selected.contains($0.id) }
        return GlassEffectContainer {
            HStack(spacing: 0) {
                barButton("Favorite", icon: "heart", identifier: "selection-favorite") { prepareReview(.favorite(!chosen.allSatisfy(\.favorite))) }
                barButton("Queue", icon: "download", identifier: "selection-queue") { prepareReview(.queue(!chosen.allSatisfy { $0.queued == true })) }
                Menu {
                    ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { value in Button(value.capitalized) { prepareReview(.status(value)) } }
                } label: { barLabel("Status", icon: "circle-check", color: theme.accent) }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("selection-status")
                barButton("Trash", icon: "trash-2", identifier: "selection-trash", color: Color(webHex: "#ff8a8a")) { prepareReview(.trash) }
            }.padding(.vertical, 6).glassEffect(.regular, in: Capsule())
        }.disabled(selected.isEmpty || store.busy)
    }
    private func barButton(_ name: String, icon: String, identifier: String, color: Color = Color(webHex: "#c5c0cf"), action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(name, icon: icon, color: color) }.buttonStyle(.plain).frame(maxWidth: .infinity).accessibilityIdentifier(identifier)
    }
    private func barLabel(_ name: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) { DiaryIcon(name: icon, size: 20); Text(name).font(.system(size: 11, weight: .medium)) }
            .foregroundStyle(color).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
    }
    private func prepareReview(_ change: CollectionChange) { let titles = filtered.filter { selected.contains($0.id) }; if !titles.isEmpty { review = CollectionReview(titles: titles, change: change) } }

    // MARK: Filter sheet

    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sheetLabel("Genre")
                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(genreCounts, id: \.0) { name, count in
                            let on = genres.contains(name)
                            sheetChip("\(name) \(count)", on: on) { var value = genres; if on { value.remove(name) } else { value.insert(name) }; genres = value }
                                .accessibilityLabel(name).accessibilityValue("\(count) titles").accessibilityIdentifier("filter-genre-" + name)
                        }
                    }
                    sheetLabel("Availability")
                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        sheetChip("Any", on: drive.isEmpty) { drive = "" }.accessibilityIdentifier("filter-disk-any")
                        sheetChip("On disk", on: drive == "mapped") { drive = "mapped" }.accessibilityIdentifier("filter-disk-mapped")
                        sheetChip("Not on disk", on: drive == "unmapped") { drive = "unmapped" }.accessibilityIdentifier("filter-disk-unmapped")
                        ForEach(HomeDiskShortcut.all) { disk in sheetChip(disk.label, on: drive == disk.key) { drive = disk.key } }
                        ForEach(extraDisks) { disk in sheetChip(disk.deviceName + " · " + disk.letters.joined(separator: " / "), on: drive == disk.key) { drive = disk.key } }
                    }
                    sheetLabel("Public rating from")
                    Picker("Public rating from", selection: $ratingSource) { ForEach(PublicRatingSource.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).accessibilityIdentifier("filter-rating-source")
                    sheetLabel("Show")
                    Toggle("Favorites only", isOn: $favoritesOnly).tint(theme.accent).accessibilityIdentifier("filter-favorites")
                    Button { showFilters = false } label: {
                        Text("Show \(filtered.count) \(filtered.count == 1 ? "title" : "titles")").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 50).background(theme.accent, in: Capsule())
                    }.buttonStyle(.plain).padding(.top, 22).accessibilityIdentifier("filter-show")
                    Button { showFilters = false; openTrash() } label: {
                        HStack(spacing: 6) { DiaryIcon(name: "trash-2", size: 15); Text("Trash · \(trashCount) \(trashCount == 1 ? "title" : "titles")") }
                            .font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Open Trash").padding(.top, 6)
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }.navigationTitle("Filters").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Clear all") { genres = []; drive = ""; favoritesOnly = false }.tint(theme.accent).disabled(activeFilterCount == 0) } }
        }
    }
    private func sheetLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.top, 18).padding(.bottom, 8)
    }
    private func sheetChip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14)).foregroundStyle(on ? theme.accent : Color(webHex: "#c5c0cf"))
                .padding(.horizontal, 12).frame(height: 34)
                .background(on ? theme.accent.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.7) : .white.opacity(0.16)))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    /// The sheet sits outside the navigation stack, so Trash is pushed onto Library's path.
    private func openTrash() { router.paths[.library, default: NavigationPath()].append(AppDestination.trash) }

    // MARK: Data

    private func applyShortcut() {
        guard router.libraryRevision > appliedShortcutRevision else { return }
        appliedShortcutRevision = router.libraryRevision
        category = .all; genres = router.libraryGenreShortcut.isEmpty ? [] : [router.libraryGenreShortcut]; drive = router.libraryDiskShortcut; status = "all"; favoritesOnly = false
        switch router.libraryShortcut { case "queue": status = "queue"; case "planned", "watching", "completed", "dropped": status = router.libraryShortcut ?? "all"; case "disk": drive = HomeDiskShortcut.all.first?.key ?? ""; case "add": showAdd = true; default: break }
    }
    private var filterScope: String { [category.rawValue, status, genresRaw, drive, String(favoritesOnly), sort.rawValue].joined(separator: "\n") }
    private var collection: [MediaTitle] { store.workspace.activeTitles }
    private var trashCount: Int { store.workspace.titles.count { $0.deletedAt != nil } }
    private var activeFilterCount: Int { genres.count + (drive.isEmpty ? 0 : 1) + (favoritesOnly ? 1 : 0) }
    private var activeFilterNames: [String] {
        var names: [String] = []
        if category != .all { names.append(category.rawValue) }
        if status != "all" { names.append(status.capitalized) }
        names += genres.sorted()
        if !drive.isEmpty { names.append(driveLabel) }
        if favoritesOnly { names.append("Favorites") }
        return names
    }
    private func clearFilters() { category = .all; status = "all"; genres = []; drive = ""; favoritesOnly = false }
    /// Genres in the current category and status, most common first.
    private var genreCounts: [(String, Int)] {
        LibraryShelf.make(query(status: status, genres: [], drive: "", favorites: false)).filter { $0.genre != "Without a genre" }.map { ($0.genre, $0.titles.count) }
    }
    /// Each status chip counts the titles every other filter leaves.
    private var statusCounts: [String: Int] {
        let base = query(status: "all", genres: genres, drive: drive, favorites: favoritesOnly)
        var counts = Dictionary(grouping: base, by: \.status).mapValues(\.count)
        counts["all"] = base.count; counts["queue"] = base.count { $0.queued == true }
        return counts
    }
    private var disks: [DiskSummary] { let ids = Set(collection.map(\.id)); return DiskSummary.make(store.workspace.locations.filter { ids.contains($0.titleId) }) }
    private var extraDisks: [DiskSummary] { disks.filter { disk in disk.letters.allSatisfy { letter in !HomeDiskShortcut.all.contains { $0.key == "drive:" + letter.uppercased() } } } }
    private var driveLabel: String { if drive.isEmpty { return "Any disk" }; if drive == "mapped" { return "On disk" }; if drive == "unmapped" { return "Not on disk" }; if let shortcut = HomeDiskShortcut.all.first(where: { $0.key == drive }) { return shortcut.label }; return disks.first { $0.key == drive }?.letters.joined(separator: " / ") ?? "Selected disk" }
    private var shown: [MediaTitle] { Array(filtered.prefix(visibleLimit)) }
    /// The last created cell of the lazy grid or list asks for the next 48.
    private func revealMore(after title: MediaTitle) {
        let titles = filtered
        guard visibleLimit < titles.count, title.id == titles[visibleLimit - 1].id else { return }
        visibleLimit += 48
    }
    private var filtered: [MediaTitle] { query(status: status, genres: genres, drive: drive, favorites: favoritesOnly) }
    private func query(status: String, genres: Set<String>, drive: String, favorites: Bool) -> [MediaTitle] {
        var query = LibraryQuery()
        query.category = category == .movies ? "movie" : category == .shows ? "show" : category == .anime ? "anime" : "all"
        query.status = status == "queue" ? "all" : status; query.queued = status == "queue"; query.genres = genres; query.favorites = favorites
        query.disk = drive.isEmpty ? "all" : ["mapped", "unmapped"].contains(drive) || drive.hasPrefix("[") || drive.hasPrefix("drive:") ? drive : "drive:" + drive.uppercased()
        query.sort = sort
        return store.libraryTitles(query, source: ratingSource)
    }
    private func initializeStorage() {
        guard !initializedStorage else { return }
        initializedStorage = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") && !arguments.contains("--ui-keep-library-preferences") {
            categoryRaw = LibraryCategory.all.rawValue; status = "all"; genresRaw = ""; drive = ""; favoritesOnly = false
        }
        #endif
    }
}

/// A Library poster: rating badge top-left, one state icon top-right (favorite, on disk,
/// completed, queued), a thin progress bar for shows being watched, then name and "2024 · Movie".
struct LibraryPosterCard: View {
    let title: MediaTitle
    /// Select mode puts its check circle where the state icon sits.
    var selecting = false
    @Environment(DiaryStore.self) private var store
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: title.poster, title: title.name, initialsOnly: false).aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if let score { Text(score.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6)).padding(6) }
                }
                .overlay(alignment: .topTrailing) {
                    if !selecting, let icon = stateIcon { DiaryIcon(name: icon, size: 14).foregroundStyle(.white).frame(width: 24, height: 24).background(.black.opacity(0.6), in: Circle()).padding(6) }
                }
                .overlay(alignment: .bottom) {
                    if title.isSeries && title.status == "watching" && progress > 0 {
                        Capsule().fill(.black.opacity(0.55)).frame(height: 4).overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * progress) } }
                            .padding(.horizontal, 7).padding(.bottom, 7)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            Text(title.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1).padding(.top, 6)
            Text([title.year.map(String.init), title.categoryName].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color(webHex: "#a09aa9")).lineLimit(1).padding(.top, 2)
        }.contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title.name)
            .accessibilityValue(Self.details(title, score: score, progress: progress, present: present))
    }
    private var score: Double? { store.publicScore(title, source: ratingSource) }
    private var progress: Double { store.libraryProgress(title) }
    private var present: Bool { store.hasPresentLocation(title.id) }
    private var stateIcon: String? {
        if title.favorite { return "heart" }
        if present { return "monitor" }
        if title.status == "completed" { return "check" }
        if title.queued == true { return "download" }
        return nil
    }
    /// Category, status, rating, progress and state, read by VoiceOver and the UI tests.
    static func details(_ title: MediaTitle, score: Double?, progress: Double, present: Bool) -> String {
        [title.categoryName, title.status.capitalized, score.map { "Rating " + $0.formatted(.number.precision(.fractionLength(1))) },
         title.status != "completed" && progress > 0 ? "\(Int((progress * 100).rounded())) percent watched" : nil,
         title.favorite ? "Favorite" : nil, title.queued == true ? "In Queue" : nil, present ? "On your PC" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A Library row: poster, name, "2023 · Movie · Drama", the status chip and rating; a check
/// circle in select mode.
struct LibraryListRow: View {
    let title: MediaTitle
    var selected: Bool?
    @Environment(DiaryStore.self) private var store
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        let score = store.publicScore(title, source: ratingSource)
        HStack(spacing: 12) {
            Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(title.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1)
                Text(([title.year.map(String.init), title.categoryName, title.genres.first]).compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Color(webHex: "#a09aa9")).lineLimit(1)
                HStack(spacing: 6) {
                    Text(title.status.capitalized).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(webHex: "#c5c0cf"))
                        .padding(.horizontal, 8).frame(height: 20).overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                    if let score { Text(score.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 12)).foregroundStyle(Color(webHex: "#a09aa9")) }
                }.padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(selected ? theme.accent : Color(webHex: "#a09aa9"))
            } else { DiaryIcon(name: "chevron-right", size: 15).foregroundStyle(Color(webHex: "#a09aa9")) }
        }.padding(10).background(Color(webHex: "#16151b"), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected == true ? theme.accent.opacity(0.7) : .white.opacity(0.1)))
            .contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(title.name)
            .accessibilityValue(LibraryPosterCard.details(title, score: score, progress: store.libraryProgress(title), present: store.hasPresentLocation(title.id)))
    }
}

@MainActor func titleRow(_ title: MediaTitle) -> some View {
    HStack(spacing: 12) {
        Artwork(path: title.poster, title: title.name).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 5) { Text(title.name).font(.subheadline.bold()); Text(title.categoryName).font(.caption).foregroundStyle(.secondary) }
        Spacer(); DiaryIcon(name: "chevron-right", size: 15).foregroundStyle(.secondary)
    }.foregroundStyle(.white).diaryPanel()
}

struct GlanceView: View {
    @AppStorage("glanceGrid") private var grid = false
    @AppStorage("glanceSort") private var sortRaw = GlanceSort.recentlyUpdated.rawValue
    @Environment(DiaryStore.self) private var store
    @State private var category = LibraryCategory.all
    @State private var search = ""
    @State private var showSearch = false
    var body: some View {
        // One pass over the library per update instead of three.
        let watching = store.workspace.activeTitles.filter { $0.status == "watching" }
        let titles = watching.filter { category.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        let ordered = order(titles)
        VStack(spacing: 0) {
            PageHeader(name: "Glance", count: "\(watching.count) watching", onSearch: { showSearch.toggle(); if !showSearch { search = "" } }, circledSearch: true)
            if showSearch { SearchField(placeholder: "Find a current watch…", text: $search, label: "Find a current watch", autoFocus: true).padding(.horizontal, 14).padding(.bottom, 10) }
            CategoryPicker(selection: $category)
            SortMenuRow(options: GlanceSort.allCases, selection: sort, label: \.label, identifier: "glance-sort") {
                CollectionLayoutToggle(grid: $grid, collection: "glance", small: true)
            }
            ScrollView {
                VStack(spacing: 8) {
                    // The title you logged last (or first in the chosen order) gets the large card.
                    if let first = ordered.first { ProgressCard(title: first, hero: true) }
                    CollectionLayout(grid: grid, spacing: 8) { ForEach(ordered.dropFirst()) { ProgressCard(title: $0, grid: grid) } }
                }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 100)
                if titles.isEmpty { DiaryEmptyState(title: "A clear little corner", description: "No current watches match these filters. Try another category or clear your search.").padding(.horizontal, 14).padding(.top, 20) }
            }.accessibilityIdentifier("glance-content").refreshable { await store.refresh() }
        }
    }
    private var sort: Binding<GlanceSort> {
        Binding(get: { GlanceSort(rawValue: sortRaw) ?? .recentlyUpdated }, set: { sortRaw = $0.rawValue })
    }
    private func order(_ titles: [MediaTitle]) -> [MediaTitle] {
        let chosen = sort.wrappedValue
        let progress = chosen == .almostDone ? Dictionary(uniqueKeysWithValues: titles.map { ($0.id, store.libraryProgress($0)) }) : [:]
        let activity = chosen == .recentlyUpdated ? GlanceOverview.lastActivity(events: store.workspace.events) : [:]
        return GlanceOverview.order(titles, sort: chosen, lastActivity: activity, progress: progress)
    }
}
