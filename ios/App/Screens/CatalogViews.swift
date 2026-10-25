import SwiftUI
import UIKit
import TwilDiaryCore

struct CatalogGrid: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("catalogGrid") private var grid = true
    let items: [CatalogItem]
    var showsLayoutToggle = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLayoutToggle { HStack { Spacer(); CollectionLayoutToggle(grid: $grid, collection: "catalog") } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: grid ? 3 : 1), alignment: .leading, spacing: grid ? 20 : 10) {
                ForEach(items, id: \.displayKey) { item in
                    Group {
                        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) { NavigationLink(value: saved) { card(item) } }
                        else { NavigationLink(value: item.route) { card(item) } }
                    }.buttonStyle(.plain).accessibilityIdentifier("catalog-" + item.displayKey)
                }
            }
        }
    }
    @ViewBuilder private func card(_ item: CatalogItem) -> some View {
        if grid { CatalogPoster(item: item) }
        else {
            HStack(spacing: 12) {
                Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 68, height: 102).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text((item.year.map(String.init) ?? "Year unknown") + (item.inLibraryId == nil ? "" : " · In your library")).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let score = item.rating, score > 0 { Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill").font(.system(size: 12)).foregroundStyle(.yellow) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                DiaryIcon(name: "chevron-right", size: 16).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
    }
}

struct CatalogPoster: View {
    let item: CatalogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let score = item.rating, score > 0 {
                        HStack(spacing: 5) { Image(systemName: "star.fill").font(.system(size: 13)); Text(String(format: "%.1f", score)).frame(height: 18) }
                            .font(.system(size: 12)).foregroundStyle(Color(webHex: "#e7ca90"))
                            .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6)).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).frame(minHeight: 20.25).padding(.top, 8)
            Text((item.year.map(String.init) ?? "Year unknown") + (item.inLibraryId == nil ? "" : " · In your library")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(height: 18).padding(.top, 4)
        }.accessibilityElement(children: .combine)
    }
}

struct CatalogSearchView: View {
    var onLibraryChoose: ((String) -> Void)? = nil
    var onCatalogChoose: ((CatalogRoute) -> Void)? = nil
    var allowsManual = true
    var onClose: (() -> Void)? = nil
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var identified: [SearchLibraryTitle] = []
    @State private var results: [CatalogItem] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var showManual = false
    @State private var savedManualID: String?
    @State private var dismissKeyboard = 0
    @AppStorage("searchGrid") private var grid = false
    @State private var page = 1
    @State private var totalPages = 0
    @State private var libraryLimit = 20
    @State private var generation = UUID()
    @State private var completedQuery: String?
    @State private var pageTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                SearchField(placeholder: "Title or IMDb ID…", text: $query, label: "Search library and online", autoFocus: true, dismissRevision: dismissKeyboard)
                if let onClose { Button(action: onClose) { DiaryIcon(name: "x", size: 18).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Close search") }
            }
            if !ready { Text("Find a title, or paste an IMDb ID.").font(.system(size: 14)).foregroundStyle(.secondary) }
            else {
                HStack { Text("In Library · \(localMatches.count)").font(.system(size: 15, weight: .semibold)); Spacer(); CollectionLayoutToggle(grid: $grid, collection: "search") }
                CollectionLayout(grid: grid) { ForEach(localMatches.prefix(libraryLimit)) { title in
                    Button { chooseLibrary(title.id) } label: { searchRow(title) }.buttonStyle(.plain)
                        .accessibilityIdentifier((onLibraryChoose == nil ? "search-library-" : "match-title-") + title.id)
                } }
                if localMatches.count > libraryLimit { Button("More library matches") { libraryLimit += 20 }.font(.system(size: 13)).frame(minHeight: 44) }
                if localMatches.isEmpty { Text("No library matches").font(.system(size: 13)).foregroundStyle(.secondary) }
                Text("Not In Library · TMDB").font(.system(size: 15, weight: .semibold))
                if loading && results.isEmpty { DiaryLoadingPlaceholder(label: "Searching online") }
                if let failure { HStack { Text(failure).font(.system(size: 13)).foregroundStyle(.secondary); Spacer(minLength: 0); Button("Retry") { requestPage(page) }.font(.system(size: 13)) } }
                CollectionLayout(grid: grid) { ForEach(results, id: \.key) { item in
                    Button { chooseCatalog(item.route) } label: { onlineRow(item) }
                        .buttonStyle(.plain).accessibilityIdentifier("search-" + item.key)
                } }
                if !loading && results.isEmpty && failure == nil { Text("No online matches").font(.system(size: 13)).foregroundStyle(.secondary) }
                if totalPages > 1 {
                    HStack { Button("Previous") { requestPage(page - 1) }.disabled(page <= 1 || loading); Spacer(); Text("Page \(page) of \(totalPages)").font(.system(size: 13)).foregroundStyle(.secondary); Spacer(); Button("Next") { requestPage(page + 1) }.disabled(page >= min(500, totalPages) || loading) }.font(.system(size: 13))
                }
            }
            if allowsManual { Button("Add manually") { showManual = true }.font(.system(size: 14, weight: .semibold)).frame(minHeight: 44) }
        }.padding(.horizontal, 14).padding(.bottom, 12)
            .task(id: normalized) { if completedQuery != normalized || failure != nil { await search(number: 1, reset: true) } }
            .onDisappear { pageTask?.cancel(); generation = UUID(); loading = false }
            .sheet(isPresented: $showManual, onDismiss: {
                guard let id = savedManualID else { return }
                savedManualID = nil; chooseLibrary(id)
            }) { ManualTitleView(initialName: normalized) { id in savedManualID = id; showManual = false } }
    }
    private func onlineRow(_ item: CatalogItem) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: grid ? nil : 72, height: grid ? 170 : 108).frame(maxWidth: grid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.system(size: 15, weight: .semibold)); Text([item.year.map(String.init), item.mediaType == .tv ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary) }
            if !grid { Spacer(minLength: 0); DiaryIcon(name: "arrow-up-right", size: 18).foregroundStyle(.tint) }
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).foregroundStyle(.primary)
    }
    private var normalized: String { DiarySearchTools.normalize(query) }
    private var ready: Bool { DiarySearchTools.ready(normalized) }
    private var localMatches: [SearchLibraryTitle] { DiarySearchTools.merging(DiarySearchTools.matches(store.workspace, query: normalized), identified) }
    private func searchRow(_ title: SearchLibraryTitle) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Artwork(path: title.artwork, title: title.name).frame(width: grid ? nil : 72, height: grid ? 170 : 108).frame(maxWidth: grid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) { Text(title.name).font(.system(size: 15, weight: .semibold)); Text([title.year.map(String.init), title.category == "anime-movie" ? "Anime movie" : title.category.capitalized].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary) }
            if !grid { Spacer(minLength: 0); DiaryIcon(name: "arrow-up-right", size: 18).foregroundStyle(.tint) }
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).foregroundStyle(.primary)
    }
    private func chooseLibrary(_ id: String) {
        dismissKeyboard += 1
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            if store.title(id) == nil { await store.refresh() }
            guard store.title(id) != nil else { failure = "This title is no longer available. Refresh your library and try again."; return }
            if let onLibraryChoose { onLibraryChoose(id) }
            else { router.openTitle(id, tab: router.selectedTab) }
        }
    }
    private func chooseCatalog(_ route: CatalogRoute) {
        dismissKeyboard += 1
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if let onCatalogChoose { onCatalogChoose(route) }
        else { router.paths[router.selectedTab, default: NavigationPath()].append(route) }
    }
    private func requestPage(_ number: Int) { pageTask?.cancel(); pageTask = Task { await search(number: number) } }
    private func search(number: Int, reset: Bool = false) async {
        let request = UUID(); generation = request
        if reset { completedQuery = nil; results = []; identified = []; page = 1; totalPages = 0; libraryLimit = 20 }
        failure = nil
        guard ready else { loading = false; return }
        let value = normalized; loading = true
        defer { if generation == request { loading = false } }
        do {
            if reset { try await Task.sleep(for: .milliseconds(300)) }
            let response = try await store.searchDiary(value, page: number)
            guard !Task.isCancelled, request == generation, normalized == value else { return }
            guard response.page == number else { throw APIError.message("Search returned an unexpected page. Please retry.") }
            completedQuery = value
            identified = DiarySearchTools.merging(identified, response.library)
            results = response.online; page = response.page; totalPages = response.totalPages
            failure = response.onlineError.isEmpty ? nil : response.onlineError
        } catch is CancellationError { }
        catch { if !Task.isCancelled, request == generation { failure = error.localizedDescription } }
    }
}

struct CatalogDetailView: View {
    let route: CatalogRoute
    var onImported: ((String) -> Void)? = nil
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var details: CatalogBrowse?
    @State private var failure: String?
    @State private var loading = false
    @State private var showOverview = false
    @State private var showInformation = false
    @State private var headerProgress: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let details {
                        TitleHero(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), year: details.details.year, category: details.details.suggestedCategory == "anime-movie" ? "Anime movie" : details.details.suggestedCategory.capitalized, runtime: details.details.runtimeMinutes, series: route.kind == .tv, score: details.details.communityScore, summary: details.details.overview, expanded: $showOverview, onNameScrolled: { headerProgress = $0 }) { EmptyView() }
                        if details.libraryTitle?.trashed == true {
                            NavigationLink(value: AppDestination.trash) { Text("Restore from Trash") }.buttonStyle(.borderedProminent).controlSize(.large)
                        } else if let saved = details.libraryTitle {
                            Button("Open in Library") { accepted(saved.id) }.buttonStyle(.borderedProminent).controlSize(.large)
                        } else {
                            Button { Task { if let id = await store.importTitle(details.details, category: details.details.suggestedCategory) { accepted(id) } } } label: {
                                Text(store.busy ? "Adding…" : "Add to Planned").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink).frame(maxWidth: .infinity).frame(minHeight: 48)
                            }.buttonStyle(.plain).background(theme.accent, in: RoundedRectangle(cornerRadius: 14)).disabled(store.busy || !store.canMutate).accessibilityIdentifier("catalog-add")
                        }
                        if route.kind == .tv { CatalogSeasonPreview(route: route, details: details.details, store: store) }
                        CastAndRelated(route: route, sourceTitle: details.details.name)
                    } else if loading { DiaryLoadingPlaceholder(height: 320, label: "Loading title").padding(16) }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                }.padding(.horizontal, 14).padding(.bottom, 32)
                    .background(alignment: .top) {
                        if let details { TitleArtworkBackdrop(path: CatalogTools.image(details.details.backdropPath, size: "w780"), name: details.details.name, topExtension: geometry.safeAreaInsets.top) }
                    }
            }.scrollClipDisabled().diaryScreenBackground(path: details.flatMap { CatalogTools.image($0.details.backdropPath, size: "w780") }, name: details?.details.name ?? "").navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) { CompactHeaderBackdrop(progress: headerProgress, topInset: geometry.safeAreaInsets.top) }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        if let details { CompactTitleNavigation(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), progress: headerProgress) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        TitleHeaderAction(name: details?.details.name ?? "Title", kind: route.kind, id: route.id,
                            progress: headerProgress, informationPresented: $showInformation, informationIdentifier: "catalog-information")
                    }
                }
                .sheet(isPresented: $showInformation) {
                    CommunityInformationSheet(name: details?.details.name ?? "Title", artwork: details.flatMap { CatalogTools.image($0.details.backdropPath, size: "w780") ?? CatalogTools.image($0.details.posterPath) }, identity: CommunityIdentity(kind: route.kind, id: route.id))
                }
                .task(id: route) { await load() }
        }
    }
    private func accepted(_ id: String) { if let onImported { onImported(id) } else { router.replaceTitle(id, tab: router.selectedTab) } }
    private func load() async {
        guard details == nil else { return }
        loading = true; failure = nil; defer { loading = false }
        do {
            let response = try await store.browse(route); try Task.checkCancellation()
            if let saved = response.libraryTitle, !saved.trashed {
                if store.title(saved.id) == nil { await store.refresh() }
                try Task.checkCancellation()
                if store.title(saved.id) != nil { accepted(saved.id); return }
            }
            details = response
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct CatalogSeasonPreview: View {
    let route: CatalogRoute
    let details: CatalogDetails
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var controller: CatalogEpisodeController
    @State private var selected: Int
    @State private var showAll = false
    @AppStorage("episodesGrid") private var episodesGrid = false
    @State private var expanded = Set<Int>()
    @State private var revealed = Set<Int>()
    init(route: CatalogRoute, details: CatalogDetails, store: DiaryStore) {
        self.route = route; self.details = details
        _selected = State(initialValue: details.seasons?.first(where: { $0.number > 0 })?.number ?? details.seasons?.first?.number ?? 1)
        _controller = State(initialValue: CatalogEpisodeController { season, reveal in try await store.catalogEpisodes(route, season: season, reveal: reveal) })
    }
    private var total: Int { max(controller.items.count, details.seasons?.first(where: { $0.number == selected })?.expectedEpisodes ?? 0) }
    private var visible: [CatalogEpisode] { showAll ? controller.items : Array(controller.items.prefix(4)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Episode 0").font(.system(size: 20, weight: .bold)); Text("of \(total)").font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer(); Text("0%").font(.system(size: 20, weight: .bold)).foregroundStyle(.tint)
                }
                EpisodeProgressTrack(segments: Array(repeating: .unwatched, count: total), season: selected)
            }.padding(.top, 20).padding(.bottom, 8).diaryPanel(padding: 15, radius: 24, accentBorder: true)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Episodes").font(.system(size: 22, weight: .bold))
                        Text("\(controller.items.count) episodes").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Picker("Season", selection: $selected) {
                        ForEach(details.seasons ?? [], id: \.number) { season in Text(season.number == 0 ? "Specials" : "Season \(season.number)").tag(season.number) }
                    }.pickerStyle(.menu).accessibilityIdentifier("catalog-season")
                }
                if controller.loading && controller.items.isEmpty { DiaryLoadingPlaceholder(label: "Loading season") }
                if let error = controller.error { RetryNotice(message: error) { Task { await controller.load(selected, reveal: !hideSpoilers || controller.revealed, force: true) } } }
                if controller.items.isEmpty && !controller.loading && controller.error == nil { ContentUnavailableView("No episode metadata yet", systemImage: "film", description: Text("No episodes are available for this season yet.")) }
                HStack { Spacer(); CollectionLayoutToggle(grid: $episodesGrid, collection: "catalog-episodes") }
                CollectionLayout(grid: episodesGrid) { ForEach(visible) { episode in episodeRow(episode) } }
                if controller.items.count > 4 {
                    Button(showAll ? "Show fewer episodes" : "Show all \(controller.items.count) episodes") { showAll.toggle() }.font(.system(size: 14)).frame(maxWidth: .infinity).frame(minHeight: 44)
                }
            }
        }.task(id: selected) { await controller.load(selected, reveal: !hideSpoilers) }
            .onChange(of: selected) { _, _ in showAll = false; expanded = []; revealed = [] }
            .onChange(of: hideSpoilers) { _, hidden in if !hidden { Task { await controller.load(selected, reveal: true) } } }
    }
    private func episodeRow(_ episode: CatalogEpisode) -> some View {
        let hidden = hideSpoilers && !revealed.contains(episode.number)
        let layout = episodesGrid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if expanded.contains(episode.number) { expanded.remove(episode.number) }
                else { expanded.insert(episode.number); revealed.insert(episode.number); Task { await controller.load(selected, reveal: true) } }
            } label: {
                layout {
                    Group {
                        if hidden { DiaryIcon(name: "eye-off", size: 23).frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary).background(Color(webHex: "#242030")) }
                        else { Artwork(path: CatalogTools.image(episode.stillPath) ?? CatalogTools.image(details.backdropPath), title: details.name) }
                    }.frame(width: episodesGrid ? nil : 96, height: episodesGrid ? 96 : 54).frame(maxWidth: episodesGrid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(episode.number) · " + (hidden ? "A story for later" : episode.name.isEmpty ? "Episode \(episode.number)" : episode.name)).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day() } == true ? "Not watched" : "Not aired yet").foregroundStyle(.secondary)
                            if let score = episode.communityScore, score > 0 { Text("★ " + score.formatted(.number.precision(.fractionLength(1))) + " TMDb").foregroundStyle(.yellow) }
                        }.font(.system(size: 11))
                    }
                    if !episodesGrid { Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details").accessibilityValue(expanded.contains(episode.number) ? "Expanded" : "Collapsed").accessibilityIdentifier("catalog-episode-\(episode.number)")
            if expanded.contains(episode.number) { Text(controller.loading ? "Loading episode…" : episode.overview.isEmpty ? "No synopsis available yet." : episode.overview).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4) }
        }.padding(.vertical, 10).frame(minHeight: 78)
    }
}

struct CastAndRelated: View {
    let route: CatalogRoute
    var sourceTitle: String? = nil
    @Environment(DiaryStore.self) private var store
    @AppStorage("catalogGrid") private var grid = true
    @State private var cast: [CastPerson] = []
    @State private var related: [CatalogItem] = []
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !cast.isEmpty {
                Text("Cast").font(.system(size: 20, weight: .semibold))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(cast) { person in
                            NavigationLink(value: PersonRoute(id: person.id, sourceTitle: sourceTitle, sourceRole: person.character)) {
                                VStack(spacing: 8) {
                                    Artwork(path: CatalogTools.image(person.profilePath, size: "w185"), title: person.name).frame(width: 82, height: 82).clipShape(Circle())
                                    Text(person.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    Text(person.character).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(width: 100).multilineTextAlignment(.center).foregroundStyle(.primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if !related.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("You might like").font(.system(size: 20, weight: .semibold))
                        Spacer(minLength: 8)
                        CollectionLayoutToggle(grid: $grid, collection: "catalog")
                    }
                    CatalogGrid(items: Array(related.prefix(6)), showsLayoutToggle: false)
                }
            }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
        }.task(id: route) { await load() }
    }
    private func load() async {
        failure = nil
        do { cast = try await store.cast(route).cast } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        do { related = try await store.related(route).items } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct ManualTitleView: View {
    var initialName = ""
    var onSaved: ((String) -> Void)? = nil
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ManualTitleDraft()
    @State private var failure: String?
    @State private var identity = UUID().uuidString
    @State private var saving = false
    @State private var initialized = false
    @State private var showRating = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $draft.name).accessibilityIdentifier("manual-name")
                TextField("Release year", text: $draft.year, prompt: Text("Unknown")).keyboardType(.numberPad).accessibilityIdentifier("manual-year")
                Picker("Category", selection: $draft.category) { Text("Movie").tag("movie"); Text("Show").tag("show"); Text("Anime").tag("anime"); Text("Anime movie").tag("anime-movie") }.pickerStyle(.menu).accessibilityIdentifier("manual-category")
                Picker("Watch status", selection: $draft.status) { ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { Text($0.capitalized).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("manual-status")
                DisclosureGroup("Rating", isExpanded: $showRating) { TextField("Your score / 10", text: $draft.score, prompt: Text("Not rated")).keyboardType(.decimalPad).accessibilityIdentifier("manual-score") }
                if draft.status == "completed" { Text("Episode history is tracked separately.").font(.caption).foregroundStyle(.secondary) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).accessibilityIdentifier("manual-error") }
                Button(saving ? "Saving…" : "Add to library") { Task { await save() } }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || saving || !store.canMutate).accessibilityIdentifier("manual-save")
            }.disabled(saving).navigationTitle("Add title").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }.accessibilityIdentifier("manual-keyboard-done") }
            }.onAppear { if !initialized { initialized = true; draft.name = initialName } }.interactiveDismissDisabled(saving)
        }
    }
    private func save() async {
        guard !saving else { return }; failure = nil
        do {
            let input = try draft.validated(id: identity)
            saving = true; defer { saving = false }
            let id = try await store.createManualTitle(input)
            if draft.status == "completed" {
                guard let title = store.title(id), await store.setStatus(title, status: "completed") else { throw APIError.message("Added to your library, but could not complete its watch progress. " + (store.error ?? "Try again.")) }
            }
            dismiss(); onSaved?(id)
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}

struct RetryNotice: View {
    let message: String
    let retry: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text(message).font(.subheadline).foregroundStyle(.secondary); Button("Retry", action: retry).buttonStyle(.bordered) }.frame(maxWidth: .infinity, alignment: .leading).diaryPanel() }
}
