import SwiftUI
import UIKit
import TwilDiaryCore

struct TitleDetailView: View {
    let id: String
    var linkedSeason: Int? = nil
    var focusEpisodes = false
    @State private var pendingScrollTarget: String?
    @State private var contentHeight: CGFloat = 0
    @State private var choosingWatchDate = false
    @State private var didFocusEpisodes = false
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var unwatchedOnly = false
    @State private var chosenSeason: Int?
    @State private var initializedEditor = false
    @State private var configuredSeason: Int?
    @FocusState private var notesFocused: Bool
    @State private var showOverview = false
    @State private var showNotes = false
    /// A star burst from Mark watched each time a new watch is confirmed.
    @State private var markSparks = 0
    /// A perfect 10 deserves its own little burst.
    @State private var perfectSparks = 0
    @State private var showLocation = false
    @State private var copiedLocation: String?
    @State private var notesField = VersionedField(value: "", version: nil)
    @State private var ratingField = VersionedField<Double?>(value: nil, version: nil)
    @State private var showRating = false
    @State private var showInformation = false
    @State private var headerState = CompactHeaderState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resetConfirmation = false
    @State private var card: WatchCard?
    @State private var cardRequest = UUID()
    @State private var cardError: String?
    @AppStorage("episodesGrid") private var episodesGrid = false
    @State private var watchDate = Date.now
    @State private var sliderDraft: Double?
    @State private var selectedEpisode: Episode?
    @State private var sheetEpisode: Episode?
    /// Which way the last swipe in the episode sheet went, so the next episode slides in from that side.
    @State private var episodeForward = true
    @State private var episodeDetails = SavedEpisodeDetailsController()
    @State private var revealedEpisodeIDs = Set<String>()
    @State private var preparingSeason = false
    @State private var seasonRequest = UUID()
    @State private var seasonLoadError: String?
    @State private var criticScores: [MDBListSyncEngine.SourceScore] = []
    /// TMDB's score read for this page when the diary copy has none (Trakt-only titles).
    @State private var fetchedCommunity: Double?
    /// Companies, tags, status and age rating (TMDB), shown once loaded.
    @State private var extras: TitleExtras?
    @State private var confirmTrash = false
    @AppStorage("confirmDeletions") private var confirmDeletions = true
    @Environment(\.dismiss) private var dismissPage
    @State private var newTagText = ""
    var body: some View {
        Group {
            if let title = store.title(id) {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        detailPresentations(title: title, content: ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                header(title, coverStrip: TitleCover.strip(width: geometry.size.width, safeTop: geometry.safeAreaInsets.top))
                                if store.viewingFrozenServerCopy { frozenCopyNotice }
                                progressPanel(title).padding(.top, -8)
                                if let extras { TitleTagsSection(keywords: extras.keywords, kind: title.isSeries ? .tv : .movie) }
                                if title.isSeries { episodeSection(title).id("episodes") }
                                if title.isSeries, let tmdbId = title.tmdbId {
                                    RatingTrendCard(show: tmdbId, season: season, tmdb: tmdbEpisodePoints, current: card?.next?.number)
                                }
                                // Anime characters come from AniList and need no TMDB link; the cast row follows.
                                if title.category.hasPrefix("anime") {
                                    AnimeCharactersRow(title: title.name, year: title.year, movie: !title.isSeries, tmdbID: title.tmdbId,
                                                       seeAll: title.tmdbId.map { .cast(CatalogRoute(kind: title.isSeries ? .tv : .movie, id: $0), title: title.name, anime: true, year: title.year) })
                                }
                                if let tmdbId = title.tmdbId {
                                    let route = CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdbId)
                                    CastAndRelated(route: route, sourceTitle: title.name,
                                                   seeAll: .cast(route, title: title.name, anime: title.category.hasPrefix("anime"), year: title.year))
                                    if let extras { CompaniesSection(route: route, title: title.name, extras: extras, animated: title.category.hasPrefix("anime") || title.genres.contains("Animation")) }
                                    InListsSection(route: route, title: title.name)
                                    RelatedCollectionsSection(route: route, title: title.name, anime: title.category.hasPrefix("anime"), genres: title.genres)
                                }
                            }.padding(.horizontal, 16).padding(.bottom, 32)
                                // The height only matters while the page scrolls itself to notes or files. Tracking it
                                // always rebuilt the whole page each time a lazy episode row first
                                // appeared, which stuttered the first scroll through a season.
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in if pendingScrollTarget != nil { contentHeight = height } }
                                .background(alignment: .top) {
                                    TitleArtworkBackdrop(path: ["again", "night", "severance"].contains(title.id) ? "scene:" + title.id : title.backdrop ?? title.poster, name: title.name, topExtension: geometry.safeAreaInsets.top)
                                }
                        }.scrollClipDisabled().scrollDismissesKeyboard(.interactively).diaryScreenBackground(path: title.backdrop ?? title.poster, name: title.name)
                            .onScrollPhaseChange { _, phase in if phase == .tracking || phase == .interacting { pendingScrollTarget = nil } }
                            .task(id: ScrollFocus(target: pendingScrollTarget, height: contentHeight, notes: showNotes, files: showLocation)) {
                                guard let target = pendingScrollTarget else { return }
                                await Task.yield()
                                guard !Task.isCancelled, pendingScrollTarget == target else { return }
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                                    proxy.scrollTo(target, anchor: target == "notes-editor" ? .center : .top)
                                }
                            }
                            .onChange(of: notesFocused) { _, focused in if focused { pendingScrollTarget = nil } }
                            .toolbar(.visible, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                            .overlay(alignment: .top) { CompactHeaderBackdrop(state: headerState, topInset: geometry.safeAreaInsets.top) }
                            .toolbar {
                                ToolbarItem(placement: .principal) {
                                    CompactTitleNavigation(name: title.name, poster: title.poster, state: headerState)
                                }
                                // One ••• button (owner's design) holds every action; files moved here from the page.
                                ToolbarItem(placement: .topBarTrailing) {
                                    Menu {
                                        Button("Sentiments", systemImage: "info.circle") { showInformation = true }.accessibilityIdentifier("title-information")
                                        Button(title.favorite ? "Remove from Favourites" : "Add to Favourites", systemImage: title.favorite ? "heart.slash" : "heart") {
                                            Task { await store.patch(title, values: ["favorite": !title.favorite]) }
                                        }.disabled(store.writesBlocked).accessibilityIdentifier("title-favorite")
                                        Button(title.queued == true ? "Remove from Queue" : "Add to Queue", systemImage: "text.badge.plus") { Task { await store.patch(title, values: ["queued": title.queued != true]) } }.disabled(store.writesBlocked)
                                        Button("Notes", systemImage: "note.text") { showNotes = true }.accessibilityIdentifier("title-menu-notes")
                                        Button("File locations", systemImage: "folder") { showLocation = true }.accessibilityIdentifier("title-menu-files")
                                        TitleShareItem(name: title.name, kind: title.isSeries ? .tv : .movie, id: title.tmdbId)
                                        Divider()
                                        Button("Move to Trash", systemImage: "trash", role: .destructive) { if confirmDeletions { confirmTrash = true } else { Task { if await store.trash(title) { dismissPage() } } } }
                                            .disabled(store.writesBlocked).accessibilityIdentifier("title-menu-trash")
                                    } label: { TitleMoreButtonLabel() }.accessibilityLabel("More options for " + title.name).accessibilityIdentifier("title-more")
                                }.sharedBackgroundVisibility(.hidden)
                            }
                            .task { if !initializedEditor { initializedEditor = true; watchDate = store.now; notesField = VersionedField(value: title.notes, version: title.version); ratingField = VersionedField(value: title.score, version: title.version) } }
                            .task(id: season) {
                                if configuredSeason != season { configuredSeason = season; sliderDraft = nil }
                                await prepareSeason(title)
                                if focusEpisodes && !didFocusEpisodes && !Task.isCancelled {
                                    await Task.yield()
                                    didFocusEpisodes = true
                                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { proxy.scrollTo("episodes", anchor: .top) }
                                }
                                if !hideSpoilers { await revealSeason(title) }
                            }
                            .task(id: cardRevision(title)) { await loadCard(title) }
                        )
                    }
                }
            } else { ContentUnavailableView("Title unavailable", systemImage: "film") }
        }
    }
    /// Sheets, dialogs and change observers live in their own function so the
    /// type checker handles two shorter modifier chains instead of one very long one.
    private func detailPresentations(title: MediaTitle, content: some View) -> some View {
        content
            // Presented while an episode is chosen; swiping inside changes the episode, not the sheet.
            .sheet(isPresented: Binding(get: { selectedEpisode != nil }, set: { if !$0 { selectedEpisode = nil } })) {
                // The last episode stays while the sheet slides away, instead of an empty sheet.
                if let episode = selectedEpisode ?? sheetEpisode { episodeInformation(title, episode: episode) }
            }
            .onChange(of: selectedEpisode) { _, episode in if let episode { sheetEpisode = episode } }
            .sheet(isPresented: $choosingWatchDate) {
                NavigationStack {
                    EdgeToEdgeScroll { DatePicker("Watch date", selection: $watchDate, in: ...store.now, displayedComponents: .date).datePickerStyle(.graphical).padding(16) }
                        .navigationTitle("Watch date").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingWatchDate = false } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showNotes) { notesSheet(title) }
            .sheet(isPresented: $showLocation) { locationsSheet(title) }
            .sheet(isPresented: $showInformation) {
                CommunityInformationSheet(name: title.name, artwork: title.backdrop ?? title.poster, identity: CommunityIdentity(kind: title.isSeries ? .tv : .movie, id: title.tmdbId))
            }
            .onChange(of: hideSpoilers) { _, hidden in if !hidden { Task { await revealSeason(title) } } }
            .onChange(of: store.sessionRevision) { _, _ in episodeDetails.reset(); revealedEpisodeIDs = []; selectedEpisode = nil }
            .task(id: title.id) {
                guard let tmdbId = title.tmdbId else { criticScores = []; extras = nil; return }
                let route = CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdbId)
                extras = TitleExtrasCache.cached(route)
                if let loaded = try? await TitleExtrasCache.load(store: store, route: route) { extras = loaded }
                criticScores = await CriticScores.load(store: store, tmdbId: tmdbId, isSeries: title.isSeries)
                // No score in the diary or from MDBList: ask TMDB, so the community circle and box still show.
                if communityAverage(title) == nil, fetchedCommunity == nil {
                    if let token = TMDBDirect.token(store) { fetchedCommunity = await TMDBDirect.community(route, token: token) }
                    else if let browse = try? await store.browse(route), let score = browse.details.communityScore, score > 0 { fetchedCommunity = score }
                }
            }
            .onChange(of: title.version) { _, _ in
                guard initializedEditor else { return }
                notesField.observe(.init(value: title.notes, version: title.version))
                ratingField.observe(.init(value: title.score, version: title.version))
            }
            .confirmationDialog("Move \(title.name) to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { Task { if await store.trash(title) { dismissPage() } } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It leaves your library. You can restore it from Trash.")
            }
            .confirmationDialog(title.isSeries ? "Reset Season \(season) to Planned? Only this season’s watches will be removed. Earlier seasons stay saved. Undo is available." : "Reset progress to 0? Logged watches will be removed, with Undo available.", isPresented: $resetConfirmation, titleVisibility: .visible) {
                Button("Reset to Planned", role: .destructive) { Task { await store.setSeasonStatus(title, season: season, status: "planned", watchedAt: watchInstant); await loadCard(title) } }
            }
    }
    /// "My Note": Cancel discards the draft, Save keeps it and closes. A dirty draft can't be
    /// swiped away by accident.
    private func notesSheet(_ title: MediaTitle) -> some View {
        let count = notesField.draft.utf16.count
        return NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.name).font(.system(size: 15)).foregroundStyle(.secondary)
                DisclosureGroup("Collections") {
                    InlineFlowLayout {
                        ForEach(title.tags ?? [], id: \.self) { tag in
                            Button { Task { await store.patch(title, values: ["tags": (title.tags ?? []).filter { $0 != tag }]) } } label: {
                                Label(tag, systemImage: "xmark.circle").font(.caption)
                            }.buttonStyle(.plain).disabled(store.writesBlocked)
                        }
                    }
                    HStack {
                        TextField("Add collection tag", text: $newTagText).accessibilityIdentifier("title-new-tag")
                        Button("Add") {
                            let value = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty, value.utf16.count <= 60, !(title.tags ?? []).contains(value), (title.tags ?? []).count < 20 else { return }
                            Task { if await store.patch(title, values: ["tags": (title.tags ?? []) + [value]]) { newTagText = "" } }
                        }.disabled(store.writesBlocked || newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.font(.subheadline).padding(.horizontal, 14)
                NotesEditor(text: $notesField.draft, accent: theme.accent)
                if notesField.conflict != nil {
                    fieldConflict("Notes changed elsewhere.", useSaved: { notesField.useSaved() }, keepDraft: { notesField.keepDraft() })
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .navigationTitle("My Note").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { notesField = VersionedField(value: title.notes, version: title.version); showNotes = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await saveNotes(); if !notesField.isDirty { showNotes = false } } }
                            .accessibilityLabel("Save notes")
                            .disabled(store.writesBlocked || !notesField.isDirty || notesField.submission == nil || count > 20_000)
                    }
                }
        // Notes and collections expand together on smaller devices.
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).interactiveDismissDisabled(notesField.isDirty)
    }
    private func locationsSheet(_ title: MediaTitle) -> some View {
        NavigationStack {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 10) {
                    Text(serverLabel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityIdentifier("title-locations")
                    ForEach(locations) { location in locationRow(location, title: title) }
                    // Moved here from the page (owner's request): the Jellyfin match when no drive files are mapped.
                    if locations.isEmpty { JellyfinPresenceRow(tmdb: title.tmdbId, movie: !title.isSeries) }
                    if locations.isEmpty { Text("No mapped files yet. A Jellyfin sync in Files & drives adds matching locations here.").font(.system(size: 13)).foregroundStyle(.secondary) }
                    // The sheet has its own stack; Files opens on the page underneath.
                    Button("All files & drives →") { showLocation = false; router.paths[router.selectedTab, default: NavigationPath()].append(AppDestination.files) }
                        .font(.system(size: 14, weight: .semibold)).frame(minHeight: 48).accessibilityIdentifier("title-all-files")
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }.navigationTitle("File locations").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLocation = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private struct ScrollFocus: Equatable {
        let target: String?
        let height: CGFloat
        let notes: Bool
        let files: Bool
    }
    private func locationRow(_ location: FileLocation, title: MediaTitle) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                if location.deviceId == "jellyfin" { BrandLogo(service: .jellyfin, size: 16) }
                Text(location.driveLetter + " · " + (location.season.map { "Season \($0)" } ?? "Title folder")).font(.system(size: 13.6, weight: .semibold))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().frame(width: 5, height: 5)
                    Text(location.evidence == "present" ? "Available" : location.evidence == "unavailable" ? "Drive offline" : location.evidence == "missing" ? "Not available" : "Not confirmed")
                }.font(.system(size: 12.8)).foregroundStyle(Color(webHex: location.evidence == "present" ? "#9edbc4" : "#e7ca90"))
            }
            Text(location.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(location.fileCount.counted("file", "files") + " · \(location.deviceName)").font(.system(size: 12.8)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { UIPasteboard.general.string = location.path; copiedLocation = location.id } label: { DiaryIcon(name: copiedLocation == location.id ? "check" : "copy", size: 16).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Copy path for " + title.name).accessibilityValue(copiedLocation == location.id ? "Copied" : "Copy")
                    .accessibilityIdentifier("title-copy-location-" + location.id)
            }
        }.padding(.horizontal, 15).padding(.top, 15).padding(.bottom, 7)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(webHex: "#ffffff0d")))
    }
    private func header(_ title: MediaTitle, coverStrip: CGFloat) -> some View {
        TitleHero(name: title.name, poster: title.poster, backdrop: title.backdrop, genres: title.genres, year: title.year, category: title.categoryName, runtime: title.runtimeMinutes, series: title.isSeries, summary: title.overview, expanded: $showOverview, extras: extras, ratingsBelow: true, coverStrip: coverStrip, onNameScrolled: { headerState.update($0) }) {
            RatingBoxes(scores: criticScores, tmdbFallback: title.communityScore ?? fetchedCommunity)
        }
    }
    /// The community average for the ring: Trakt's when MDBList has it, otherwise TMDB's.
    private func communityAverage(_ title: MediaTitle) -> Double? {
        if let trakt = criticScores.first(where: { RatingsStrip<EmptyView>.canonical($0.source) == "trakt" }), let value = trakt.value ?? trakt.score, value > 0 {
            return value > 10 ? value / 10 : value
        }
        return title.communityScore.flatMap { $0 > 0 ? $0 : nil } ?? fetchedCommunity
    }
    private var tmdbEpisodePoints: [EpisodeRatingPoint] {
        episodes.compactMap { episode in
            (episodeDetails.episodes[episode.id]?.communityScore ?? episode.communityScore).map { EpisodeRatingPoint(episode: episode.number, score: $0) }
        }
    }
    private func progressPanel(_ title: MediaTitle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    Button(title.queued == true ? "Remove from Queue" : "Queue") { Task { await store.patch(title, values: ["queued": title.queued != true]) } }
                    ForEach(["planned", "watching", "completed", "dropped"], id: \.self) { status in
                    Button(status.capitalized) {
                        if status == "planned" && store.seasonStatus(title, season: season) != "planned" { resetConfirmation = true }
                        else { Task { await store.setSeasonStatus(title, season: season, status: status, watchedAt: watchInstant); await loadCard(title) } }
                    }
                    }
                    Divider()
                    Button("Watch date…", systemImage: "calendar") { choosingWatchDate = true }
                } label: {
                    HStack(spacing: 8) {
                        if store.seasonStatus(title, season: season) == "watching" { Image(systemName: "play.fill").font(.system(size: 12)) }
                        else { Circle().fill(store.seasonStatus(title, season: season) == "completed" ? Color.mint : Color.secondary).frame(width: 8, height: 8) }
                        Text(store.seasonStatus(title, season: season).capitalized).font(.system(size: 15, weight: .bold))
                        DiaryIcon(name: "chevron-down", size: 15)
                    }.foregroundStyle(HomeStyle.chipText).padding(.horizontal, 18).frame(minWidth: 156, minHeight: 44)
                        .background(HomeStyle.chip, in: Capsule())
                }.buttonStyle(.plain).disabled(store.writesBlocked).accessibilityIdentifier("title-watch-status")
                Spacer(minLength: 0)
                Text(title.isSeries ? remaining(title).map { "\(DiaryDate.duration($0)) left" } ?? "Time unknown" : movieViewings.isEmpty ? title.runtimeMinutes.map { "\(DiaryDate.duration($0)) left" } ?? "Movie" : "Movie")
                    .font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.trailing)
            }.padding(.bottom, 22)
            // A cached card paints on the first frame instead of a 290 pt placeholder swap.
            if let card = card ?? store.cachedCard(title, season: title.isSeries ? season : nil) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title.isSeries ? "Episode \(displayedWatched)" : "\(movieViewings.count)").font(.system(size: 22, weight: .bold)).foregroundStyle(HomeStyle.primary)
                    Text(title.isSeries ? "of \(card.progress.total)" : movieViewings.count == 1 ? "view logged" : "views logged").font(.system(size: 15, weight: .medium)).foregroundStyle(HomeStyle.secondary)
                    Spacer(minLength: 0); Text("\(displayedPercent)%").foregroundStyle(.tint).font(.system(size: 22, weight: .bold))
                }.frame(minHeight: 29).padding(.bottom, 14)
                if title.isSeries {
                    episodeSlider(title, card: card)
                } else {
                    ProgressView(value: Double(percent), total: 100)
                        .accessibilityIdentifier("movie-progress")
                        .frame(height: 44)
                        .overlay {
                            EpisodeRangeInput(value: Double(percent) / 100, maximum: 1, enabled: !store.busy && store.canMutate, label: "Movie watched", valueText: percent > 0 ? "Watched" : "Not watched", identifier: "movie-watch-input", scope: title.id + ":movie", onChange: { _ in }, onCommit: { value in
                                Task {
                                    if value < 1, let previous = card.previous { await store.removeLatest(title, expected: previous) }
                                    else if value >= 1, card.progress.watched == 0 { await store.recordViewing(title, watchedAt: watchInstant) }
                                    await loadCard(title)
                                }
                            }, onCancel: {})
                        }
                }
                if let next = card.next, let episode = episodes.first(where: { $0.id == next.id }) { nextPreview(title, episode: episode).padding(.top, 8).padding(.bottom, 12) }
                else if title.isSeries { Text(seasonCanEdit(title) ? "You’re caught up with available episodes." : "Load the season to see what’s next.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12) }
                // Your rating, the community's, then the main action on one line.
                HStack(spacing: 10) {
                    RatingCircles(mine: title.score, community: communityAverage(title), onRate: { openRating(title) }, onCommunity: { showInformation = true })
                    Button { Task {
                        var recorded = false
                        if title.isSeries, let next = card.next, let episode = episodes.first(where: { $0.id == next.id }) { recorded = await store.recordViewing(title, episode: episode, watchedAt: watchInstant) }
                        else if !title.isSeries { recorded = await store.recordViewing(title, rewatch: !movieViewings.isEmpty, watchedAt: watchInstant) }
                        if recorded { markSparks += 1 }
                        await loadCard(title)
                    } } label: {
                        Label(title.isSeries ? card.next.map { "Mark E\($0.number) watched" } ?? "Season caught up" : movieViewings.isEmpty ? "Log a watch" : "Rewatch", systemImage: !title.isSeries && !movieViewings.isEmpty ? "arrow.counterclockwise" : "checkmark")
                            .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(minHeight: 48)
                    }.buttonStyle(.diaryPrimary).disabled(store.writesBlocked || store.viewingFrozenServerCopy || (title.isSeries && card.next == nil)).starBurst(trigger: markSparks)
                        .sensoryFeedback(.success, trigger: markSparks).accessibilityIdentifier("mark-title-watch")
                }.padding(.top, 4)
                if DiaryDate.day(watchDate) != DiaryDate.day(store.now) {
                    Button { choosingWatchDate = true } label: {
                        HStack(spacing: 6) { DiaryIcon(name: "calendar-days", size: 14).foregroundStyle(theme.accent); Text("Logging as " + watchDate.formatted(.dateTime.day().month(.abbreviated).year())) }
                            .font(.system(size: 13)).foregroundStyle(Color(webHex: "#c5c0cf")).frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.plain).accessibilityIdentifier("watch-date")
                }
                if showRating { ratingPanel(title).padding(.top, 10) }
            } else if let cardError {
                VStack(alignment: .leading, spacing: 12) {
                    if title.isSeries {
                        let progress = store.seasonProgress(title, season: season)
                        Text("\(progress.watched) of " + progress.total.counted("episode", "episodes") + " watched").font(.headline)
                        EpisodeProgressTrack(segments: EpisodeSegment.make(episodes: episodes, total: progress.total, watched: watched, nextID: nil), season: season).frame(height: 44)
                    }
                    RetryNotice(message: cardError) { Task { await loadCard(title) } }
                }.padding(.vertical, 12)
            } else { DiaryLoadingPlaceholder(height: title.isSeries ? 290 : 210, label: "Loading watch progress") }
        }.padding(19)
            // Design: a 28 pt card in rgba(18 16 26 / .58) with a white 8 % hairline.
            .background(Color(red: 18 / 255, green: 16 / 255, blue: 26 / 255).opacity(0.58), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.08), lineWidth: HomeStyle.hairline))
            .onAppear { if card == nil, let cached = store.cachedCard(title, season: title.isSeries ? season : nil) { card = cached } }
    }
    private func episodeSlider(_ title: MediaTitle, card: WatchCard) -> some View {
        let states = sliderDraft.map { draft in (0..<max(0, card.progress.total)).map { $0 < Int(draft) ? EpisodeSegment.watched : .unwatched } }
            ?? EpisodeSegment.make(episodes: episodes, total: card.progress.total, watched: watched, nextID: card.next?.id)
        return ZStack {
            EpisodeProgressTrack(segments: states, season: season).accessibilityHidden(true).allowsHitTesting(false)
            if !episodes.isEmpty {
                EpisodeRangeInput(value: sliderDraft ?? Double(card.progress.watched), maximum: episodes.count, enabled: !store.busy && store.canMutate && seasonCanEdit(title), label: "Season \(season) episodes watched", valueText: "\(displayedWatched) of \(card.progress.total) episodes watched", identifier: "episode-progress", scope: title.id + ":season:\(season)", onChange: { sliderDraft = $0 }, onCommit: { count in
                    Task { await store.setSeasonProgress(title, season: season, count: Int(count), watchedAt: watchInstant); sliderDraft = nil; await loadCard(title) }
                }, onCancel: { sliderDraft = nil })
            }
        }.frame(height: 44)
    }
    private func nextPreview(_ title: MediaTitle, episode: Episode) -> some View {
        Button { toggleEpisode(title, episode: episode) } label: {
            HStack(spacing: 12) {
                // Design: 100 × 66 still (radius 12), "UP NEXT" 12 pt bold, the name 15 pt semibold, runtime top right.
                episodeArtwork(episode).frame(width: 100, height: 66).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) { Text("UP NEXT").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent); Text("\(episode.number) · \(episodeName(episode))").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(3).multilineTextAlignment(.leading) }
                Spacer(minLength: 0)
            }.overlay(alignment: .topTrailing) { if let runtime = title.runtimeMinutes { Text("\(runtime) min").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary) } }
                .padding(.vertical, 16).padding(.horizontal, 10).frame(minHeight: 98).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details")
    }
    /// Episodes: heading with the count and season, All / Unwatched beside a list–grid switch,
    /// three episodes around what's next (a sideways row of cards in grid), then the full page.
    private func episodeSection(_ title: MediaTitle) -> some View {
        let seen = watched
        let dates = EpisodeWatchDates.latest(store, titleID: id)
        let nextID = card?.next?.id ?? episodes.first(where: { !seen.contains($0.id) && hasAired($0) })?.id
        let shown = inlineEpisodes(nextID: nextID, watched: seen)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Episodes").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                if !episodes.isEmpty {
                    Text(episodes.count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                        .padding(.horizontal, 10).frame(height: 28).background(HomeStyle.round, in: Capsule())
                        .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                }
                Spacer(minLength: 0)
                seasonMenu
            }
            HStack(spacing: 8) {
                episodeFilter("All episodes", on: !unwatchedOnly) { unwatchedOnly = false }
                episodeFilter("Unwatched", on: unwatchedOnly) { unwatchedOnly = true }
                Spacer(minLength: 0)
                Button { episodesGrid.toggle() } label: {
                    // Design: an 87 x 43 pill (#17171d, #26262e hairline) with a 40 x 36 #2a2440 knob.
                    HStack(spacing: 0) {
                        DiaryIcon(name: "layout-grid", size: 17).foregroundStyle(episodesGrid ? HomeStyle.chipText : HomeStyle.secondary)
                            .frame(width: 40, height: 36).background(episodesGrid ? HomeStyle.chip : .clear, in: Capsule())
                        DiaryIcon(name: "list", size: 17).foregroundStyle(episodesGrid ? HomeStyle.secondary : HomeStyle.chipText)
                            .frame(width: 40, height: 36).background(episodesGrid ? .clear : HomeStyle.chip, in: Capsule())
                    }.padding(3).background(HomeStyle.round, in: Capsule())
                        .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Show episodes as " + (episodesGrid ? "list" : "grid")).accessibilityValue(episodesGrid ? "Grid" : "List").accessibilityIdentifier("episodes-layout")
            }
            if !seasonCanEdit(title) { Button("Load season episodes") { Task { await store.loadSeason(title, number: season); await loadCard(title) } }.buttonStyle(.glass).disabled(store.writesBlocked) }
            if let seasonLoadError { RetryNotice(message: seasonLoadError) { Task { await prepareSeason(title, force: true) } } }
            if let episodeError = episodeDetails.error(for: season) { Text(episodeError).font(.caption).foregroundStyle(.secondary); Button("Retry episode details") { Task { await revealSeason(title) } } }
            if episodesGrid {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(shown) { episode in
                            EpisodeGridCard(number: episode.number, name: episodeName(episode), artwork: episodeArtworkPath(episode, title: title), hidden: isHidden(episode),
                                            state: rowState(episode, watched: seen, dates: dates, nextID: nextID), airedOn: episode.airedOn, runtime: title.runtimeMinutes,
                                            score: episodeScore(episode), onOpen: { toggleEpisode(title, episode: episode) }, onToggle: { toggleWatched(title, episode: episode) })
                                .frame(width: 260)
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
            } else {
                VStack(spacing: 9) {
                    ForEach(shown) { episode in
                        EpisodeCardRow(number: episode.number, name: episodeName(episode), artwork: episodeArtworkPath(episode, title: title), hidden: isHidden(episode),
                                       state: rowState(episode, watched: seen, dates: dates, nextID: nextID), score: episodeScore(episode),
                                       canToggle: !store.writesBlocked && (seen.contains(episode.id) || hasAired(episode)),
                                       onOpen: { toggleEpisode(title, episode: episode) }, onToggle: { toggleWatched(title, episode: episode) })
                    }
                }
            }
            if episodes.isEmpty { Text("No episode metadata yet").font(.subheadline).foregroundStyle(.secondary) }
            else if unwatchedOnly && episodes.allSatisfy({ seen.contains($0.id) }) { Text("Every episode in this season is watched.").font(.subheadline).foregroundStyle(.secondary) }
            if !episodes.isEmpty {
                NavigationLink(value: ShowPageRoute.episodes(titleID: id, season: season)) {
                    HStack(spacing: 6) { Text("Show all \(episodes.count) episodes"); DiaryIcon(name: "chevron-right", size: 14) }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(HomeStyle.round, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.shortcutBorder, lineWidth: HomeStyle.hairline))
                }.buttonStyle(.springPress).accessibilityIdentifier("title-all-episodes")
            }
            if let pending = store.pendingSeasonAdjustments[title.id + ":" + String(season)] { Button("Retry progress to episode \(pending.count)") { Task { await store.setSeasonProgress(title, season: season, count: pending.count, watchedAt: watchInstant); await loadCard(title) } }.disabled(store.writesBlocked) }
        }
    }
    /// Three around what's next (one before, two from it); Unwatched shows the next three.
    /// A grid row shows more, as it scrolls sideways.
    private func inlineEpisodes(nextID: String?, watched seen: Set<String>) -> [Episode] {
        let pool = unwatchedOnly ? episodes.filter { !seen.contains($0.id) } : episodes
        let focus = nextID.flatMap { id in pool.firstIndex { $0.id == id } } ?? (unwatchedOnly ? 0 : nil)
        let window = EpisodeWindow(count: pool.count, focus: focus, leading: unwatchedOnly ? 0 : 1, trailing: episodesGrid ? 8 : unwatchedOnly ? 2 : 1)
        return Array(pool[window.shown])
    }
    private func rowState(_ episode: Episode, watched seen: Set<String>, dates: [String: Date], nextID: String?) -> EpisodeRowState {
        if seen.contains(episode.id) { return .watched(dates[episode.id]) }
        if episode.id == nextID { return .next }
        return hasAired(episode) ? .notWatched : .notAired
    }
    private func episodeArtworkPath(_ episode: Episode, title: MediaTitle) -> String? { episodeDetails.episodes[episode.id]?.artwork ?? episode.still ?? title.backdrop }
    private func episodeScore(_ episode: Episode) -> Double? { episodeDetails.episodes[episode.id]?.communityScore ?? episode.communityScore }
    private func toggleWatched(_ title: MediaTitle, episode: Episode) {
        Task {
            if watched.contains(episode.id) { await store.unwatchEpisode(episode) }
            else { await store.recordViewing(title, episode: episode, watchedAt: watchInstant) }
            await loadCard(title)
        }
    }
    private var seasonMenu: some View {
        Menu {
            Picker("Season", selection: Binding(get: { season }, set: { chosenSeason = $0 })) {
                ForEach(seasonNumbers, id: \.self) { number in Text(number == 0 ? "Specials" : "Season \(number)").tag(number) }
            }
        } label: {
            // A pill like the filters; the chevron only shows when there is another season to pick.
            HStack(spacing: 8) {
                Text(season == 0 ? "Specials" : "Season \(season)").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                if seasonNumbers.count > 1 { DiaryIcon(name: "chevron-down", size: 13).foregroundStyle(HomeStyle.secondary) }
            }.padding(.horizontal, 18).frame(height: 44)
                .background(HomeStyle.round, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                .frame(minHeight: 44).contentShape(Capsule())
        }.disabled(seasonNumbers.count < 2).accessibilityLabel("Season").accessibilityValue(season == 0 ? "Specials" : "Season \(season)").accessibilityIdentifier("title-season")
    }
    private func episodeFilter(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Design: 44 pt pills, 14 pt semibold; the chosen one #0b0b10 on the accent.
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#0b0b10") : HomeStyle.soft)
                .padding(.horizontal, 20).frame(height: 44)
                .background(on ? theme.accent : HomeStyle.round, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("episodes-filter-" + (name == "Unwatched" ? "unwatched" : "all"))
    }
    @ViewBuilder private func episodeArtwork(_ episode: Episode) -> some View {
        if isHidden(episode) { Color(webHex: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 23).foregroundStyle(.secondary) } }
        else { Artwork(path: episodeDetails.episodes[episode.id]?.artwork ?? episode.still ?? store.title(id)?.backdrop, title: String(episode.number)) }
    }
    private func isHidden(_ episode: Episode) -> Bool { hideSpoilers && !watched.contains(episode.id) && !revealedEpisodeIDs.contains(episode.id) }
    private func episodeName(_ episode: Episode) -> String {
        if isHidden(episode) { return "A story for later" }
        let name = episodeDetails.episodes[episode.id]?.name ?? episode.name
        return name.isEmpty ? "Episode \(episode.number)" : name
    }
    private func episodeSummary(_ episode: Episode) -> String { let text = episodeDetails.episodes[episode.id]?.overview ?? episode.overview; return text.isEmpty ? "No episode summary available." : text }
    private func hasAired(_ episode: Episode) -> Bool { episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day(store.now) } ?? false }
    private func seasonCanEdit(_ title: MediaTitle) -> Bool {
        guard !episodes.isEmpty else { return false }
        guard let manifest = title.seasons?.first(where: { $0.number == season }) else { return title.tmdbId == nil }
        return manifest.expectedEpisodes.map { $0 == episodes.count } ?? (manifest.metadataLoadedAt != nil)
    }
    private func toggleEpisode(_ title: MediaTitle, episode: Episode) {
        // Revealing a spoiler changes only the fixed-size thumbnail and caption.
        // Long synopses live in a sheet, never inside a scrolling grid row.
        if isHidden(episode) { revealedEpisodeIDs.insert(episode.id) }
        else { selectedEpisode = episode }
        if episodeDetails.episodes[episode.id] == nil { Task { await revealSeason(title) } }
    }
    private func episodeInformation(_ title: MediaTitle, episode: Episode) -> some View {
        EpisodeInfoSheet(title: title, season: season, episodes: episodes, episode: episode,
                         page: { item in
                             .init(name: episodeName(item), summary: episodeSummary(item), artwork: episodeArtworkPath(item, title: title),
                                   hidden: isHidden(item), tmdbScore: episodeScore(item),
                                   traktScore: title.tmdbId.flatMap { TraktTitleReads.cachedRatings(show: $0, season: season)[item.number] },
                                   watched: watched.contains(item.id))
                         },
                         onToggleWatched: { toggleWatched(title, episode: $0) },
                         onNeighbour: { showNeighbour(of: episode, forward: $0, title: title) },
                         onNote: { selectedEpisode = nil; showNotes = true },
                         onClose: { selectedEpisode = nil })
            .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    /// The next or previous episode of this season in the open sheet. Swiping to it is a deliberate
    /// choice, so a spoiler-hidden one is revealed, as tapping it would.
    private func showNeighbour(of episode: Episode, forward: Bool, title: MediaTitle) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), episodes.indices.contains(index + (forward ? 1 : -1)) else { return }
        let next = episodes[index + (forward ? 1 : -1)]
        revealedEpisodeIDs.insert(next.id)
        if episodeDetails.episodes[next.id] == nil { Task { await revealSeason(title) } }
        episodeForward = forward
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) { selectedEpisode = next }
    }
    private func prepareSeason(_ title: MediaTitle, force: Bool = false) async {
        if store.isPreview && !store.canMutate { return }
        let request = UUID(), selected = season
        seasonRequest = request; seasonLoadError = nil
        guard force || SeasonMetadata.needsPreparation(title: title, workspace: scope, season: selected, now: store.now) else { preparingSeason = false; return }
        preparingSeason = true; defer { if seasonRequest == request { preparingSeason = false } }
        do { try await store.prepareSavedSeason(title, number: selected, force: force) }
        catch is CancellationError { }
        catch { if seasonRequest == request, selected == season, !Task.isCancelled { seasonLoadError = error.localizedDescription } }
    }
    private func revealSeason(_ title: MediaTitle) async {
        let selected = season
        await episodeDetails.load(selected) { try await store.revealedSeason(title, number: selected) }
    }
    private var movieViewings: [WatchEvent] { scope.activeEvents.filter { $0.titleId == id && $0.episodeId == nil }.sorted { ($0.recordedAt, $0.id) > ($1.recordedAt, $1.id) } }
    private var displayedWatched: Int { sliderDraft.map(Int.init) ?? card?.progress.watched ?? 0 }
    private var watchInstant: Date { let calendar = DiaryDate.calendar(); return calendar.isDate(watchDate, inSameDayAs: store.now) ? store.now : calendar.date(bySettingHour: 12, minute: 0, second: 0, of: watchDate) ?? watchDate }
    private var displayedPercent: Int { guard let total = card?.progress.total, total > 0 else { return 0 }; return Int((Double(displayedWatched) / Double(total) * 100).rounded()) }
    /// Your old server copy is on screen while a service holds the diary: watches and ratings are
    /// read-only here, with one tap back to the diary that takes them.
    private var frozenCopyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.frozenCopyMessage).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let record = store.serverRecord {
                    Button("Show my diary from \(record.name)") { store.diarySource = record.rawValue }
                        .font(.footnote.weight(.semibold))
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain).accessibilityIdentifier("title-frozen-copy")
    }
    private func ratingPanel(_ title: MediaTitle) -> some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 7) { DiaryIcon(name: "star", size: 16); Text("Your rating") }.foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(ratingField.draft.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "Not rated").monospacedDigit()
                    .contentTransition(.numericText(value: ratingField.draft ?? 0)).animation(Motion.press, value: ratingField.draft)
                    .starBurst(trigger: perfectSparks)
                if ratingField.draft != nil { Button("Clear") { Task { await saveRating(value: nil) } }.accessibilityLabel("Clear your rating") }
                else { Button("Rate 7") { Task { await saveRating(value: 7) } } }
            }.font(.system(size: 14)).frame(minHeight: 32)
            HStack(spacing: 10) {
                Text("1").foregroundStyle(.secondary)
                Slider(value: Binding(get: { ratingField.draft ?? 7 }, set: { ratingField.draft = $0 }), in: 1...10, step: 1) { editing in
                    if !editing { Task { await saveRating(value: ratingField.draft) } }
                }.sensoryFeedback(.selection, trigger: ratingField.draft).accessibilityLabel("Your rating out of 10").accessibilityIdentifier("title-rating-slider")
                Text("10").foregroundStyle(.secondary)
            }.font(.system(size: 12))
            if ratingField.conflict != nil {
                fieldConflict("Your rating changed elsewhere.", useSaved: { ratingField.useSaved() }, keepDraft: { ratingField.keepDraft() })
            }
            if ratingField.isDirty && ratingField.submission != nil {
                Button("Save rating") { Task { await saveRating(value: ratingField.draft) } }
            }
        }.disabled(store.writesBlocked || !store.canMutate || store.viewingFrozenServerCopy).accessibilityElement(children: .contain).accessibilityIdentifier("title-rating-panel")
    }
    private func saveRating(value: Double?) async {
        if value == 10 { perfectSparks += 1 }
        // Whole numbers only, everywhere: Trakt, Simkl and MDBList keep 1–10 whole ratings (a half
        // star on a 5-star scale is one whole point), so the diary and every service always agree.
        ratingField.draft = value.map { min(10, max(1, $0.rounded())) }
        guard let current = store.title(id) else { return }
        ratingField.observe(.init(value: current.score, version: current.version))
        guard let submitted = ratingField.submission else { return }
        let acknowledged = await store.patch(current, values: ["score": submitted.value as Any? ?? NSNull()], expectedVersion: submitted.version)
        guard let saved = store.title(id) else { return }
        let snapshot = VersionedField<Double?>.Snapshot(value: saved.score, version: saved.version)
        if acknowledged { ratingField.acknowledge(submitted, latest: snapshot) }
        else { ratingField.observe(snapshot) }
    }
    private func openRating(_ title: MediaTitle) {
        ratingField.observe(.init(value: title.score, version: title.version))
        showRating.toggle()
    }
    private func saveNotes() async {
        guard let current = store.title(id), notesField.draft.utf16.count <= 20_000 else { return }
        notesField.observe(.init(value: current.notes, version: current.version))
        guard let submitted = notesField.submission else { return }
        let acknowledged = await store.patch(current, values: ["notes": submitted.value], expectedVersion: submitted.version)
        guard let saved = store.title(id) else { return }
        let snapshot = VersionedField<String>.Snapshot(value: saved.notes, version: saved.version)
        if acknowledged { notesField.acknowledge(submitted, latest: snapshot) }
        else { notesField.observe(snapshot) }
    }
    private func fieldConflict(_ message: String, useSaved: @escaping () -> Void, keepDraft: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message + " Your draft is kept. Choose which version to use before saving.").font(.footnote).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { Button("Use saved", action: useSaved); Button("Keep my draft", action: keepDraft) }
                VStack(alignment: .leading) { Button("Use saved", action: useSaved); Button("Keep my draft", action: keepDraft) }
            }.buttonStyle(.glass).buttonBorderShape(.capsule)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private struct CardRevision: Hashable {
        let season: Int
        let events: [WatchEvent]
        let episodes: [Episode]
        let seasons: [Season]
    }
    /// This title's rows only. `season` is read many times per body pass; it no
    /// longer scans every episode and watch in the diary each time.
    private var scope: Workspace { store.titleScope(id) }
    private var seasonNumbers: [Int] { EpisodeSelection.seasons(in: scope, titleID: id) }
    private var season: Int { chosenSeason ?? EpisodeSelection.preferredSeason(in: scope, titleID: id, today: DiaryDate.day(store.now), linkedSeason: linkedSeason) }
    private func cardRevision(_ title: MediaTitle) -> CardRevision {
        CardRevision(season: season, events: scope.events.filter { $0.titleId == id }, episodes: episodes, seasons: title.seasons ?? [])
    }
    private var episodes: [Episode] { store.episodesForSeason(id, season: season) }
    private var watched: Set<String> { store.watchedEpisodeIDs(id) }
    private var locations: [FileLocation] { scope.locations.filter { $0.titleId == id } }
    private var serverLabel: String { ServerAvailability.label(locations) }
    private var percent: Int { guard let card, card.progress.total > 0 else { return 0 }; return Int((Double(card.progress.watched) / Double(card.progress.total) * 100).rounded()) }
    private func remaining(_ title: MediaTitle) -> Int? { title.isSeries ? store.seasonProgress(title, season: season).remainingMinutes : title.runtimeMinutes.map { card?.progress.watched == 1 ? 0 : $0 } }
    private func loadCard(_ title: MediaTitle) async {
        let request = UUID(), requestedSeason = season
        cardRequest = request
        cardError = nil
        if let cached = store.cachedCard(title, season: title.isSeries ? requestedSeason : nil) { card = cached }
        else if title.isSeries && card?.season?.number != requestedSeason { card = nil }
        do {
            let loaded = try await store.card(title, season: title.isSeries ? requestedSeason : nil)
            guard cardRequest == request, requestedSeason == season, !Task.isCancelled else { return }
            card = loaded
        } catch is CancellationError { }
        catch { if cardRequest == request, !Task.isCancelled { cardError = error.localizedDescription } }
    }
}

/// The Notes sheet's editor. It keeps its own focus: a page's FocusState does not reach
/// into a sheet, so the page could never show this Done button.
/// The notes text box with its count; also used by Glance's TitleNotesSheet.
struct NotesEditor: View {
    @Binding var text: String
    let accent: Color
    @FocusState private var focused: Bool
    var body: some View {
        let count = text.utf16.count
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $text).scrollContentBackground(.hidden).padding(10).frame(height: 150)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text("Add your personal note…").foregroundStyle(.tertiary).padding(.horizontal, 15).padding(.vertical, 18).allowsHitTesting(false) }
                }
                .focused($focused).accessibilityIdentifier("title-notes").accessibilityLabel("Title notes")
            HStack {
                if count > 20_000 { Text("Keep notes within 20,000 characters.").foregroundStyle(.orange) }
                Spacer(minLength: 0)
                Text("\(count.formatted())/20,000").monospacedDigit().foregroundStyle(.secondary)
                if focused {
                    Button("Done") { focused = false }.font(.system(size: 15, weight: .semibold)).tint(accent)
                        .frame(minHeight: 44).padding(.leading, 8).accessibilityIdentifier("notes-keyboard-done")
                }
            }.font(.caption)
        }
    }
}
