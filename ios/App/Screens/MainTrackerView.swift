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
                TrackerPreviewPanel(tracker: tracker)
                Text("Your diary still lives on your server until the switch-over. Choosing here changes nothing yet; it picks which service the preview reads.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("Main tracker").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }

    private func row(_ option: MainTracker) -> some View {
        HStack(alignment: .top, spacing: 14) {
            BrandLogo(service: option.brand, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(option.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                Text(option.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: option == tracker ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(option == tracker ? theme.accent : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }.padding(14).frame(minHeight: 64).contentShape(Rectangle())
    }
}

extension MainTracker {
    var brand: BrandLogo.Service {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Direct from \(tracker.name) (preview)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                Text(intro).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let report { reportView(report) }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id + "-error")
                }
                Button {
                    Task { if tracker == .trakt { await trakt.check(store: store) } else { await others.check(tracker, store: store) } }
                } label: {
                    Label(running ? "Reading \(tracker.name)…" : "Check now", systemImage: "bolt.horizontal.circle").frame(maxWidth: .infinity)
                }.font(.subheadline).buttonStyle(.diarySecondary).disabled(running).accessibilityIdentifier(id + "-check")
            }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
                .smoothChange(of: report?.comparison.matchingPlays ?? -1)
        }.accessibilityElement(children: .contain).accessibilityIdentifier(id + "-panel")
    }

    private var intro: String {
        switch tracker {
        case .trakt: "Reads your Trakt history, ratings, watchlist, favourites and dropped shows straight from Trakt and compares them with your diary. Nothing is changed."
        case .simkl: "Reads your Simkl library (watches, ratings, plan to watch, dropped and memos) and compares it with your diary. Simkl keeps one watch per episode, so rewatches aren’t counted as differences. Nothing is changed."
        case .mdblist: "Reads your MDBList watched items, ratings, dropped titles and watchlist and compares them with your diary. MDBList’s read format isn’t published, so items it can’t read are counted, not guessed. Nothing is changed."
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
