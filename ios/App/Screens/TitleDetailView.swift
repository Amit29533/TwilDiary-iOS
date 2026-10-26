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
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var chosenSeason: Int?
    @State private var initializedEditor = false
    @State private var configuredSeason: Int?
    @FocusState private var notesFocused: Bool
    @State private var showOverview = false
    @State private var showNotes = false
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
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                header(title)
                                progressPanel(title).padding(.top, -8)
                                if title.isSeries { episodeSection(title).id("episodes") }
                                if let tmdbId = title.tmdbId { CastAndRelated(route: CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdbId), sourceTitle: title.name) }
                                VStack(spacing: 20) {
                                    DisclosureGroup("Notes", isExpanded: $showNotes) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            TextEditor(text: $notesField.draft).frame(minHeight: 110).scrollContentBackground(.hidden).focused($notesFocused).accessibilityIdentifier("title-notes").accessibilityLabel("Title notes").id("notes-editor")
                                            if notesField.draft.utf16.count > 20_000 { Text("Keep notes within 20,000 characters.").font(.caption).foregroundStyle(.orange) }
                                            if notesField.conflict != nil {
                                                fieldConflict("Notes changed elsewhere.", useSaved: { notesField.useSaved() }, keepDraft: { notesField.keepDraft() })
                                            }
                                            Button("Save notes") { Task { await saveNotes() } }.disabled(store.writesBlocked || !notesField.isDirty || notesField.submission == nil || notesField.draft.utf16.count > 20_000)
                                        }.padding(.top, 12)
                                    }.id("notes")
                                    Divider()
                                    DisclosureGroup(isExpanded: $showLocation) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            ForEach(locations) { location in locationRow(location, title: title) }
                                            if locations.isEmpty { Text("No mapped files yet. A Windows scan will add matching locations here.").font(.system(size: 13)).foregroundStyle(.secondary) }
                                            NavigationLink("All files & drives →", value: AppDestination.files).font(.system(size: 14, weight: .semibold)).frame(minHeight: 48).accessibilityIdentifier("title-all-files")
                                        }.padding(.top, 12)
                                    } label: { Text(serverLabel).font(.subheadline.weight(.semibold)).accessibilityIdentifier("title-locations") }
                                        .id("files")
                                }.diaryPanel()
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
                                        Button(title.queued == true ? "Remove from Queue" : "Queue") { Task { await store.patch(title, values: ["queued": title.queued != true]) } }.disabled(store.writesBlocked)
                                        Button("Notes") { showNotes = true; pendingScrollTarget = "notes-editor" }.accessibilityIdentifier("title-menu-notes")
                                        Button("File locations") { showLocation = true; pendingScrollTarget = "files" }.accessibilityIdentifier("title-menu-files")
                                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More options for " + title.name).accessibilityIdentifier("title-more")
                                }
                            }
                            .toolbar { ToolbarItemGroup(placement: .keyboard) { if notesFocused { Spacer(); Button("Done") { notesFocused = false }.accessibilityIdentifier("notes-keyboard-done") } } }
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
                                    pendingScrollTarget = "notes-editor"
                                }
                            }
                            .sheet(item: $selectedEpisode) { episode in episodeInformation(title, episode: episode) }
                            .sheet(isPresented: $choosingWatchDate) {
                                NavigationStack {
                                    ScrollView { DatePicker("Watch date", selection: $watchDate, in: ...store.now, displayedComponents: .date).datePickerStyle(.graphical).padding(16) }
                                        .navigationTitle("Watch date").navigationBarTitleDisplayMode(.inline)
                                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingWatchDate = false } } }
                                }.presentationDetents([.medium, .large])
                            }
                            .sheet(isPresented: $showInformation) {
                                CommunityInformationSheet(name: title.name, artwork: title.backdrop ?? title.poster, identity: CommunityIdentity(kind: title.isSeries ? .tv : .movie, id: title.tmdbId))
                            }
                            .onChange(of: hideSpoilers) { _, hidden in if !hidden { Task { await revealSeason(title) } } }
                            .onChange(of: store.sessionRevision) { _, _ in episodeDetails.reset(); revealedEpisodeIDs = []; expandedEpisodes = [] }
                            .onChange(of: title.version) { _, _ in
                                guard initializedEditor else { return }
                                notesField.observe(.init(value: title.notes, version: title.version))
                                ratingField.observe(.init(value: title.score, version: title.version))
                            }
                            .confirmationDialog(title.isSeries ? "Reset Season \(season) to Planned? Only this season’s watches will be removed. Earlier seasons stay saved. Undo is available." : "Reset progress to 0? Logged watches will be removed, with Undo available.", isPresented: $resetConfirmation, titleVisibility: .visible) {
                                Button("Reset to Planned", role: .destructive) { Task { await store.setSeasonStatus(title, season: season, status: "planned", watchedAt: watchInstant); await loadCard(title) } }
                            }
                    }
                }
            } else { ContentUnavailableView("Title unavailable", systemImage: "film") }
        }
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
                Text(location.driveLetter + " · " + (location.season.map { "Season \($0)" } ?? "Title folder")).font(.system(size: 13.6, weight: .semibold))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().frame(width: 5, height: 5)
                    Text(location.evidence == "present" ? "Available" : location.evidence == "unavailable" ? "Drive offline" : location.evidence == "missing" ? "Not available" : "Not confirmed")
                }.font(.system(size: 12.8)).foregroundStyle(Color(webHex: location.evidence == "present" ? "#9edbc4" : "#e7ca90"))
            }
            Text(location.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text("\(location.fileCount) files · \(location.deviceName)").font(.system(size: 12.8)).foregroundStyle(.secondary)
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
            if let card {
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
                    if title.isSeries, let next = card.next, let episode = episodes.first(where: { $0.id == next.id }) { await store.recordViewing(title, episode: episode, watchedAt: watchInstant) }
                    else if !title.isSeries { await store.recordViewing(title, rewatch: !movieViewings.isEmpty, watchedAt: watchInstant) }
                    await loadCard(title)
                } } label: {
                    Label(title.isSeries ? card.next.map { "Mark E\($0.number) watched" } ?? "Season caught up" : movieViewings.isEmpty ? "Log a watch" : "Log a rewatch", systemImage: !title.isSeries && !movieViewings.isEmpty ? "arrow.counterclockwise" : "checkmark")
                        .font(.system(size: 15.2, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 52)

                }.buttonStyle(.glassProminent).disabled(store.writesBlocked || (title.isSeries && card.next == nil)).accessibilityIdentifier("mark-title-watch")
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
                        Text("\(progress.watched) of \(progress.total) episodes watched").font(.headline)
                        EpisodeProgressTrack(segments: EpisodeSegment.make(episodes: episodes, total: progress.total, watched: watched, nextID: nil), season: season).frame(height: 44)
                    }
                    RetryNotice(message: cardError) { Task { await loadCard(title) } }
                }.padding(.vertical, 12)
            } else { DiaryLoadingPlaceholder(height: title.isSeries ? 290 : 210, label: "Loading watch progress") }
        }.diaryPanel(padding: 15, radius: 24, accentBorder: true)
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
    private func episodeSection(_ title: MediaTitle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Episodes").font(.system(size: 22, weight: .bold))
                    Text("\(store.seasonProgress(title, season: season).watched) / \(store.seasonProgress(title, season: season).total) watched").font(.system(size: 13.6)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !seasonNumbers.isEmpty {
                    Picker("Season", selection: Binding(get: { season }, set: { chosenSeason = $0 })) {
                        ForEach(seasonNumbers, id: \.self) { number in Text(number == 0 ? "Specials" : "Season \(number)").tag(number) }
                    }.pickerStyle(.menu).accessibilityIdentifier("title-season").accessibilityValue(season == 0 ? "Specials" : "Season \(season)")
                }
                CollectionLayoutToggle(grid: $episodesGrid, collection: "episodes")
            }
            if !seasonCanEdit(title) { Button("Load season episodes") { Task { await store.loadSeason(title, number: season); await loadCard(title) } }.buttonStyle(.glass).disabled(store.writesBlocked) }
            if let seasonLoadError { RetryNotice(message: seasonLoadError) { Task { await prepareSeason(title, force: true) } } }
            if let episodeError = episodeDetails.error(for: season) { Text(episodeError).font(.caption).foregroundStyle(.secondary); Button("Retry episode details") { Task { await revealSeason(title) } } }
            CollectionLayout(grid: episodesGrid, spacing: 8) { ForEach(visibleEpisodes) { episode in episodeRow(title, episode: episode) } }
            if episodes.isEmpty { Text("No episode metadata yet").font(.subheadline).foregroundStyle(.secondary) }
            if showAllEpisodes && episodeLimit < episodes.count { Color.clear.frame(height: 1).onAppear { episodeLimit += 40 } }
            if episodes.count > 4 { Button(showAllEpisodes ? "Back to next episode" : "Show all \(episodes.count) episodes") { showAllEpisodes.toggle() }.frame(maxWidth: .infinity).frame(minHeight: 44) }
            if let pending = store.pendingSeasonAdjustments[title.id + ":" + String(season)] { Button("Retry progress to episode \(pending.count)") { Task { await store.setSeasonProgress(title, season: season, count: pending.count, watchedAt: watchInstant); await loadCard(title) } }.disabled(store.writesBlocked) }
        }
    }
    private func episodeRow(_ title: MediaTitle, episode: Episode) -> some View {
        let isWatched = watched.contains(episode.id), next = card?.next?.id == episode.id
        return VStack(alignment: .leading, spacing: 10) {
            if episodesGrid {
                Button { toggleEpisode(title, episode: episode) } label: {
                    episodeArtwork(episode).frame(height: 96).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("episode-thumbnail-\(episode.number)")
                }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) artwork")
                    .overlay(alignment: .bottomTrailing) {
                        episodeWatchControl(title, episode: episode, watched: isWatched)
                            .background(.black.opacity(0.65), in: Circle())
                    }
                Button { toggleEpisode(title, episode: episode) } label: {
                    episodeCaption(episode, watched: isWatched, next: next)
                }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details")
                    .accessibilityValue(episodeName(episode)).accessibilityIdentifier("title-episode-\(episode.number)")
            } else {
                HStack(spacing: 12) {
                    Button { toggleEpisode(title, episode: episode) } label: {
                        HStack(spacing: 12) {
                            episodeArtwork(episode).frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
                            episodeCaption(episode, watched: isWatched, next: next)
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Episode \(episode.number) details")
                        .accessibilityValue(episodeName(episode)).accessibilityIdentifier("title-episode-\(episode.number)")
                    episodeWatchControl(title, episode: episode, watched: isWatched)
                }
            }

        }.padding(.vertical, 8).frame(minHeight: 72).background(next ? theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 18))
    }
    private func episodeCaption(_ episode: Episode, watched: Bool, next: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(episode.number) · \(episodeName(episode))").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white).multilineTextAlignment(.leading)
                .accessibilityIdentifier("episode-caption-\(episode.number)")
            InlineFlowLayout {
                Text(watched ? "Watched" : next ? "Up next" : hasAired(episode) ? "Not watched" : "Not aired yet")
                    .foregroundStyle(next ? theme.accent : Color.secondary)
                if let score = episodeDetails.episodes[episode.id]?.communityScore ?? episode.communityScore, score > 0 {
                    Text("★ " + score.formatted(.number.precision(.fractionLength(1))) + " TMDb").foregroundStyle(.yellow)
                }
            }.font(.system(size: 11))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func episodeWatchControl(_ title: MediaTitle, episode: Episode, watched: Bool) -> some View {
        Button {
            Task {
                if watched { await store.unwatchEpisode(episode) }
                else { await store.recordViewing(title, episode: episode, watchedAt: watchInstant) }
                await loadCard(title)
            }
        } label: {
            Image(systemName: watched ? "checkmark.circle.fill" : "circle").font(.system(size: episodesGrid ? 32 : 24))
                .foregroundStyle(watched ? theme.accent : Color.secondary).frame(width: 44, height: 44)
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
                    episodeArtwork(episode).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(episodeName(episode)).font(.title2.bold())
                    Text(episodeSummary(episode)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("episode-summary-\(episode.number)")
                    if watched.contains(episode.id) {
                        Button {
                            Task {
                                await store.recordViewing(title, episode: episode, rewatch: true, watchedAt: watchInstant)
                                selectedEpisode = nil
                                await loadCard(title)
                            }
                        } label: { Label("Log rewatch", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.glassProminent).disabled(store.writesBlocked || !hasAired(episode))
                            .accessibilityIdentifier("episode-rewatch-\(episode.number)")
                    }
                }.padding(20)
            }.navigationTitle("Episode \(episode.number)").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedEpisode = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func prepareSeason(_ title: MediaTitle, force: Bool = false) async {
        if store.isPreview && !store.canMutate { return }
        let request = UUID(), selected = season
        seasonRequest = request; seasonLoadError = nil
        guard force || SeasonMetadata.needsPreparation(title: title, workspace: store.workspace, season: selected, now: store.now) else { preparingSeason = false; return }
        preparingSeason = true; defer { if seasonRequest == request { preparingSeason = false } }
        do { try await store.prepareSavedSeason(title, number: selected, force: force) }
        catch is CancellationError { }
        catch { if seasonRequest == request, selected == season, !Task.isCancelled { seasonLoadError = error.localizedDescription } }
    }
    private func revealSeason(_ title: MediaTitle) async {
        let selected = season
        await episodeDetails.load(selected) { try await store.revealedSeason(title, number: selected) }
    }
    private var movieViewings: [WatchEvent] { store.workspace.activeEvents.filter { $0.titleId == id && $0.episodeId == nil }.sorted { ($0.recordedAt, $0.id) > ($1.recordedAt, $1.id) } }
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
                if ratingField.draft != nil { Button("Clear") { Task { await saveRating(value: nil) } }.accessibilityLabel("Clear your rating") }
                else { Button("Rate 7.0") { Task { await saveRating(value: 7) } } }
            }.font(.system(size: 14)).frame(minHeight: 32)
            HStack(spacing: 10) {
                Text("1").foregroundStyle(.secondary)
                Slider(value: Binding(get: { ratingField.draft ?? 7 }, set: { ratingField.draft = $0 }), in: 1...10, step: 0.5) { editing in
                    if !editing { Task { await saveRating(value: ratingField.draft) } }
                }.accessibilityLabel("Your rating out of 10").accessibilityIdentifier("title-rating-slider")
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
    private var seasonNumbers: [Int] { EpisodeSelection.seasons(in: store.workspace, titleID: id) }
    private var season: Int { chosenSeason ?? EpisodeSelection.preferredSeason(in: store.workspace, titleID: id, today: DiaryDate.day(store.now), linkedSeason: linkedSeason) }
    private func cardRevision(_ title: MediaTitle) -> CardRevision {
        CardRevision(season: season, events: store.workspace.events.filter { $0.titleId == id }, episodes: episodes, seasons: title.seasons ?? [])
    }
    private var episodes: [Episode] { store.episodesForSeason(id, season: season) }
    private var visibleEpisodes: [Episode] {
        Array(EpisodeSelection.window(episodes, season: season, all: showAllEpisodes, nextID: card?.next?.id ?? episodes.first(where: { !watched.contains($0.id) && hasAired($0) })?.id).prefix(episodeLimit))
    }
    private var watched: Set<String> { store.watchedEpisodeIDs(id) }
    private var locations: [FileLocation] { store.workspace.locations.filter { $0.titleId == id } }
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
