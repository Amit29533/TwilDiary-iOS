import SwiftUI
import UIKit
import TwilDiaryCore

struct TitleDetailView: View {
    let id: String
    var linkedSeason: Int? = nil
    var focusEpisodes = false
    var focusNotes = false
    @State private var didFocusNotes = false
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
    @State private var showAllEpisodes = false
    @AppStorage("episodesGrid") private var episodesGrid = false
    @State private var watchDate = Date.now
    @State private var showDate = false
    @State private var sliderDraft: Double?
    @State private var selectedEpisode: Episode?
    @State private var episodeSheetHeight: CGFloat = 420
    @State private var sheetEpisode: Episode?
    /// Which way the last swipe in the episode sheet went, so the next episode slides in from that side.
    @State private var episodeForward = true
    @State private var episodeLimit = 40
    @State private var episodeDetails = SavedEpisodeDetailsController()
    @State private var revealedEpisodeIDs = Set<String>()
    @State private var preparingSeason = false
    @State private var seasonRequest = UUID()
    @State private var seasonLoadError: String?
    var body: some View {
        Group {
            if let title = store.title(id) {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        detailPresentations(title: title, content: ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                header(title)
                                progressPanel(title).padding(.top, -8)
                                if !locations.isEmpty { driveRow(title) }
                                if title.isSeries { episodeSection(title).id("episodes") }
                                // Anime characters come from AniList and need no TMDB link; the cast row follows.
                                if title.category.hasPrefix("anime") { AnimeCharactersRow(title: title.name, year: title.year, movie: !title.isSeries) }
                                if let tmdbId = title.tmdbId { CastAndRelated(route: CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdbId), sourceTitle: title.name) }
                            }.padding(.horizontal, 14).padding(.bottom, 32)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
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
                                ToolbarItemGroup(placement: .topBarTrailing) {
                                    TitleHeaderAction(name: title.name, kind: title.isSeries ? .tv : .movie, id: title.tmdbId, state: headerState, informationPresented: $showInformation)
                                    Button { Task { await store.patch(title, values: ["favorite": !title.favorite]) } } label: { Image(systemName: title.favorite ? "heart.fill" : "heart") }.accessibilityLabel("Favorite").disabled(store.writesBlocked)
                                    Menu {
                                            Button("Community information", systemImage: "info.circle") { showInformation = true }
                                            Button(title.favorite ? "Remove favorite" : "Favorite", systemImage: title.favorite ? "heart.slash" : "heart") { Task { await store.patch(title, values: ["favorite": !title.favorite]) } }.disabled(store.writesBlocked)
                                        Button(title.queued == true ? "Remove from Queue" : "Add to Queue", systemImage: "text.badge.plus") { Task { await store.patch(title, values: ["queued": title.queued != true]) } }.disabled(store.writesBlocked)
                                        Button("Notes", systemImage: "note.text") { showNotes = true }.accessibilityIdentifier("title-menu-notes")
                                        Button("File locations", systemImage: "folder") { showLocation = true }.accessibilityIdentifier("title-menu-files")
                                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More options for " + title.name).accessibilityIdentifier("title-more")
                                }
                            }
                            .task { if !initializedEditor { initializedEditor = true; watchDate = store.now; notesField = VersionedField(value: title.notes, version: title.version); ratingField = VersionedField(value: title.score, version: title.version) } }
                            .task(id: season) {
                                if configuredSeason != season { configuredSeason = season; sliderDraft = nil; showAllEpisodes = false; episodeLimit = 40 }
                                await prepareSeason(title)
                                if focusEpisodes && !didFocusEpisodes && !Task.isCancelled {
                                    await Task.yield()
                                    didFocusEpisodes = true
                                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { proxy.scrollTo("episodes", anchor: .top) }
                                }
                                if !hideSpoilers { await revealSeason(title) }
                            }
                            .task(id: cardRevision(title)) { await loadCard(title) }
                            .task {
                                if focusNotes && !didFocusNotes {
                                    showNotes = true
                                    didFocusNotes = true
                                }
                            }
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
                    ScrollView { DatePicker("Watch date", selection: $watchDate, in: ...store.now, displayedComponents: .date).datePickerStyle(.graphical).padding(16) }
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
            .onChange(of: title.version) { _, _ in
                guard initializedEditor else { return }
                notesField.observe(.init(value: title.notes, version: title.version))
                ratingField.observe(.init(value: title.score, version: title.version))
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
        // A short sheet: the note field and its count, not half the screen.
        }.presentationDetents([.height(320)]).presentationDragIndicator(.visible).interactiveDismissDisabled(notesField.isDirty)
    }
    /// "On your drive": where the files are, at a glance; the full list opens in the locations sheet.
    private func driveRow(_ title: MediaTitle) -> some View {
        let present = locations.filter { $0.evidence == "present" }, shown = present.isEmpty ? locations : present
        // Letters arrive as "E:" from the scanner and Jellyfin; trim and add the colon once either way.
        let drives = Array(Set(shown.map { location -> String in
            let letter = location.driveLetter.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            return letter.isEmpty ? location.root : letter.uppercased() + ":"
        })).sorted()
        let seasons = Set(shown.compactMap(\.season)).sorted(), files = shown.reduce(0) { $0 + $1.fileCount }
        let detail = (seasons.count > 1 ? "Seasons \(seasons.first!)–\(seasons.last!)" : seasons.first.map { "Season \($0)" } ?? "")
        return Button { showLocation = true } label: {
            HStack(spacing: 12) {
                if locations.contains(where: { $0.deviceId == "jellyfin" }) { BrandLogo(service: .jellyfin, size: 30) }
                else { DiaryIcon(name: "hard-drive", size: 20).foregroundStyle(theme.accent).frame(width: 30, height: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(present.isEmpty ? "Not on your drives now" : "On your drive").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                    Text(([drives.joined(separator: " · ")] + (detail.isEmpty ? [] : [detail]) + [files.counted("file", "files")]).joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1))).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityIdentifier("title-drive-row")
    }
    private func locationsSheet(_ title: MediaTitle) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(serverLabel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityIdentifier("title-locations")
                    ForEach(locations) { location in locationRow(location, title: title) }
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
    private func header(_ title: MediaTitle) -> some View {
        TitleHero(name: title.name, poster: title.poster, year: title.year, category: title.categoryName, runtime: title.runtimeMinutes, series: title.isSeries, score: title.communityScore, summary: title.overview, expanded: $showOverview, onNameScrolled: { headerState.update($0) }) { personalRating(title).frame(minHeight: 44) }
    }
    private func personalRating(_ title: MediaTitle) -> some View { Button { openRating(title) } label: { HStack(spacing: 7) { DiaryIcon(name: "star", size: 21); Text("Your rating").foregroundStyle(.secondary); Text(title.score.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—") } }.buttonStyle(.plain).accessibilityIdentifier("title-personal-rating").accessibilityLabel("Your rating").accessibilityValue(title.score.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Not rated") }
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
                } } label: {
                    HStack(spacing: 8) {
                        if store.seasonStatus(title, season: season) == "watching" { Image(systemName: "play.fill").font(.system(size: 12)) }
                        else { Circle().fill(store.seasonStatus(title, season: season) == "completed" ? Color.mint : Color.secondary).frame(width: 8, height: 8) }
                        Text(store.seasonStatus(title, season: season).capitalized).font(.system(size: 14.4, weight: .semibold))
                        DiaryIcon(name: "chevron-down", size: 15)
                    }.padding(.horizontal, 14).frame(minHeight: 46).background { DiaryControlSurface(shape: Capsule(), selected: true) }
                }.buttonStyle(.plain).disabled(store.writesBlocked).accessibilityIdentifier("title-watch-status")
                Spacer(minLength: 0)
                Text(title.isSeries ? remaining(title).map { "\(DiaryDate.duration($0)) left" } ?? "Time unknown" : movieViewings.isEmpty ? title.runtimeMinutes.map { "\(DiaryDate.duration($0)) left" } ?? "Movie" : "Movie")
                    .font(.system(size: 12.8)).foregroundStyle(Color(white: 0.75)).multilineTextAlignment(.trailing).shadow(color: .black, radius: 3)
            }.padding(.bottom, 22)
            // A cached card paints on the first frame instead of a 290 pt placeholder swap.
            if let card = card ?? store.cachedCard(title, season: title.isSeries ? season : nil) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title.isSeries ? "Episode \(displayedWatched)" : "\(movieViewings.count)").font(.system(size: 20, weight: .bold))
                    Text(title.isSeries ? "of \(card.progress.total)" : movieViewings.count == 1 ? "view logged" : "views logged").font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer(minLength: 0); Text("\(displayedPercent)%").foregroundStyle(.tint).font(.system(size: 20, weight: .bold))
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
                Button { Task {
                    var recorded = false
                    if title.isSeries, let next = card.next, let episode = episodes.first(where: { $0.id == next.id }) { recorded = await store.recordViewing(title, episode: episode, watchedAt: watchInstant) }
                    else if !title.isSeries { recorded = await store.recordViewing(title, rewatch: !movieViewings.isEmpty, watchedAt: watchInstant) }
                    if recorded { markSparks += 1 }
                    await loadCard(title)
                } } label: {
                    Label(title.isSeries ? card.next.map { "Mark E\($0.number) watched" } ?? "Season caught up" : movieViewings.isEmpty ? "Log a watch" : "Log a rewatch", systemImage: !title.isSeries && !movieViewings.isEmpty ? "arrow.counterclockwise" : "checkmark")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.diaryPrimary).disabled(store.writesBlocked || (title.isSeries && card.next == nil)).starBurst(trigger: markSparks)
                    .sensoryFeedback(.success, trigger: markSparks).accessibilityIdentifier("mark-title-watch")
                HStack(spacing: 8) {
                    Button { showDate.toggle() } label: {
                        HStack(spacing: 7) { DiaryIcon(name: "calendar-days", size: 16).foregroundStyle(theme.accent); Text(DiaryDate.day(watchDate) == DiaryDate.day(store.now) ? "Watched today" : DiaryDate.day(watchDate)) }.frame(maxWidth: .infinity, minHeight: 44)
                    }.accessibilityIdentifier("watch-date")
                    Button { openRating(title) } label: {
                        HStack(spacing: 7) { DiaryIcon(name: "star", size: 16).foregroundStyle(theme.accent); Text(title.isSeries ? "Rate show" : "Rate movie") }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                }.font(.system(size: 14)).foregroundStyle(Color(webHex: "#c5c0cf")).buttonStyle(.plain).padding(.top, 6)
                if showDate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Watch date").font(.system(size: 13)).foregroundStyle(.secondary)
                        Button { choosingWatchDate = true } label: {
                            HStack(spacing: 8) { DiaryIcon(name: "calendar-days", size: 17); Text(watchDate.formatted(.dateTime.day().month(.abbreviated).year())).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0); DiaryIcon(name: "chevron-down", size: 13) }
                                .font(.system(size: 15)).padding(.horizontal, 12).frame(minHeight: 44)
                        }.buttonStyle(.plain).background { DiaryControlSurface(shape: RoundedRectangle(cornerRadius: 12), field: true) }.accessibilityIdentifier("title-watch-date-value").disabled(store.writesBlocked)
                        Text("Used for your next watch or progress update.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
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
        }.diaryPanel(padding: 15, radius: 24, accentBorder: true)
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
                episodeArtwork(episode).frame(width: 104, height: 58).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) { Text("UP NEXT").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.accent); Text("\(episode.number) · \(episodeName(episode))").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.leading) }
                Spacer(minLength: 0); if let runtime = title.runtimeMinutes { Text("\(runtime) min").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 12).padding(.horizontal, 10).background(.white.opacity(5.0 / 255), in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details")
    }
    /// Owner's Episodes layout: heading, a season card with its progress, All / Unwatched
    /// chips beside a grid–list switch, then the episodes.
    private func episodeSection(_ title: MediaTitle) -> some View {
        let progress = store.seasonProgress(title, season: season)
        let share = progress.total > 0 ? Int((Double(progress.watched) / Double(progress.total) * 100).rounded()) : 0
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Episodes").font(.system(size: 30, weight: .bold)).tracking(-0.8)
                Text("Your next story awaits").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    seasonMenu
                    Spacer(minLength: 0)
                    Text("\(share)%").font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
                }
                HStack {
                    Text("\(progress.watched) of \(progress.total) watched")
                    Spacer(minLength: 0)
                    Text("\(max(0, progress.total - progress.watched)) remaining")
                }.font(.system(size: 14)).foregroundStyle(.secondary)
                Capsule().fill(.white.opacity(0.1)).frame(height: 8)
                    .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * progress.fraction) } }
                    .padding(.top, 6).accessibilityHidden(true)
            }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
            HStack(spacing: 10) {
                episodeFilter("All episodes", on: !unwatchedOnly) { unwatchedOnly = false }
                episodeFilter("Unwatched", on: unwatchedOnly) { unwatchedOnly = true }
                Spacer(minLength: 0)
                Button { episodesGrid.toggle() } label: {
                    HStack(spacing: 2) {
                        DiaryIcon(name: "layout-grid", size: 18).frame(width: 40, height: 34).background(episodesGrid ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        DiaryIcon(name: "list", size: 18).frame(width: 40, height: 34).background(episodesGrid ? .clear : .white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    }.foregroundStyle(Color(webHex: "#c5c0cf")).padding(4).background(theme.field, in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.1))).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Show episodes as " + (episodesGrid ? "list" : "grid")).accessibilityValue(episodesGrid ? "Grid" : "List").accessibilityIdentifier("episodes-layout")
            }
            if !seasonCanEdit(title) { Button("Load season episodes") { Task { await store.loadSeason(title, number: season); await loadCard(title) } }.buttonStyle(.glass).disabled(store.writesBlocked) }
            if let seasonLoadError { RetryNotice(message: seasonLoadError) { Task { await prepareSeason(title, force: true) } } }
            if let episodeError = episodeDetails.error(for: season) { Text(episodeError).font(.caption).foregroundStyle(.secondary); Button("Retry episode details") { Task { await revealSeason(title) } } }
            CollectionLayout(grid: episodesGrid, spacing: 12) {
                let shown = visibleEpisodes
                ForEach(shown) { episode in
                    // The lazy grid creates the last row only as it nears the screen.
                    episodeRow(title, episode: episode).onAppear {
                        if showAllEpisodes, episode.id == shown.last?.id, episodeLimit < episodes.count { episodeLimit += 40 }
                    }
                }
            }
            if episodes.isEmpty { Text("No episode metadata yet").font(.subheadline).foregroundStyle(.secondary) }
            else if unwatchedOnly && episodes.allSatisfy({ watched.contains($0.id) }) { Text("Every episode in this season is watched.").font(.subheadline).foregroundStyle(.secondary) }
            if episodes.count > 4 { Button(showAllEpisodes ? "Back to next episode" : "Show all \(episodes.count) episodes") { showAllEpisodes.toggle() }.frame(maxWidth: .infinity).frame(minHeight: 44) }
            if let pending = store.pendingSeasonAdjustments[title.id + ":" + String(season)] { Button("Retry progress to episode \(pending.count)") { Task { await store.setSeasonProgress(title, season: season, count: pending.count, watchedAt: watchInstant); await loadCard(title) } }.disabled(store.writesBlocked) }
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
                Text(season == 0 ? "Specials" : "Season \(season)").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                if seasonNumbers.count > 1 { DiaryIcon(name: "chevron-down", size: 13).foregroundStyle(theme.accent) }
            }.padding(.horizontal, 16).frame(height: 40)
                .background(.white.opacity(0.08), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                .frame(minHeight: 44).contentShape(Capsule())
        }.disabled(seasonNumbers.count < 2).accessibilityLabel("Season").accessibilityValue(season == 0 ? "Specials" : "Season \(season)").accessibilityIdentifier("title-season")
    }
    private func episodeFilter(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name).font(.system(size: 15, weight: .medium)).foregroundStyle(on ? theme.ink : Color(webHex: "#c5c0cf"))
                .padding(.horizontal, 16).frame(height: 40)
                .background(on ? theme.accent : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : .white.opacity(0.16)))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("episodes-filter-" + (name == "Unwatched" ? "unwatched" : "all"))
    }
    private func episodeRow(_ title: MediaTitle, episode: Episode) -> some View {
        let isWatched = watched.contains(episode.id), next = card?.next?.id == episode.id
        return VStack(alignment: .leading, spacing: 10) {
            if episodesGrid {
                Button { toggleEpisode(title, episode: episode) } label: {
                    Color.clear.aspectRatio(16 / 10, contentMode: .fit).overlay { episodeArtwork(episode) }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("episode-thumbnail-\(episode.number)")
                }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) artwork")
                    .overlay(alignment: .bottomTrailing) { episodeWatchControl(title, episode: episode, watched: isWatched) }
                Button { toggleEpisode(title, episode: episode) } label: {
                    episodeCaption(episode, watched: isWatched, next: next)
                }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details")
                    .accessibilityValue(episodeName(episode)).accessibilityIdentifier("title-episode-\(episode.number)")
            } else {
                HStack(spacing: 12) {
                    Button { toggleEpisode(title, episode: episode) } label: {
                        HStack(spacing: 12) {
                            episodeArtwork(episode).frame(width: 132, height: 74).clipShape(RoundedRectangle(cornerRadius: 12))
                            episodeCaption(episode, watched: isWatched, next: next)
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details")
                        .accessibilityValue(episodeName(episode)).accessibilityIdentifier("title-episode-\(episode.number)")
                    episodeWatchControl(title, episode: episode, watched: isWatched)
                }
            }

        }.padding(.vertical, episodesGrid ? 0 : 10).padding(.horizontal, episodesGrid ? 0 : 4).frame(minHeight: 92).background(next && !episodesGrid ? theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 18))
    }
    private func episodeCaption(_ episode: Episode, watched: Bool, next: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Two lines beside the list thumbnail (one in the grid); the thumbnail sets the row height,
            // so revealing a spoiler-hidden name never moves the rows.
            Text(captionName(episode)).font(.system(size: 17, weight: .semibold))
                .lineLimit(episodesGrid ? 1 : 2).foregroundStyle(.white).multilineTextAlignment(.leading)
                .accessibilityIdentifier("episode-caption-\(episode.number)")
            HStack(spacing: 6) {
                Text(watched ? "Watched" : next ? "Up next" : hasAired(episode) ? "Not watched" : "Not aired yet")
                    .foregroundStyle(next ? theme.accent : Color.secondary)
                Spacer(minLength: 0)
                if let score = episodeDetails.episodes[episode.id]?.communityScore ?? episode.communityScore, score > 0 {
                    HStack(spacing: 4) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text(score.formatted(.number.precision(.fractionLength(1)))) }
                        .accessibilityElement(children: .ignore).accessibilityLabel("TMDb " + score.formatted(.number.precision(.fractionLength(1))))
                }
            }.font(.system(size: 14)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// "Episode 4" when that's all the name says, otherwise "4. The Ghost Bride".
    private func captionName(_ episode: Episode) -> String {
        let name = episodeName(episode)
        return name.hasPrefix("Episode ") || isHidden(episode) ? name : "\(episode.number). \(name)"
    }
    private func episodeWatchControl(_ title: MediaTitle, episode: Episode, watched: Bool) -> some View {
        Button {
            Task {
                if watched { await store.unwatchEpisode(episode) }
                else { await store.recordViewing(title, episode: episode, watchedAt: watchInstant) }
                await loadCard(title)
            }
        } label: {
            ZStack {
                Circle().fill(watched ? theme.accent : .black.opacity(episodesGrid ? 0.45 : 0)).frame(width: 30, height: 30)
                Circle().strokeBorder(watched ? .black.opacity(0.35) : .white.opacity(0.8), lineWidth: watched ? 2 : 1.5).frame(width: 30, height: 30)
                if watched { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.ink) }
            }.frame(width: 44, height: 44)
        }.buttonStyle(.plain).disabled(store.writesBlocked || (!watched && !hasAired(episode)))
            .accessibilityLabel("Mark episode \(episode.number) \(watched ? "unwatched" : "watched")")
            .accessibilityIdentifier("episode-watch-\(episode.number)")
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    episodeArtwork(episode).frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(episodeName(episode)).font(.title2.bold()).foregroundStyle(Color(webHex: "#f3f0f7"))
                    Text(episodeSummary(episode)).font(.system(size: 16)).lineSpacing(4).foregroundStyle(Color(webHex: "#c5c0cf")).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("episode-summary-\(episode.number)")
                    if watched.contains(episode.id) {
                        Button {
                            // Close the sheet at once so "Watch marked" and its Undo are
                            // visible while the save runs, not hidden under the sheet.
                            // A failed save still reports on the page's error banner.
                            let instant = watchInstant
                            selectedEpisode = nil
                            Task {
                                await store.recordViewing(title, episode: episode, rewatch: true, watchedAt: instant)
                                await loadCard(title)
                            }
                        } label: { Label("Log rewatch", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
                            .buttonStyle(.diaryPrimary).disabled(store.writesBlocked || !hasAired(episode))
                            .accessibilityIdentifier("episode-rewatch-\(episode.number)")
                    }
                }.padding(20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { episodeSheetHeight = $0 }
                    .id(episode.id)
                    .transition(.asymmetric(insertion: .move(edge: episodeForward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: episodeForward ? .leading : .trailing).combined(with: .opacity)))
            }.scrollContentBackground(.hidden).containerBackground(Color.clear, for: .navigation)
                // Swipe left for the next episode, right for the previous one.
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > 60, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                    showNeighbour(of: episode, forward: dx < 0, title: title)
                })
                .accessibilityAction(named: "Next episode") { showNeighbour(of: episode, forward: true, title: title) }
                .accessibilityAction(named: "Previous episode") { showNeighbour(of: episode, forward: false, title: title) }
                .navigationTitle("Episode \(episode.number)").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedEpisode = nil } } }
        // As tall as the synopsis needs, on glass: never the opaque full-screen sheet, so the text colours never jump.
        }.presentationDetents([SheetFit.detent(episodeSheetHeight, chrome: 96)]).presentationDragIndicator(.visible)
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
    private func ratingPanel(_ title: MediaTitle) -> some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 7) { DiaryIcon(name: "star", size: 16); Text("Your rating") }.foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(ratingField.draft.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Not rated").monospacedDigit()
                    .contentTransition(.numericText(value: ratingField.draft ?? 0)).animation(Motion.press, value: ratingField.draft)
                    .starBurst(trigger: perfectSparks)
                if ratingField.draft != nil { Button("Clear") { Task { await saveRating(value: nil) } }.accessibilityLabel("Clear your rating") }
                else { Button("Rate 7.0") { Task { await saveRating(value: 7) } } }
            }.font(.system(size: 14)).frame(minHeight: 32)
            HStack(spacing: 10) {
                Text("1").foregroundStyle(.secondary)
                Slider(value: Binding(get: { ratingField.draft ?? 7 }, set: { ratingField.draft = $0 }), in: 1...10, step: 0.5) { editing in
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
        }.disabled(store.writesBlocked || !store.canMutate).accessibilityElement(children: .contain).accessibilityIdentifier("title-rating-panel")
    }
    private func saveRating(value: Double?) async {
        if value == 10 { perfectSparks += 1 }
        ratingField.draft = value.map { ($0 * 2).rounded() / 2 }
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
    /// Unwatched filters before the 40-row page, so a long season never shows an empty first page.
    private var visibleEpisodes: [Episode] {
        let window = EpisodeSelection.window(episodes, season: season, all: showAllEpisodes, nextID: card?.next?.id ?? episodes.first(where: { !watched.contains($0.id) && hasAired($0) })?.id)
        let seen = self.watched
        return Array((unwatchedOnly ? window.filter { !seen.contains($0.id) } : window).prefix(episodeLimit))
    }
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
private struct NotesEditor: View {
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
