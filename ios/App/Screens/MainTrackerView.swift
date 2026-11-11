import SwiftUI
import TwilDiaryCore

/// Settings → Main tracker: which service is the diary (Trakt, Simkl or MDBList). For now the
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
                Text("Choose the service that holds your diary. Whatever it can’t keep stays in your Cloudflare backup, along with file locations, tags and people you’ve hearted.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(MainTracker.allCases.enumerated()), id: \.element) { index, option in
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
                if tracker != .trakt, !store.providerSettings.config(for: tracker == .simkl ? .simkl : .mdblist).isAuthenticated {
                    NavigationLink(value: tracker == .simkl ? AppDestination.simkl : AppDestination.mdblist) {
                        Label("Connect \(tracker.name) first", systemImage: "link").frame(maxWidth: .infinity)
                    }.font(.subheadline).buttonStyle(.diarySecondary).accessibilityIdentifier("main-tracker-connect")
                }
                if tracker == .trakt { diarySource } else { trackerDiarySource }
                TrackerPreviewPanel(tracker: tracker)
                Text(recordNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("main-tracker-record")
            }.padding(14).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("Main tracker").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }

    /// Where the diary lives (phase 4c switches it from the server to a service).
    private var recordNote: String {
        guard let record = store.serverRecord else {
            return "Your diary still lives on your server until the switch-over. Choosing here picks which service the preview reads and where “Make \(tracker.name) match the diary” writes."
        }
        let until = store.serverRecordReadOnlyUntil.map { " until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return "\(record.name) holds your diary now. Your server keeps a read-only copy of its old watches and ratings\(until); notes, tags, favourites, Queue and files stay on your server."
    }

    /// Phase 4a: browse the whole app with the diary built from Trakt (plus your server's extras),
    /// before Trakt becomes the record. Editing is paused meanwhile; switching back is instant.
    private var diarySource: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $store.diaryFromTrakt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show my diary from Trakt").font(.subheadline.weight(.semibold))
                    Text("Every screen shows your Trakt watches, ratings, Planned, favourites and dropped, with posters, tags, notes and files from your server. Your edits go to Trakt; notes, tags, Queue and Trash stay on your server.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("diary-from-trakt")
            if store.diaryFromTrakt {
                Label("Your diary comes from Trakt. Turn this off to go back to your server’s diary.", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            }
        }.padding(14).background(theme.field, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }

    /// Phase 5: the same from Simkl or MDBList; edits go to it.
    private var trackerDiarySource: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { store.diaryFromTracker == tracker }, set: { store.diaryFromTracker = $0 ? tracker : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show my diary from \(tracker.name)").font(.subheadline.weight(.semibold))
                    Text("Every screen shows your \(tracker.name) watches, ratings, Planned and dropped, with posters, tags, notes, favourites and files from your server. Your edits go to \(tracker.name); notes, tags, favourites, Queue and Trash stay on your server.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("diary-from-" + tracker.rawValue)
            if store.diaryFromTracker == tracker {
                Label("Your diary comes from \(tracker.name). Turn this off to go back to your server’s diary.", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
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
        switch self { case .trakt: .trakt; case .simkl: .simkl; case .mdblist: .mdblist }
    }
    var provider: SyncProviderKind {
        switch self { case .trakt: .trakt; case .simkl: .simkl; case .mdblist: .mdblist }
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
    private var holdsDiary: Bool { tracker == .trakt ? store.traktHoldsDiary : (store.diaryService == tracker || store.serverRecord == tracker) }
    @State private var confirmMatch = false
    @State private var writeThroughError: String?
    @State private var savingWriteThrough = false

    var body: some View {
        if tracker == .trakt && store.traktHoldsDiary { traktSyncCard } else { previewCard }
    }

    /// Trakt holds the diary: just whether everything is on Trakt, and what's still going there.
    private var traktSyncCard: some View {
        let compared = report?.comparison
        let waiting = [compared?.onlyInDiary, compared?.ratingDifferences, compared?.plannedDifferences,
                       compared?.favoriteDifferences, compared?.droppedDifferences].compactMap { $0 }.flatMap { $0 }
        let matched = report != nil && waiting.isEmpty && trakt.pending.isEmpty
        let headline = trakt.writeProgress ?? (running ? "Checking Trakt…" : matched ? "Everything is on Trakt"
            : !waiting.isEmpty ? (waiting.count == 1 ? "1 change going to Trakt" : "\(waiting.count) changes going to Trakt")
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
                if !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(waiting.prefix(5).enumerated()), id: \.offset) { _, item in
                            Text(item.title).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }
                        if waiting.count > 5 { Text("and \(waiting.count - 5) more").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary) }
                    }.padding(.leading, 48)
                }
                if !trakt.pending.isEmpty && !waiting.isEmpty {
                    Label(trakt.pending.count.counted("change", "changes") + " waiting to send", systemImage: "icloud.and.arrow.up")
                        .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).accessibilityIdentifier("trakt-pending")
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-error") }
                Button {
                    Task {
                        await trakt.check(store: store)
                        if trakt.plan?.isEmpty == false { await trakt.makeTraktMatch(store: store) }
                    }
                } label: {
                    Label(running || trakt.writing ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(running || trakt.writing).accessibilityIdentifier(id + "-check")
            }.padding(15).modifier(SettingsCard())
        }.accessibilityElement(children: .contain).accessibilityIdentifier(id + "-panel")
    }

    private var previewCard: some View {
        // Design (boards 7 and 13): DIRECT FROM SIMKL · Preview · ⓘ, then one card with Check now.
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
                if tracker == .trakt { matchSection } else if holdsDiary {
                    Text("\(tracker.name) holds your diary, so nothing is sent to it from here. The differences above are against your old server copy (kept read-only), for reference.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-holds-diary")
                } else { trackerMatchSection }
                Button {
                    Task { if tracker == .trakt { await trakt.check(store: store) } else { await others.check(tracker, store: store) } }
                } label: {
                    Label(running ? "Reading \(tracker.name)…" : "Check now", systemImage: "arrow.clockwise")
                }.buttonStyle(SettingsWideButtonStyle()).disabled(running || trakt.writing || others.writing != nil).accessibilityIdentifier(id + "-check")
            }.padding(15).modifier(SettingsCard())
                .smoothChange(of: report?.comparison.matchingPlays ?? -1)
        }.accessibilityElement(children: .contain).accessibilityIdentifier(id + "-panel")
    }

    /// Phase 2: bring Trakt in line with the diary, after showing exactly what will be sent.
    @ViewBuilder private var matchSection: some View {
        let plan = report != nil ? trakt.plan : nil
        let fill = store.traktHoldsDiary
        if fill {
            Text(plan?.isEmpty == false
                 ? "Trakt holds your diary. The list above is what your old server copy has and Trakt doesn’t. It’s copied in automatically once; if anything is still listed, tap below to try again. Anything newer on Trakt stays as it is."
                 : "Trakt holds your diary and has everything from your old server copy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-holds-diary")
        } else {
        Toggle(isOn: Binding(get: { store.traktWriteThrough }, set: { on in
            savingWriteThrough = true; writeThroughError = nil
            Task {
                do { try await store.setTraktWriteThrough(on) } catch { writeThroughError = error.localizedDescription }
                savingWriteThrough = false
            }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send my edits to Trakt as I make them").font(.subheadline.weight(.semibold))
                Text("Watches (at their exact time), ratings, Planned, favourites and dropped shows go straight to Trakt.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(savingWriteThrough).accessibilityIdentifier("trakt-write-through")
        if let writeThroughError { Text(writeThroughError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        if let progress = trakt.writeProgress {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(.secondary) }
        } else if let result = trakt.writeResult {
            Label(result, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("trakt-match-result")
        }
        if let plan, !plan.isEmpty, !trakt.writing {
            Button { confirmMatch = true } label: {
                Label(fill ? "Copy what’s missing into Trakt" : "Make Trakt match the diary",
                      systemImage: fill ? "square.and.arrow.down.on.square" : "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }.font(.subheadline.weight(.semibold)).buttonStyle(.glassProminent).disabled(running).accessibilityIdentifier("trakt-make-match")
                .confirmationDialog(fill ? "Copy into Trakt?" : "Make Trakt match the diary?", isPresented: $confirmMatch, titleVisibility: .visible) {
                    Button("Send to Trakt") { Task { await trakt.makeTraktMatch(store: store) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(plan.summary.map { "• " + $0 }.joined(separator: "\n")
                         + "\n\nNothing is removed from your Trakt history. Watches only on Trakt stay and come into the diary on their own.")
                }
        }
    }

    /// Phase 5: the same for Simkl and MDBList, within what each keeps.
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
            }.font(.subheadline.weight(.semibold)).buttonStyle(.glassProminent).disabled(running).accessibilityIdentifier(tracker.rawValue + "-make-match")
                .confirmationDialog("Make \(tracker.name) match the diary?", isPresented: $confirmMatch, titleVisibility: .visible) {
                    Button("Send to \(tracker.name)") { Task { await others.makeMatch(tracker, store: store) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(plan.summary.map { "• " + $0 }.joined(separator: "\n")
                         + "\n\nNothing is removed from your \(tracker.name) history. \(tracker.name) keeps one watch per episode, so the first is sent and rewatches stay in your diary.")
                }
        }
    }

    private var intro: String {
        switch tracker {
        case .trakt: "Reads your Trakt history, ratings, watchlist, favourites and dropped shows straight from Trakt and compares them with your diary. Nothing is changed."
        case .simkl: "Reads your Simkl library (watches, ratings, plan to watch, dropped and memos) and compares it with your diary. Simkl keeps one watch per episode, so rewatches aren’t counted as differences. Nothing changes until you send."
        case .mdblist: "Reads your MDBList watched items, ratings, dropped shows and watchlist and compares them with your diary. Items it can’t read are counted, not guessed. Nothing changes until you send."
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
