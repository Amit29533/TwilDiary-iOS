import SwiftUI
import TwilDiaryCore

/// Library (approved design): header with Search, category pills, status chips
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
    @SceneStorage("library.tag") private var tag = ""
    @SceneStorage("library.drive") private var drive = ""
    @SceneStorage("library.favorites") private var favoritesOnly = false
    /// "Your rating": only titles you rated at least this (0: any).
    @SceneStorage("library.minScore") private var minScore = 0
    @State private var namingShelf = false
    @State private var shelfName = ""
    @State private var showFilters = false
    @State private var showAllGenres = false
    /// The overview's "See all" shows the whole grid until the filters change.
    @State private var expandedAll = false
    /// The status chips scroll sideways, so a drag that starts on them never changes the category.
    @State private var chipRow = CGRect.null
    /// The visible height of the scroll view, so a short category still fills it and takes the swipe.
    @State private var viewport: CGFloat = 0
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
    @State private var jellyfin = JellyfinShelf.shared
    var body: some View {
        VStack(spacing: 0) {
            if selecting { selectionHeader }
            collectionContent
        }
        .background(Color(webHex: "#0e0d13")).diaryScreenBackground()
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar.padding(.horizontal, 16).padding(.bottom, 8) } }
            .task(id: collection.map(\.id).sorted().joined(separator: ",") + ratingSource.rawValue + String(store.communityRatings.retryRound)) { await store.loadPublicRatings(collection, source: ratingSource) }
            .onChange(of: router.libraryRevision) { _, _ in applyShortcut() }
            .onAppear { initializeStorage(); applyShortcut() }
            // At home, the Jellyfin list is read again now and then; away, the saved one stays.
            .task { await jellyfin.refreshQuietly(store: store) }
            .onChange(of: filterScope) { _, _ in selected.formIntersection(filtered.map(\.id)); visibleLimit = 48 }
            .onChange(of: filtered.map(\.id)) { _, ids in selected.formIntersection(ids) }
            // Opens at half height; pulling it up by its top brings the whole board.
            .sheet(isPresented: $showFilters) { filterSheet.presentationDetents([.medium, .large]).presentationContentInteraction(.resizes).presentationDragIndicator(.visible) }
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
    /// Jellyfin keeps the titles on the owner's Jellyfin server; every other filter still applies.
    private static let statuses = [("all", "All"), ("watching", "Watching"), ("planned", "Planned"), ("completed", "Completed"), ("dropped", "Dropped"), ("jellyfin", "Jellyfin"), ("queue", "Queue")]
    private var statusChips: some View {
        let counts = statusCounts
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.statuses.filter { $0.0 != "all" }, id: \.0) { key, name in
                    let on = status == key
                    Button { status = on ? "all" : key } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Self.statusDot(key)).frame(width: 8, height: 8)
                            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? HomeStyle.chipText : HomeStyle.primary)
                            Text("\(counts[key] ?? 0)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(on ? HomeStyle.chipText.opacity(0.8) : HomeStyle.secondary)
                        }.padding(.horizontal, 14).frame(height: 40)
                            .background(on ? HomeStyle.chip : HomeStyle.round, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? HomeStyle.chipText.opacity(0.5) : HomeStyle.dateChipBorder, lineWidth: on ? 1 : HomeStyle.hairline))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(name).accessibilityValue("\(counts[key] ?? 0) titles")
                        .accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("library-status-" + key)
                }
            }.padding(.horizontal, 14)
        }.scrollIndicators(.hidden).padding(.vertical, 6)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Motion.swipeSpace)) } action: { chipRow = $0 }
    }
    /// Watching in the accent, Planned grey, Completed green (design), Dropped red.
    static func statusDot(_ key: String) -> Color {
        switch key {
        case "watching": HomeStyle.chipText
        case "planned": Color(webHex: "#8e8e9c")
        case "completed": Color(webHex: "#5fd48a")
        case "dropped": Color(webHex: "#ff8a80")
        case "jellyfin": Color(webHex: "#00a4dc")
        default: Color(webHex: "#f5c26b")
        }
    }
    private var sortRow: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Order", selection: $sort) {
                    Text("Recently added").tag(LibraryQuery.Sort.added); Text("Library order").tag(LibraryQuery.Sort.library)
                    Text("Title A–Z").tag(LibraryQuery.Sort.title); Text("Newest year").tag(LibraryQuery.Sort.year)
                    Text("Highest rating").tag(LibraryQuery.Sort.score)
                }
            } label: {
                FilterPill(label: sortLabel, icon: "arrow-down-up")
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
        switch sort { case .added: "Recently added"; case .title: "Title A–Z"; case .year: "Newest year"; case .score: "Highest rating"; case .library: "Library order" }
    }

    // MARK: Content

    /// True full screen: the whole header (logo, title, Select) scrolls with the collection.
    private var libraryHeader: some View {
        PageHeader(name: "Library", count: "\(collection.count) \(collection.count == 1 ? "title" : "titles")", height: 54)
    }
    private var collectionContent: some View {
        EdgeToEdgeScroll {
            VStack(spacing: 0) {
                if !selecting { libraryHeader }
                CategoryPicker(selection: Binding(get: { category }, set: { category = $0 }))
                statusChips
                sortRow
                if ratingSource == .trakt || ratingSource == .mdblist {
                    if store.communityRatings.loading { ratingStatus("Loading community ratings…") }
                    else if store.communityRatings.unavailable {
                        HStack(alignment: .top, spacing: 8) {
                            Text("Some \(ratingSource.label) ratings are unavailable.").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Retry") { Task { await store.loadPublicRatings(collection, source: ratingSource, retry: true) } }.font(.system(size: 12, weight: .semibold)).accessibilityIdentifier("ratings-retry")
                        }.padding(.horizontal, 14).padding(.bottom, 10)
                    }
                }
                if !store.hasLoadedWorkspace && collection.isEmpty { skeleton }
                else if collection.isEmpty { DiaryEmptyState(title: "Nothing here just yet", description: "Add a movie or show to start your library.").padding(.horizontal, 14).padding(.top, 20) }
                else if filtered.isEmpty && jellyfinExtras.isEmpty { noMatches }
                else {
                    if !filtered.isEmpty { diaryTitles }
                    jellyfinSection
                }
            }.padding(.bottom, selecting ? 90 : 24)
                // On the content, whose coordinates don't move while scrolling (so the chip row's frame
                // only changes with layout, not every scroll frame), at least as tall as the visible area
                // so a short category's empty space still takes the swipe.
                // Genre shelves scroll sideways themselves, so they keep the swipe.
                .frame(minHeight: viewport, alignment: .top)
                .categorySwipe(Binding(get: { category }, set: { category = $0 }), enabled: layout != .shelves && !selecting, ignoring: chipRow)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height - $0.contentInsets.top - $0.contentInsets.bottom } action: { _, height in viewport = max(0, height) }
        .refreshable { await store.refresh(); await store.loadPublicRatings(collection, source: ratingSource) }
    }
    /// Jellyfin chip: what's on Jellyfin but not in the diary, under the diary titles, through the
    /// filters that apply (category, genre, drive). Each opens its TMDB page, where it can be added.
    @ViewBuilder private var jellyfinSection: some View {
        let extras = jellyfinExtras
        if !extras.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Not in your diary").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                    Text("\(extras.count)").font(.system(size: 14)).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("library-jellyfin-extras")
                Text("On your Jellyfin. Open one to add it.").font(.system(size: 13)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                    ForEach(extras) { JellyfinEntryCard(entry: $0) }
                }
            }.padding(.horizontal, 14).padding(.top, filtered.isEmpty ? 4 : 26)
        }
    }
    @ViewBuilder private var diaryTitles: some View {
                    switch selecting ? (layout == .shelves ? .grid : layout) : layout {
                    case .shelves:
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(LibraryShelf.make(filtered)) { shelf in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Text(shelf.genre).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1).truncationMode(.tail)
                                        Text("\(shelf.titles.count)").font(.system(size: 14)).foregroundStyle(.secondary)
                                        Spacer()
                                        if shelf.genre != "Without a genre" {
                                            SectionMoreButton(label: "See all \(shelf.genre) titles", identifier: "library-genre-" + shelf.genre) { genres = [shelf.genre]; genreRows = false; list = false }
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
                        if showsOverview { overview }
                        else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                                ForEach(shown) { title in poster(title).onAppear { revealMore(after: title) } }
                            }.padding(.horizontal, 14)
                        }
                    }
    }
    /// With no filters, the grid opens as an overview: five titles and "+N See all", then the
    /// genres as rows, each opening that genre.
    private var showsOverview: Bool {
        !expandedAll && !selecting && status == "all" && genres.isEmpty && tag.isEmpty && drive.isEmpty && !favoritesOnly && minScore == 0 && filtered.count > 6
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("All titles").font(.system(size: 22, weight: .bold)).tracking(-0.5)
                Spacer()
                Text(filtered.count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#c5c0cf"))
                    .padding(.horizontal, 9).frame(height: 26).background(.white.opacity(0.09), in: Capsule())
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                ForEach(filtered.prefix(5)) { title in poster(title) }
                // Exactly a poster's size (same 2:3 box and corners as the cards beside it).
                Button { expandedAll = true } label: {
                    Color.clear.posterAspect()
                        .overlay {
                            VStack(spacing: 4) {
                                Text("+\((filtered.count - 5).formatted())").font(.system(size: 26, weight: .bold)).foregroundStyle(theme.accent)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                Text("See all").font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.horizontal, 6)
                        }
                        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.springPress).accessibilityLabel("See all \(filtered.count) titles").accessibilityIdentifier("library-see-all")
            }
            HStack {
                Text("Browse by genre").font(.system(size: 22, weight: .bold)).tracking(-0.5).lineLimit(1)
                Spacer()
                SectionMoreButton(label: "All genres", identifier: "library-all-genres") { genreRows = true; list = false }
            }.padding(.top, 12)
            ForEach(LibraryShelf.make(filtered).filter { $0.genre != "Without a genre" }) { shelf in
                Button { genres = [shelf.genre] } label: {
                    HStack {
                        Text(shelf.genre).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        Spacer()
                        Text(shelf.titles.count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#c5c0cf"))
                            .padding(.horizontal, 9).frame(height: 26).background(.white.opacity(0.09), in: Capsule())
                        DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).frame(minHeight: 60).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08))).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("library-genre-row-" + shelf.genre)
            }
        }.padding(.horizontal, 14)
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
            Button("Clear filters") { clearFilters() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                .padding(.horizontal, 18).frame(height: 40).background(HomeStyle.chip, in: Capsule()).buttonStyle(.plain).padding(.top, 6)
        }.frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
    private var skeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 16) {
            ForEach(0..<9, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).posterAspect()
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
            NavigationLink(value: title.id) { Group { if row { LibraryListRow(title: title) } else { LibraryPosterCard(title: title) } }.zoomSource(ZoomID.title(title.id)) }
                .buttonStyle(.springPress).contentShape(Rectangle()).accessibilityIdentifier("title-" + title.id)
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
        filterSheetContent
            .alert("Save as a Home shelf", isPresented: $namingShelf) {
                TextField("Name", text: $shelfName)
                Button("Save") { saveShelf() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("These filters become a shelf on Home, one tap from these titles.") }
    }
    private var filterSheetContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sheetLabel("Genre", detail: genres.isEmpty ? nil : "\(genres.count) selected")
                    let allGenres = genreCounts
                    // The six most common, then "N more" for the rest (any chosen one always shows).
                    let visible = showAllGenres ? allGenres : allGenres.enumerated().filter { $0.offset < 6 || genres.contains($0.element.0) }.map(\.element)
                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(visible, id: \.0) { name, count in
                            let on = genres.contains(name)
                            sheetChip(name, count: count, on: on) { var value = genres; if on { value.remove(name) } else { value.insert(name) }; genres = value }
                                .accessibilityLabel(name).accessibilityValue("\(count) titles").accessibilityIdentifier("filter-genre-" + name)
                        }
                        if allGenres.count > visible.count || showAllGenres && allGenres.count > 6 {
                            Button { withAnimation(.smooth(duration: 0.25)) { showAllGenres.toggle() } } label: {
                                HStack(spacing: 6) {
                                    Text(showAllGenres ? "Fewer" : "\(allGenres.count - visible.count) more")
                                    Image(systemName: showAllGenres ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold))
                                }.font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                    .padding(.horizontal, 16).frame(height: 42)
                                    .overlay(Capsule().strokeBorder(HomeStyle.chipText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            }.buttonStyle(.plain).accessibilityIdentifier("filter-genre-more")
                        }
                    }
                    if !collectionTags.isEmpty || !tag.isEmpty {
                        sheetLabel("Collection")
                        InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                            sheetChip("All collections", on: tag.isEmpty) { tag = "" }
                            ForEach(collectionTags, id: \.self) { value in
                                sheetChip(value, on: tag == value) { tag = value }.accessibilityIdentifier("filter-tag-" + value)
                            }
                        }
                    }
                    sheetLabel("Availability")
                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        sheetChip("Any", on: drive.isEmpty) { drive = "" }.accessibilityIdentifier("filter-disk-any")
                        sheetChip("On disk", on: drive == "mapped") { drive = "mapped" }.accessibilityIdentifier("filter-disk-mapped")
                        sheetChip("Not on disk", on: drive == "unmapped") { drive = "unmapped" }.accessibilityIdentifier("filter-disk-unmapped")
                        ForEach(HomeDiskShortcut.all) { disk in sheetChip(disk.label, icon: "internaldrive", on: drive == disk.key) { drive = disk.key } }
                        ForEach(extraDisks) { disk in sheetChip(disk.deviceName + " · " + disk.letters.joined(separator: " / "), icon: "internaldrive", on: drive == disk.key) { drive = disk.key } }
                    }
                    sheetLabel("Your rating")
                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        sheetChip("Any", on: minScore == 0) { minScore = 0 }.accessibilityIdentifier("filter-rating-any")
                        ForEach([6, 7, 8, 9], id: \.self) { least in
                            sheetChip("\(least)+", on: minScore == least) { minScore = least }.accessibilityIdentifier("filter-rating-\(least)")
                        }
                    }
                    sheetLabel("Show")
                    VStack(spacing: 0) {
                        Button { shelfName = activeFilterNames.joined(separator: " · "); namingShelf = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                Text("Save as a Home shelf").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                Spacer()
                            }.padding(.horizontal, 16).frame(minHeight: 58).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(activeFilterNames.isEmpty).opacity(activeFilterNames.isEmpty ? 0.45 : 1)
                            .accessibilityIdentifier("filter-save-shelf")
                        SettingsDivider()
                        Toggle(isOn: $favoritesOnly) { Text("Favorites only").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary).frame(maxWidth: .infinity, alignment: .leading) }
                            .toggleStyle(SettingsToggleStyle()).padding(.horizontal, 16).frame(minHeight: 58).accessibilityIdentifier("filter-favorites")
                        SettingsDivider()
                        Button { showFilters = false; openTrash() } label: {
                            HStack(spacing: 12) {
                                DiaryIcon(name: "trash-2", size: 17).foregroundStyle(HomeStyle.secondary)
                                Text("Trash").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                Spacer()
                                Text(trashCount.counted("title", "titles")).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                            }.padding(.horizontal, 16).frame(minHeight: 58).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Open Trash")
                    }.modifier(SettingsCard())
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            // The result button stays pinned while the filters scroll.
            .safeAreaInset(edge: .bottom) {
                Button { showFilters = false } label: { Text("Show \(filtered.count) \(filtered.count == 1 ? "title" : "titles")") }
                    .buttonStyle(SettingsPrimaryButtonStyle()).padding(.horizontal, 20).padding(.vertical, 8).accessibilityIdentifier("filter-show")
                    // Solid under the button down to the screen edge, so chips never show beneath it.
                    .background(alignment: .bottom) {
                        LinearGradient(stops: [.init(color: Color(webHex: "#111116").opacity(0), location: 0), .init(color: Color(webHex: "#111116"), location: 0.4)],
                                       startPoint: .top, endPoint: .bottom)
                            .padding(.top, -24).ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
                    }
            }
            .navigationTitle("Filters").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFilters = false } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
                            .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    }.buttonStyle(.plain).accessibilityLabel("Close")
                }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { genres = []; tag = ""; drive = ""; favoritesOnly = false } label: { Text("Clear").lineLimit(1).fixedSize() }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                        .padding(.horizontal, 16).frame(height: 40).background(HomeStyle.chip, in: Capsule())
                        .buttonStyle(.plain).disabled(activeFilterCount == 0).opacity(activeFilterCount == 0 ? 0.5 : 1)
                }.sharedBackgroundVisibility(.hidden)
            }
        }.presentationBackground(Color(webHex: "#111116"))
    }
    private func sheetLabel(_ text: String, detail: String? = nil) -> some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 13, weight: .bold)).tracking(1.2).foregroundStyle(HomeStyle.secondary)
            Spacer()
            if let detail { Text(detail).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText) }
        }.padding(.top, 22).padding(.bottom, 10)
    }
    /// A filter chip (design): name and count on a dark pill; chosen, the accent with dark text.
    private func sheetChip(_ label: String, count: Int? = nil, icon: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? Color(webHex: "#1a1030") : HomeStyle.secondary) }
                Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#1a1030") : HomeStyle.primary).lineLimit(1)
                if let count { Text(count.formatted()).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(on ? Color(webHex: "#1a1030").opacity(0.7) : HomeStyle.secondary) }
            }.padding(.horizontal, 16).frame(height: 42)
                .background(on ? theme.accent : HomeStyle.round, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    /// The sheet sits outside the navigation stack, so Trash is pushed onto Library's path.
    private func openTrash() { router.paths[.library, default: NavigationPath()].append(AppDestination.trash) }

    // MARK: Data

    private func applyShortcut() {
        guard router.libraryRevision > appliedShortcutRevision else { return }
        appliedShortcutRevision = router.libraryRevision
        category = .all; genres = router.libraryGenreShortcut.isEmpty ? [] : [router.libraryGenreShortcut]; drive = router.libraryDiskShortcut; status = "all"; tag = ""; favoritesOnly = false
        minScore = 0
        switch router.libraryShortcut { case "queue": status = "queue"; case "planned", "watching", "completed", "dropped": status = router.libraryShortcut ?? "all"; case "disk": drive = HomeDiskShortcut.all.first?.key ?? ""; case "add": router.search(); default: break }
        // A Home shelf's ›: its saved filter, all of it.
        if let saved = router.librarySavedShortcut {
            category = LibraryCategory(rawValue: saved.category) ?? .all; status = saved.status; genres = Set(saved.genres)
            tag = saved.tag; drive = saved.drive; favoritesOnly = saved.favorites; minScore = saved.minScore ?? 0
            if let order = LibraryQuery.Sort(rawValue: saved.sort) { sort = order }
        }
    }
    private var filterScope: String { [category.rawValue, status, genresRaw, tag, drive, String(favoritesOnly), String(minScore), sort.rawValue].joined(separator: "\n") }
    private var collectionTags: [String] { Array(Set(collection.flatMap { $0.tags ?? [] })).sorted() }
    private var collection: [MediaTitle] { store.workspace.activeTitles }
    private var trashCount: Int { store.phoneOnly ? PhoneTrash.shared.titles.count : store.workspace.titles.count { $0.deletedAt != nil } }
    private var activeFilterCount: Int { genres.count + (tag.isEmpty ? 0 : 1) + (drive.isEmpty ? 0 : 1) + (favoritesOnly ? 1 : 0) + (minScore > 0 ? 1 : 0) }
    private var activeFilterNames: [String] {
        var names: [String] = []
        if category != .all { names.append(category.rawValue) }
        if status != "all" { names.append(status.capitalized) }
        names += genres.sorted()
        if !tag.isEmpty { names.append(tag) }
        if !drive.isEmpty { names.append(driveLabel) }
        if favoritesOnly { names.append("Favorites") }
        if minScore > 0 { names.append("Rated \(minScore)+") }
        return names
    }
    private func clearFilters() { category = .all; status = "all"; genres = []; tag = ""; drive = ""; favoritesOnly = false; minScore = 0 }
    /// Saves what's chosen now (category, status, genres, collection, disk, favourites, rating and
    /// order) as a shelf on Home.
    private func saveShelf() {
        let name = shelfName.trimmingCharacters(in: .whitespacesAndNewlines)
        SavedFilters.shared.add(SavedFilter(name: name.isEmpty ? activeFilterNames.joined(separator: " · ") : name, category: category.rawValue,
                                            status: status, genres: genres.sorted(), tag: tag, drive: drive, favorites: favoritesOnly,
                                            minScore: minScore > 0 ? minScore : nil, sort: sort.rawValue))
    }
    /// Genres in the current category and status, most common first.
    private var genreCounts: [(String, Int)] {
        let diary = LibraryShelf.make(query(status: status, genres: [], drive: "", favorites: false)).filter { $0.genre != "Without a genre" }.map { ($0.genre, $0.titles.count) }
        guard status == "jellyfin" else { return diary }
        // The Jellyfin chip also counts the Jellyfin titles not in the diary.
        var counts = Dictionary(diary, uniquingKeysWith: +)
        for entry in extras(genres: [], drive: "", favorites: false) { for genre in Set(entry.genres ?? []) { counts[genre, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key.localizedStandardCompare($1.key) == .orderedAscending : $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    /// Jellyfin titles not in the diary, shown under the Jellyfin chip (not while selecting:
    /// only diary titles can be changed together).
    private var jellyfinExtras: [JellyfinEntry] {
        status == "jellyfin" && !selecting ? extras(genres: genres, drive: drive, favorites: favoritesOnly) : []
    }
    private func extras(genres: Set<String>, drive: String, favorites: Bool) -> [JellyfinEntry] {
        guard tag.isEmpty else { return [] }
        return jellyfin.extras(diary: collection, category: categoryKey, genres: genres, disk: diskKey(drive), favorites: favorites, sort: sort)
    }
    private var categoryKey: String { category == .movies ? "movie" : category == .shows ? "show" : category == .anime ? "anime" : "all" }
    private func diskKey(_ drive: String) -> String {
        drive.isEmpty ? "all" : ["mapped", "unmapped"].contains(drive) || drive.hasPrefix("[") || drive.hasPrefix("drive:") ? drive : "drive:" + drive.uppercased()
    }
    /// Each status chip counts the titles every other filter leaves.
    private var statusCounts: [String: Int] {
        let base = query(status: "all", genres: genres, drive: drive, favorites: favoritesOnly)
        var counts = Dictionary(grouping: base, by: \.status).mapValues(\.count)
        counts["all"] = base.count; counts["queue"] = base.count { $0.queued == true }
        counts["jellyfin"] = query(status: "jellyfin", genres: genres, drive: drive, favorites: favoritesOnly).count
            + extras(genres: genres, drive: drive, favorites: favoritesOnly).count
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
        query.category = categoryKey
        query.tag = tag
        query.status = ["queue", "jellyfin"].contains(status) ? "all" : status; query.queued = status == "queue"; query.genres = genres; query.favorites = favorites
        // The saved Jellyfin list (JellyfinShelf) works away from home and after sign-out.
        query.jellyfin = status == "jellyfin"; query.jellyfinTitles = status == "jellyfin" ? jellyfin.titleIDs(diary: collection) : []
        query.disk = diskKey(drive)
        query.minScore = minScore > 0 ? Double(minScore) : nil
        query.sort = sort
        return store.libraryTitles(query, source: ratingSource)
    }
    private func initializeStorage() {
        guard !initializedStorage else { return }
        initializedStorage = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") && !arguments.contains("--ui-keep-library-preferences") {
            categoryRaw = LibraryCategory.all.rawValue; status = "all"; genresRaw = ""; tag = ""; drive = ""; favoritesOnly = false
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
            Artwork(path: title.poster, title: title.name, initialsOnly: false).posterAspect()
                .overlay(alignment: .topLeading) {
                    if let score {
                        HStack(spacing: 3) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(webHex: "#ffc83d")); Text(score.formatted(.number.precision(.fractionLength(1)))) }
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 22).background(.black.opacity(0.72), in: Capsule()).padding(6)
                    }
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
    /// Remembered between visits, like the layout and sort.
    @AppStorage("glanceCategory") private var category = LibraryCategory.all
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var showAll = false
    private func glanceHeading(_ name: String, _ count: Int) -> some View {
        HStack {
            Text(name).font(.system(size: 24, weight: .bold)).tracking(-0.6)
            Spacer()
            Text(count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#c5c0cf"))
                .padding(.horizontal, 9).frame(height: 26).background(.white.opacity(0.09), in: Capsule())
        }.padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 2)
    }
    var body: some View {
        // One pass over the library per update instead of three.
        let watching = store.workspace.activeTitles.filter { $0.status == "watching" }
        let titles = watching.filter { category.includes($0) }
        let ordered = order(titles)
        // True full screen: the header and filters scroll with the cards; nothing stays pinned.
        let header = PageHeader(name: "Glance", count: "\(watching.count) watching")
        EdgeToEdgeScroll {
                VStack(spacing: 0) {
                    header

                    ScrollView(.horizontal) {
                        CategoryPicker(selection: $category, counts: Dictionary(uniqueKeysWithValues: LibraryCategory.allCases.map { item in (item, watching.filter { item.includes($0) }.count) }))
                    }.scrollIndicators(.hidden)
                    HStack(spacing: 10) {
                        Menu {
                            Picker("Order", selection: sort) { ForEach(GlanceSort.allCases, id: \.self) { Text($0.label).tag($0) } }
                        } label: {
                            HStack(spacing: 6) { Text(sort.wrappedValue.label); Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)) }
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                .padding(.horizontal, 14).frame(height: 40).background(HomeStyle.round, in: Capsule())
                                .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                        }.accessibilityLabel("Order").accessibilityValue(sort.wrappedValue.label).accessibilityIdentifier("glance-sort")
                        Spacer(minLength: 0)
                        layoutButton(grid: false, icon: "list.bullet")
                        layoutButton(grid: true, icon: "square.grid.2x2")
                    }.padding(.horizontal, 14).padding(.top, 6)
                }
                // The title you logged last (or first in the chosen order) gets the large card; the rest
                // split into Continue (started) and Not started, each with its count.
                let started = Set(store.workspace.activeEvents.map(\.titleId))
                let rest = Array(ordered.dropFirst())
                let continuing = rest.filter { started.contains($0.id) }, fresh = rest.filter { !started.contains($0.id) }
                VStack(alignment: .leading, spacing: 8) {
                    if let first = ordered.first { ProgressCard(title: first, hero: true) }
                    if !continuing.isEmpty {
                        glanceHeading("Continue", continuing.count)
                        CollectionLayout(grid: grid, spacing: 8) { ForEach(showAll ? continuing : Array(continuing.prefix(8))) { ProgressCard(title: $0, grid: grid) } }
                    }
                    if !fresh.isEmpty && (showAll || continuing.count <= 8) {
                        glanceHeading("Not started", fresh.count)
                        CollectionLayout(grid: grid, spacing: 8) { ForEach(fresh) { ProgressCard(title: $0, grid: grid) } }
                    }
                    if !showAll && continuing.count > 8 {
                        Button { showAll = true } label: {
                            Text("Show all \(titles.count)").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                .frame(maxWidth: .infinity, minHeight: 54).background(HomeStyle.card, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                        }.buttonStyle(.springPress).padding(.top, 6).accessibilityIdentifier("glance-show-all")
                    }
                }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 100)
                if titles.isEmpty { DiaryEmptyState(title: "A clear little corner", description: "No current watches match these filters. Try another category.").padding(.horizontal, 14).padding(.top, 20) }
            }.categorySwipe($category).accessibilityIdentifier("glance-content").refreshable { await store.refresh() }
    }
    /// One side of the list | grid switch: the chosen one sits on the accent tint.
    private func layoutButton(grid value: Bool, icon: String) -> some View {
        Button { withAnimation(.smooth(duration: 0.28)) { grid = value } } label: {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(grid == value ? HomeStyle.chipText : HomeStyle.secondary)
                .frame(width: 40, height: 40).background(grid == value ? HomeStyle.chip : .clear, in: Circle())
                .frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(value ? "Show as grid" : "Show as list").accessibilityAddTraits(grid == value ? .isSelected : [])
            // Both halves say which layout is showing now.
            .accessibilityValue(grid ? "Grid" : "List")
            .accessibilityIdentifier(value ? "glance-layout" : "glance-layout-list")
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
