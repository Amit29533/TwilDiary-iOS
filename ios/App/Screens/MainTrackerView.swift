import SwiftUI
import TwilDiaryCore

/// Settings → Main tracker: which service is the diary (Trakt, MDBList or WeTrakr). For now the
/// choice decides which one the read-and-compare preview checks; the switch-over (plan phase 4)
/// makes it the diary. Nothing is written anywhere from here.
struct MainTrackerView: View {
    @AppStorage(MainTrackerView.key) private var selection = MainTracker.trakt.rawValue
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    static let key = "mainTracker"
    private var tracker: MainTracker { MainTracker(rawValue: selection) ?? .trakt }

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text("Where your diary lives").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    SettingsInfoButton(text: "The service you pick holds your diary. What it can’t keep (tags, notes, file locations, favourite people) stays on this iPhone and in your backups.")
                }
                VStack(spacing: 0) {
                    ForEach(Array(MainTracker.offered.enumerated()), id: \.element) { index, option in
                        if index > 0 { Divider().padding(.leading, 62) }
                        Button { selection = option.rawValue } label: { row(option) }
                            .buttonStyle(.plain).accessibilityIdentifier("main-tracker-" + option.rawValue)
                            .accessibilityAddTraits(option == tracker ? .isSelected : [])
                    }
                }.diaryPanel(padding: 0, radius: 18)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kept in Cloudflare with \(tracker.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(tracker.keptInCloudflare.joined(separator: " · ").capitalizedFirst)
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("main-tracker-cloudflare")
                }.frame(maxWidth: .infinity, alignment: .leading).diaryPanel(padding: 14, radius: 16)
                if tracker != .trakt, !store.providerSettings.config(for: tracker.provider).isAuthenticated {
                    NavigationLink(value: tracker == .wetrakr ? AppDestination.wetrakr : AppDestination.mdblist) {
                        Label("Connect \(tracker.name) first", systemImage: "link").frame(maxWidth: .infinity)
                    }.font(.subheadline).buttonStyle(.diarySecondary).accessibilityIdentifier("main-tracker-connect")
                }
                if tracker == .trakt { diarySource } else { trackerDiarySource }
                TrackerPreviewPanel(tracker: tracker)
                Text(store.onThisPhone ? "Your diary is on this phone." : store.diaryService.map { "\($0.name) holds your diary." } ?? "Your diary is on this phone.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("main-tracker-record")
            }.padding(14).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("Main tracker").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }

    /// Phase 4a: browse the whole app with the diary built from Trakt (plus your server's extras),
    /// before Trakt becomes the record. Editing is paused meanwhile; switching back is instant.
    private var diarySource: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $store.diaryFromTrakt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show my diary from Trakt").font(.subheadline.weight(.semibold))
                    Text("Your edits go straight to Trakt").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.accessibilityIdentifier("diary-from-trakt")
            if store.diaryFromTrakt {
                Label("Your diary comes from Trakt. Turn this off to go back to your server’s diary.", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            }
        }.padding(14).background(theme.field, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }

    /// Phase 5: the same from MDBList or WeTrakr; edits go to it.
    private var trackerDiarySource: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { store.diaryFromTracker == tracker }, set: { store.diaryFromTracker = $0 ? tracker : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show my diary from \(tracker.name)").font(.subheadline.weight(.semibold))
                    Text("Your edits go straight to \(tracker.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.accessibilityIdentifier("diary-from-" + tracker.rawValue)
            if store.diaryFromTracker == tracker {
                Label("Diary from \(tracker.name)", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            }
        }.padding(14).background(theme.field, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }

    private func row(_ option: MainTracker) -> some View {
        HStack(alignment: .top, spacing: 14) {
            BrandLogo(service: option.brand, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(option.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                Text(option.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(theme.accent)
                .opacity(option == tracker ? 1 : 0).frame(width: 24)
        }.padding(14).frame(minHeight: 64).contentShape(Rectangle())
    }
}

extension MainTracker {
    var brand: BrandLogo.Service {
        switch self { case .trakt: .trakt; case .mdblist: .mdblist; case .wetrakr: .wetrakr }
    }
    var provider: SyncProviderKind {
        switch self { case .trakt: .trakt; case .mdblist: .mdblist; case .wetrakr: .wetrakr }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Reads the chosen tracker directly and compares it with the diary. Changes nothing.
struct TrackerPreviewPanel: View {
    let tracker: MainTracker
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var trakt = TraktDirectStore.shared
    @State private var others = TrackerPreviewStore.shared
    private var id: String { tracker.rawValue + "-direct" }
    private var library: TraktLibrary? { tracker == .trakt ? trakt.library : others.libraries[tracker] }
    private var report: TraktDirectStore.Report? { tracker == .trakt ? trakt.report : others.reports[tracker] }
    private var error: String? { tracker == .trakt ? trakt.error : others.errors[tracker] }
    private var running: Bool { tracker == .trakt ? trakt.running : others.running == tracker }
    /// This service is the diary: there's nothing to make it match.
    private var holdsDiary: Bool { tracker == .trakt ? store.traktHoldsDiary : (store.diaryService == tracker) }
    @State private var confirmMatch = false
    /// Force Match: which side wins.
    @State private var forceSource = TrackerPreviewStore.ForceSource.diary
    /// Force Match asks first, with what it would add and take off (both sides read for it).
    @State private var forcePreview: ForceMatchPlan?
    @State private var forcePreviewSource = TrackerPreviewStore.ForceSource.diary
    @State private var readingForForce = false
    @State private var confirmForce = false
    @State private var copiedReport = false
    @State private var clearedLetters = 0
    @State private var writeThroughError: String?
    @State private var savingWriteThrough = false

    var body: some View {
        if tracker == .trakt && store.traktHoldsDiary { traktSyncCard } else { previewCard }
    }

    /// Trakt holds the diary: just whether everything is on Trakt, and what's still going there.
    private var traktSyncCard: some View {
        let matched = report != nil && trakt.pending.isEmpty
        let headline = trakt.writeProgress ?? (running ? "Checking Trakt…" : matched ? "Everything is on Trakt"
            : !trakt.pending.isEmpty ? trakt.pending.count.counted("change", "changes") + " waiting to send" : "Not checked yet")
        let checked = library.flatMap { DiaryDate.parse($0.fetchedAt) }
        // Design (board 4): SYNC, then one card: the state with when it was checked, and Sync now.
        return VStack(alignment: .leading, spacing: 12) {
            SettingsLabel(text: "Sync") { EmptyView() }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Group {
                        if running || trakt.writeProgress != nil { ProgressView().controlSize(.small).tint(HomeStyle.chipText) }
                        else { Image(systemName: matched ? "checkmark" : "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .bold)) }
                    }.foregroundStyle(HomeStyle.chipText).frame(width: 36, height: 36).background(HomeStyle.chip, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                            .accessibilityIdentifier(matched ? id + "-match" : id + "-differences")
                        if let checked { Text("Checked " + checked.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-error") }
                Button {
                    Task { await trakt.check(store: store) }
                } label: {
                    Label(running || trakt.writing ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(running || trakt.writing).accessibilityIdentifier(id + "-check")
            }.padding(15).modifier(SettingsCard())
        }.accessibilityElement(children: .contain).accessibilityIdentifier(id + "-panel")
    }

    private var previewCard: some View {
        // Design (boards 7 and 13): DIRECT FROM <SERVICE> · Preview · ⓘ, then one card with Check now.
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabel(text: "Direct from \(tracker.name)") {
                SettingsBadge(text: "Preview", tone: .configured)
                SettingsInfoButton(text: intro)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Compare your \(tracker.name) library with your diary.").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report { reportView(report) }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-error")
                }
                if tracker == .trakt, !trakt.pending.isEmpty {
                    Label(trakt.pending.count.counted("change", "changes") + " waiting for a connection; sent on their own when you’re back online.", systemImage: "icloud.and.arrow.up")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("trakt-pending")
                }
                if tracker == .trakt { if !store.phoneOnly { matchSection } } else if holdsDiary {
                    Text("\(tracker.name) holds your diary; nothing is sent from here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-holds-diary")
                } else { trackerMatchSection }
                Button {
                    Task { if tracker == .trakt { await trakt.check(store: store) } else { await others.check(tracker, store: store) } }
                } label: {
                    Label(running ? "Reading \(tracker.name)…" : "Check now", systemImage: "arrow.clockwise")
                }.buttonStyle(SettingsWideButtonStyle()).disabled(running || trakt.writing || others.writing != nil).accessibilityIdentifier(id + "-check")
                if tracker != .trakt, let log = SyncReport.text(tracker.provider) {
                    // What the last match sent and what came back, to see why something didn't land.
                    Button { UIPasteboard.general.string = log; copiedReport = true } label: {
                        Label(copiedReport ? "Copied" : "Copy last sync report", systemImage: copiedReport ? "checkmark" : "doc.on.doc")
                    }.buttonStyle(SettingsWideButtonStyle()).accessibilityIdentifier(id + "-report")
                }
                let ledger = MatchLedger.tokens(tracker)
                if !ledger.isEmpty {
                    // Sent before and not kept by the service: not resent on every match.
                    HStack(spacing: 8) {
                        Label("\(ledger.count) didn’t stick on \(tracker.name)", systemImage: "arrow.uturn.backward.circle")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Try them again") {
                            Task { if tracker == .trakt { await trakt.retryLedger(store: store) } else { await others.retryLedger(tracker, store: store) }; clearedLetters += 1 }
                        }.font(.subheadline.weight(.semibold))
                    }.id("ledger-\(clearedLetters)").accessibilityIdentifier(id + "-ledger")
                }
                let setAside = DeadLetters.list(tracker.provider)
                if !setAside.isEmpty {
                    // Edits the service refused or kept failing on: off its queue so the rest go on.
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(setAside, id: \.self) { line in
                                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Clear this list", role: .destructive) { DeadLetters.clear(tracker.provider); clearedLetters += 1 }.font(.caption.weight(.semibold))
                        }.padding(.top, 6)
                    } label: {
                        Label("\(setAside.count) \(setAside.count == 1 ? "edit" : "edits") set aside", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color(webHex: "#f5c26b"))
                    }.id(clearedLetters).accessibilityIdentifier(id + "-set-aside")
                }
            }.padding(15).modifier(SettingsCard())
                .smoothChange(of: report?.comparison.matchingPlays ?? -1)
        }.accessibilityElement(children: .contain).accessibilityIdentifier(id + "-panel")
    }

    /// Phase 2: bring Trakt in line with the diary, after showing exactly what will be sent.
    @ViewBuilder private var matchSection: some View {
        let plan = report != nil ? trakt.plan : nil
        Toggle(isOn: Binding(get: { store.traktWriteThrough }, set: { on in
            savingWriteThrough = true; writeThroughError = nil
            Task {
                do { try await store.setTraktWriteThrough(on) } catch { writeThroughError = error.localizedDescription }
                savingWriteThrough = false
            }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send my edits to Trakt as I make them").font(.subheadline.weight(.semibold))
                Text("Watches, ratings and lists").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.disabled(savingWriteThrough).accessibilityIdentifier("trakt-write-through")
        if let writeThroughError { Text(writeThroughError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        if let progress = trakt.writeProgress {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(.secondary) }
        } else if let result = trakt.writeResult {
            Label(result, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("trakt-match-result")
        }
        if let plan, !plan.isEmpty, !trakt.writing {
            Button { confirmMatch = true } label: {
                Label("Make Trakt match the diary", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }.font(.subheadline.weight(.semibold)).buttonStyle(.diaryPrimary).disabled(running).accessibilityIdentifier("trakt-make-match")
                .confirmationDialog("Make Trakt match the diary?", isPresented: $confirmMatch, titleVisibility: .visible) {
                    Button("Send to Trakt") { Task { await trakt.makeTraktMatch(store: store) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(plan.summary.map { "• " + $0 }.joined(separator: "\n")
                         + "\n\nNothing is removed from your Trakt history. Watches only on Trakt stay and come into the diary on their own.")
                }
        }
    }

    /// Phase 5: the same for MDBList and WeTrakr, within what each keeps.
    @ViewBuilder private var trackerMatchSection: some View {
        let plan = report != nil ? others.plans[tracker] : nil
        if others.writing == tracker, let progress = others.writeProgress {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(.secondary) }
        } else if let result = others.writeResults[tracker] {
            Label(result, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(tracker.rawValue + "-match-result")
        }
        if let plan, !plan.isEmpty, others.writing == nil {
            Button { confirmMatch = true } label: {
                Label("Make \(tracker.name) match the diary", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }.font(.subheadline.weight(.semibold)).buttonStyle(.diaryPrimary).disabled(running).accessibilityIdentifier(tracker.rawValue + "-make-match")
                .confirmationDialog("Make \(tracker.name) match the diary?", isPresented: $confirmMatch, titleVisibility: .visible) {
                    Button("Send to \(tracker.name)") { Task { await others.makeMatch(tracker, store: store) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(plan.summary.map { "• " + $0 }.joined(separator: "\n")
                         + "\n\nNothing is removed from your \(tracker.name) history. \(tracker.name) keeps one watch per episode, so the first is sent and rewatches stay in your diary.")
                }
        }
        forceMatchSection
    }

    /// Force Match: one side made exactly like the other, after a preview of what's added and taken off.
    @ViewBuilder private var forceMatchSection: some View {
        let intoDiary = others.canForceIntoDiary(tracker, store: store)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Source of truth").font(.subheadline.weight(.semibold))
                SettingsInfoButton(text: forceSource == .diary
                 ? "Makes \(tracker.name) your diary: what it lacks is added, what it has that your diary doesn’t is taken off, and failures are retried. Titles \(tracker.name) can’t take as sent are left as they are and named. You’ll see what changes first; it can’t be undone."
                 : "Makes your diary \(tracker.name): what it lacks is added to \((store.diaryService ?? .trakt).name), what isn’t on \(tracker.name) is taken off, and failures are retried. Titles that can’t be taken as sent are left as they are and named. You’ll see what changes first; it can’t be undone.").padding(.vertical, -10)
                Spacer(minLength: 8)
                // The app's pill dropdown (as Automatic backups), not the system's plain menu picker.
                Menu {
                    Picker("Source of truth", selection: $forceSource) {
                        Text("Diary").tag(TrackerPreviewStore.ForceSource.diary)
                        if intoDiary { Text(tracker.name).tag(TrackerPreviewStore.ForceSource.service) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(forceSource == .diary ? "Diary" : tracker.name)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }.font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                        .padding(.horizontal, 12).frame(height: 32).background(HomeStyle.chip, in: Capsule())
                }.accessibilityLabel("Source of truth").accessibilityValue(forceSource == .diary ? "Diary" : tracker.name)
                    .accessibilityIdentifier(tracker.rawValue + "-force-source")
            }
            Button {
                // Both sides are read and the changes shown before anything is sent.
                let source = forceSource
                readingForForce = true
                Task {
                    let plan = await others.forcePlan(tracker, source: source, store: store)
                    readingForForce = false
                    // A read that failed says why in the panel.
                    guard let plan else { return }
                    // Nothing to change: the run says so itself.
                    if plan.isEmpty { await others.forceRun(tracker, source: source, store: store); return }
                    forcePreview = plan; forcePreviewSource = source; confirmForce = true
                }
            } label: {
                Label(others.writing == tracker ? "Force matching…" : readingForForce ? "Reading both sides…" : "Force Match", systemImage: "equal.circle").frame(maxWidth: .infinity)
            }.buttonStyle(SettingsWideButtonStyle()).disabled(running || others.writing != nil || readingForForce)
                .accessibilityIdentifier(tracker.rawValue + "-force-match")
                .alert(forcePreviewSource == .service ? "Change your diary to match \(tracker.name)?" : "Make \(tracker.name) match your diary?", isPresented: $confirmForce) {
                    Button(forcePreviewSource == .service ? "Change my diary" : "Force Match", role: .destructive) {
                        let source = forcePreviewSource
                        Task { await others.forceRun(tracker, source: source, store: store) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(forceConfirmation)
                }
        }.onChange(of: intoDiary) { _, can in if !can { forceSource = .diary } }
    }
    /// What the previewed Force Match would do, one line per kind of change.
    private var forceConfirmation: String {
        guard let plan = forcePreview else { return "" }
        // Some lines name every title; in an alert they're cut to a line or two.
        let lines = plan.summary.map { "• " + ($0.count > 140 ? String($0.prefix(140)) + "…" : $0) }
        var text = lines.joined(separator: "\n")
        if plan.removalCount > 0 { text += "\n\n\(plan.removalCount.formatted()) taken off \(plan.tracker.name) in all." }
        if forcePreviewSource == .service, !tracker.capabilities.keepsRewatches {
            text += "\n\n\(tracker.name) keeps one watch per episode; rewatches already in your diary stay."
        }
        return text + "\n\nThis can’t be undone."
    }
    private var intro: String {
        switch tracker {
        case .trakt: "Reads your Trakt history, ratings, watchlist, favourites and dropped shows straight from Trakt and compares them with your diary. Nothing is changed."
        case .mdblist: "Reads your MDBList watched items, ratings, dropped shows and watchlist and compares them with your diary. Items it can’t read are counted, not guessed. Nothing changes until you send."
        case .wetrakr: "Reads your WeTrakr plays (rewatches included), ratings, watchlist, favourites and dropped titles, then only its journal of what changed, and compares them with your diary. Nothing changes until you send."
        }
    }

    @ViewBuilder private func reportView(_ report: TraktDirectStore.Report) -> some View {
        let library = library ?? TraktLibrary()
        let compared = report.comparison
        let timing = report.seconds.formatted(.number.precision(.fractionLength(1))) + " s · " + report.requests.counted("request", "requests")
        Text(report.fetched.isEmpty ? "Nothing changed on \(tracker.name) since the last check · \(timing)" : "Read in \(timing) · " + report.fetched.map(\.rawValue).joined(separator: ", "))
            .font(.system(size: 13, weight: .semibold)).accessibilityIdentifier(id + "-timing")
        Text(counts(library)).font(.caption).foregroundStyle(.secondary)
        if !report.unavailable.isEmpty {
            Text("\(tracker.name) didn’t give: " + report.unavailable.map(\.rawValue).joined(separator: ", ") + ". They’re asked for again next time.").font(.caption).foregroundStyle(.secondary)
        }
        if report.skipped > 0 || compared.unmatchedTraktTitles > 0 {
            Text("\(report.skipped) unreadable items · \(compared.unmatchedTraktTitles) titles without a TMDB id").font(.caption).foregroundStyle(.secondary)
        }
        if compared.matches {
            Label("Matches your diary: \(compared.matchingPlays.counted("play", "plays"))", systemImage: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent).accessibilityIdentifier(id + "-match")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(compared.matchingPlays.counted("play", "plays")) match. Differences:").font(.system(size: 13, weight: .semibold))
                differences("Only on \(tracker.name)", compared.onlyOnTrakt)
                differences("Only in the diary", compared.onlyInDiary)
                differences("Ratings", compared.ratingDifferences)
                differences("Planned / watchlist", compared.plannedDifferences)
                differences("Favourites", compared.favoriteDifferences)
                differences("Dropped", compared.droppedDifferences)
            }.accessibilityElement(children: .contain).accessibilityIdentifier(id + "-differences")
        }
    }
    private func counts(_ library: TraktLibrary) -> String {
        let can = tracker.capabilities
        var parts = [library.plays.count.counted(can.keepsRewatches ? "play" : "watch", can.keepsRewatches ? "plays" : "watches"),
                     library.ratings.count.counted("rating", "ratings"), "\(library.watchlist.count) planned"]
        if can.holdsFavourites { parts.append(library.favorites.count.counted("favourite", "favourites")) }
        if can.holdsDropped { parts.append("\(library.dropped.count) dropped") }
        if can.noteLimit != nil { parts.append(library.notes.count.counted("note", "notes")) }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder private func differences(_ heading: String, _ list: [TraktComparison.Difference]) -> some View {
        if !list.isEmpty {
            Text("\(heading): \(list.count)").font(.caption.weight(.semibold))
            ForEach(Array(list.prefix(3).enumerated()), id: \.offset) { _, item in
                Text("· \(item.title) — \(item.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
