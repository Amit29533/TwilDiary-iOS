import SwiftUI
import TwilDiaryCore

struct LibraryView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(AppRouter.self) private var router
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @SceneStorage("library.category") private var categoryRaw = LibraryCategory.all.rawValue
    @SceneStorage("library.status") private var status = "all"
    @SceneStorage("library.genre") private var genre = ""
    @SceneStorage("library.drive") private var drive = ""
    @State private var showSearch = false
    @State private var showAdd = false
    @State private var addedTitle: String?
    @State private var addedCatalog: CatalogRoute?
    @AppStorage("library.list") private var list = false
    @AppStorage("library.genreRows") private var genreRows = false
    @AppStorage("library.sort") private var sort = LibraryQuery.Sort.library
    @State private var initializedStorage = false
    private var category: LibraryCategory {
        get { LibraryCategory(rawValue: categoryRaw) ?? .all }
        nonmutating set { categoryRaw = newValue.rawValue }
    }
    @State private var appliedShortcutRevision = 0
    @State private var visibleLimit = 48
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var review: CollectionReview?
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(name: "Library", count: String(collection.count), onSearch: { showSearch.toggle() }, height: 54)
            if showSearch {
                ScrollView { CatalogSearchView(onClose: { showSearch = false }).padding(.top, 2) }
            } else {
                CategoryPicker(selection: Binding(get: { category }, set: { category = $0 }))
                collectionContent
            }
        }.background(theme == .glass ? .clear : Color(webHex: "#0e0d13")).diaryScreenBackground()
            .task(id: collection.map(\.id).sorted().joined(separator: ",") + ratingSource.rawValue) { await store.loadPublicRatings(collection, source: ratingSource) }
            .onChange(of: router.libraryRevision) { _, _ in applyShortcut() }
            .onAppear { initializeStorage(); applyShortcut() }
            .onChange(of: filterScope) { _, _ in selecting = false; selected = []; visibleLimit = 48 }
            .onChange(of: filtered.map(\.id)) { _, ids in selected.formIntersection(ids) }
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
    private func ratingStatus(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
    }
    private var filterBar: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Status", selection: $status) {
                            Text("All statuses").tag("all")
                            ForEach(["planned", "watching", "completed", "dropped", "queue"], id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    } label: { filterChip(status == "all" ? "Status" : status.capitalized, selected: status != "all") }.accessibilityIdentifier("library-status")
                    Menu {
                        Picker("Genre", selection: $genre) { Text("All genres").tag(""); ForEach(genres, id: \.self) { value in Text("\(value) (\(collection.filter { $0.genres.contains(value) }.count))").tag(value) } }
                    } label: { filterChip(genre.isEmpty ? "Genre" : genre, selected: !genre.isEmpty) }.accessibilityIdentifier("library-genre")
                    Menu {
                        Picker("Disk", selection: $drive) {
                            Text("All disks").tag("")
                            ForEach(HomeDiskShortcut.all) { Text($0.label).tag($0.key) }
                            ForEach(extraDisks) { Text($0.deviceName + " · " + $0.letters.joined(separator: " / ")).tag($0.key) }
                            Text("No disk mapping").tag("unmapped")
                        }
                    } label: { filterChip(driveLabel, selected: !drive.isEmpty) }.accessibilityIdentifier("library-disk")
                    NavigationLink(value: AppDestination.trash) { trashChip }.accessibilityLabel("Open Trash")
                }.buttonStyle(.plain).foregroundStyle(Color(webHex: "#c5c0cf")).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }.scrollIndicators(.hidden)
    }
    private var orderingBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                Text(hasFilters ? "" : "All titles")
                    .font(.system(size: geometry.size.width < 331 ? 13 : 14))
                    .foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Picker("Order", selection: $sort) {
                        Text("Library order").tag(LibraryQuery.Sort.library); Text("Title A–Z").tag(LibraryQuery.Sort.title)
                        Text("Newest year").tag(LibraryQuery.Sort.year); Text("Highest " + ratingSource.label + " rating").tag(LibraryQuery.Sort.score)
                    }
                } label: {
                    HStack(spacing: 5) {
                        DiaryIcon(name: "arrow-down-up", size: 17)
                        HStack(spacing: 0) {
                            Text(sortLabel).lineLimit(1)
                            Spacer(minLength: 0)
                            DiaryIcon(name: "chevron-down", size: 12)
                        }.font(.system(size: geometry.size.width < 331 ? 12 : 13, weight: .semibold))
                            .frame(width: geometry.size.width < 331 ? 110 : 145, height: 44)
                    }.padding(.horizontal, 9).frame(height: 46).contentShape(RoundedRectangle(cornerRadius: 14))
                        .background { DiaryControlSurface(shape: RoundedRectangle(cornerRadius: 14)) }
                }.buttonStyle(.plain).accessibilityIdentifier("library-order")
                if selecting {
                    Button("Done selecting", systemImage: "xmark") { selecting = false; selected = [] }
                        .labelStyle(.iconOnly).frame(width: 42, height: 44)
                } else {
                    Button { list.toggle(); genreRows = false } label: { layoutIcon(list ? "list" : "layout-grid", selected: true) }
                        .accessibilityLabel(list ? "Grid layout" : "List layout").accessibilityIdentifier("library-layout")
                    Button { genreRows.toggle(); list = false } label: { layoutIcon("rows-3", selected: genreRows, genre: true) }
                        .accessibilityLabel("Genre sections").accessibilityIdentifier("library-genres")
                }
            // Native glass comes from DiaryControlSurface behind each label. The glass
            // button style would add its own padding and break the fixed 46/44 pt sizes.
            }.foregroundStyle(Color(webHex: "#c5c0cf")).buttonStyle(.plain)
        }.frame(height: 46).padding(.horizontal, 14).padding(.bottom, 12)
    }
    private var sortLabel: String {
        switch sort { case .title: "Title A–Z"; case .year: "Newest year"; case .score: "Highest " + ratingSource.label + " rating"; case .library: "Library order" }
    }
    private var collectionContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                filterBar
                if hasFilters {
                    HStack(spacing: 12) { Text("\(filtered.count) \(filtered.count == 1 ? "title" : "titles")").foregroundStyle(.secondary); Button("Clear filters") { category = .all; status = "all"; genre = ""; drive = "" }; Spacer(minLength: 0) }.font(.system(size: 13)).padding(.horizontal, 14).padding(.bottom, 8)
                }
                orderingBar
                if ratingSource == .trakt {
                    if store.communityRatings.loading { ratingStatus("Loading Trakt community ratings…") }
                    else if store.communityRatings.unavailable {
                        HStack(alignment: .top, spacing: 8) {
                            Text("Some Trakt ratings are unavailable.").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Retry") { Task { await store.loadPublicRatings(collection, source: ratingSource, retry: true) } }.font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("ratings-retry")
                        }.padding(.horizontal, 14).padding(.bottom, 10)
                    }
                }
            }
                if selecting { CollectionSelectionPanel(titles: filtered, selected: $selected, onReview: prepareReview).padding(.horizontal, 14).padding(.bottom, 12) }
                if genreRows && !selecting {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(LibraryShelf.make(filtered)) { shelf in
                            HStack { Text(shelf.genre).font(.headline); Text("\(shelf.titles.count)").font(.caption).foregroundStyle(.secondary); Spacer(); if shelf.genre != "Without a genre" { Button("See all") { genre = shelf.genre; genreRows = false }.font(.caption.bold()).accessibilityLabel("See all \(shelf.genre) titles") } }
                            ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { ForEach(shelf.titles) { title in poster(title).frame(width: 112) } } }.scrollIndicators(.hidden)
                        }
                    }.padding(.horizontal, 14)
                } else if list {
                    LazyVStack(spacing: 12) { ForEach(Array(filtered.prefix(visibleLimit))) { title in poster(title, row: true) } }.padding(.horizontal, 14)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), alignment: .leading, spacing: 18) { ForEach(Array(filtered.prefix(visibleLimit))) { poster($0) } }.padding(.horizontal, 14)
                }
                if !genreRows && visibleLimit < filtered.count { Color.clear.frame(height: 1).onAppear { visibleLimit += 48 } }
                if filtered.isEmpty { DiaryEmptyState(title: "Nothing here just yet", description: "Try a different search or clear a filter to find your stories.").padding(.horizontal, 14).padding(.top, 20) }
            }.refreshable { await store.refresh(); await store.loadPublicRatings(collection, source: ratingSource) }
    }
    private func applyShortcut() {
        guard router.libraryRevision > appliedShortcutRevision else { return }
        appliedShortcutRevision = router.libraryRevision
        category = .all; genre = router.libraryGenreShortcut; drive = router.libraryDiskShortcut; status = "all"
        switch router.libraryShortcut { case "queue": status = "queue"; case "planned", "watching", "completed", "dropped": status = router.libraryShortcut ?? "all"; case "disk": drive = HomeDiskShortcut.all.first?.key ?? ""; case "add": showAdd = true; default: break }
    }
    @ViewBuilder private func poster(_ title: MediaTitle, row: Bool = false) -> some View {
        if selecting {
            Button { if selected.contains(title.id) { selected.remove(title.id) } else if selected.count < CollectionRequest.limit { selected.insert(title.id) } } label: {
                cardContent(title, row: row).overlay(alignment: .topTrailing) { Image(systemName: selected.contains(title.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(selected.contains(title.id) ? theme.accent : .white).padding(7).shadow(color: .black, radius: 3) }
            }.buttonStyle(.plain).disabled(store.busy || (!selected.contains(title.id) && selected.count >= CollectionRequest.limit)).accessibilityIdentifier("select-title-" + title.id).accessibilityAddTraits(selected.contains(title.id) ? .isSelected : [])
        } else {
            NavigationLink(value: title.id) { cardContent(title, row: row) }.buttonStyle(.plain).contentShape(Rectangle()).accessibilityIdentifier("title-" + title.id)
                .contextMenu {
                    Button("Select") { selecting = true; selected = [title.id] }
                    Button(title.favorite ? "Remove favorite" : "Favorite") { review = CollectionReview(titles: [title], change: .favorite(!title.favorite)) }
                    Button(title.queued == true ? "Remove from Queue" : "Add to Queue") { review = CollectionReview(titles: [title], change: .queue(title.queued != true)) }
                    Button("Move to Trash", role: .destructive) { review = CollectionReview(titles: [title], change: .trash) }
                }
        }
    }
    @ViewBuilder private func cardContent(_ title: MediaTitle, row: Bool) -> some View { if row { LibraryTitleRow(title: title) } else { PosterCard(title: title).contentShape(Rectangle()) } }
    private func prepareReview(_ change: CollectionChange) { let titles = filtered.filter { selected.contains($0.id) }; if !titles.isEmpty { review = CollectionReview(titles: titles, change: change) } }
    private var filterScope: String { [category.rawValue, status, genre, drive, sort.rawValue].joined(separator: "\n") }
    private var collection: [MediaTitle] { store.workspace.activeTitles }
    private var trashChip: some View { HStack(spacing: 6) { DiaryIcon(name: "trash-2", size: 15); Text("Trash") }.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).frame(height: 40).background { DiaryControlSurface(shape: Capsule()) } }
    private func filterChip(_ label: String, selected: Bool) -> some View {
        HStack(spacing: 7) { Text(label).lineLimit(1); DiaryIcon(name: "chevron-down", size: 15) }.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).frame(height: 40).background { DiaryControlSurface(shape: Capsule(), selected: selected) }
    }
    private func layoutIcon(_ name: String, selected: Bool, genre: Bool = false) -> some View {
        DiaryIcon(name: name, size: 20).foregroundStyle(genre && selected ? theme.accent : Color(webHex: "#c5c0cf"))
            .frame(width: genre ? 36 : 42, height: 44)
            .background { DiaryControlSurface(shape: RoundedRectangle(cornerRadius: 14), selected: genre && selected) }
            .contentShape(Rectangle())
    }
    private var genres: [String] { LibraryShelf.make(collection).map(\.genre).filter { $0 != "Without a genre" } }
    private var hasFilters: Bool { category != .all || status != "all" || !genre.isEmpty || !drive.isEmpty }
    private var disks: [DiskSummary] { let ids = Set(collection.map(\.id)); return DiskSummary.make(store.workspace.locations.filter { ids.contains($0.titleId) }) }
    private var extraDisks: [DiskSummary] { disks.filter { disk in disk.key == drive || disk.letters.allSatisfy { letter in !HomeDiskShortcut.all.contains { $0.key == "drive:" + letter.uppercased() } } } }
    private var driveLabel: String { if drive.isEmpty { return "Disk" }; if drive == "mapped" { return "On disk" }; if drive == "unmapped" { return "No disk mapping" }; if let shortcut = HomeDiskShortcut.all.first(where: { $0.key == drive }) { return shortcut.label }; return disks.first { $0.key == drive }?.letters.joined(separator: " / ") ?? "Selected disk" }
    private var filtered: [MediaTitle] {
        var query = LibraryQuery()
        query.category = category == .movies ? "movie" : category == .shows ? "show" : category == .anime ? "anime" : "all"
        query.status = status == "queue" ? "all" : status; query.queued = status == "queue"; query.genre = genre
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
            categoryRaw = LibraryCategory.all.rawValue; status = "all"; genre = ""; drive = ""
        }
        #endif
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
    @Environment(DiaryStore.self) private var store
    @State private var category = LibraryCategory.all
    @State private var search = ""
    @State private var showSearch = false
    var body: some View {
        // One pass over the library per update instead of three.
        let watching = store.workspace.activeTitles.filter { $0.status == "watching" }
        let titles = watching.filter { category.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
        VStack(spacing: 0) {
            PageHeader(name: "Glance", count: "\(watching.count) watching", onSearch: { showSearch.toggle(); if !showSearch { search = "" } })
            if showSearch { SearchField(placeholder: "Find a current watch…", text: $search, label: "Find a current watch", autoFocus: true).padding(.horizontal, 14).padding(.bottom, 10) }
            HStack(spacing: 0) { CategoryPicker(selection: $category); CollectionLayoutToggle(grid: $grid, collection: "glance").padding(.trailing, 8) }
            ScrollView {
                CollectionLayout(grid: grid, spacing: 8) { ForEach(titles) { ProgressCard(title: $0, grid: grid) } }.padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 100)
                if titles.isEmpty { DiaryEmptyState(title: "A clear little corner", description: "No current watches match these filters. Try another category or clear your search.").padding(.horizontal, 14).padding(.top, 20) }
            }.accessibilityIdentifier("glance-content").refreshable { await store.refresh() }
        }
    }
}
