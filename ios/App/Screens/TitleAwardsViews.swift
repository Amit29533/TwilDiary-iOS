import SwiftUI
import TwilDiaryCore

struct TitleAwardsSection: View {
    let route: CatalogRoute
    let title: String
    let imdbID: String?
    var body: some View {
        NavigationLink(value: ShowPageRoute.titleAwards(route, title: title, imdbID: imdbID)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ShowSectionHeading(title: "Awards & Nominations")
                    Label("View award history", systemImage: "trophy")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                RoundChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all awards and nominations")
        .accessibilityIdentifier("title-awards-all")
    }
}

private struct AwardEdition: Hashable {
    let year: Int?
    let ceremony: String

    init(_ row: TitleAwardRecord) {
        year = row.year
        switch row.ceremony {
        case "Primetime Emmy Award", "Primetime Emmy Awards": ceremony = "Emmy Awards"
        case "Golden Globe Award", "Golden Globe Awards": ceremony = "Golden Globes"
        case "Academy Award": ceremony = "Academy Awards"
        default: ceremony = row.ceremony
        }
    }

    var heading: String { year.map { "\(ceremony) · \($0)" } ?? ceremony }
}

struct TitleAwardsPage: View {
    let route: CatalogRoute
    let title: String
    let imdbID: String?
    @Environment(DiaryStore.self) private var store
    @State private var records: [TitleAwardRecord] = []
    @State private var loading = true
    @State private var issue: String?
    @State private var attempt = 0
    @State private var winsOnly = false

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if !records.isEmpty {
                    Picker("Award results", selection: $winsOnly) {
                        Text("All").tag(false)
                        Text("Wins").tag(true)
                    }.pickerStyle(.segmented)
                    let groups = Dictionary(grouping: records.filter { !winsOnly || $0.won }, by: AwardEdition.init)
                    let editions = groups.keys.sorted {
                        if $0.year != $1.year { return ($0.year ?? 0) > ($1.year ?? 0) }
                        return $0.ceremony.localizedStandardCompare($1.ceremony) == .orderedAscending
                    }
                    ForEach(editions, id: \.self) { edition in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(edition.heading).font(.headline).accessibilityAddTraits(.isHeader)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array((groups[edition] ?? []).enumerated()), id: \.element) { index, row in
                                    if index > 0 { Divider().padding(.leading, 48) }
                                    result(row)
                                }
                            }
                            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    if editions.isEmpty && !loading {
                        Text("No wins recorded in this history.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading award credits…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let issue { RetryNotice(message: issue) { attempt += 1 } }
                if !loading && records.isEmpty && issue == nil {
                    ContentUnavailableView("No award records", systemImage: "trophy")
                }
                if !records.isEmpty {
                    Text("Available records from the TMDB Awards Database and Wikidata. Coverage varies by ceremony and year.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }
        .diaryScreenBackground().navigationTitle("Awards & Nominations")
        .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .task(id: attempt) { await load() }
    }

    private func result(_ row: TitleAwardRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.won ? "trophy.fill" : "rosette")
                .foregroundStyle(row.won ? Color.orange : Color.secondary)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.category).font(.body.weight(.semibold)).foregroundStyle(HomeStyle.primary)
                if let recipient = row.recipient { Text(recipient).font(.subheadline).foregroundStyle(.secondary) }
                Text(row.won ? "Won" : "Nominated").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        loading = true; issue = nil
        var local: [TitleAwardRecord] = []
        var failures: [String] = []
        do { local = try await TitleAwardHistory.shared.titleRecords(route) }
        catch { failures.append("Title awards couldn’t be loaded.") }
        guard !Task.isCancelled else { return }
        if records.isEmpty { records = Self.sortedRecords(local) }
        var people: [TitleAwardRecord] = []
        if !store.isPreview {
            do { people = try await TitleAwardHistory.shared.peopleRecords(route, imdbID: imdbID) }
            catch { failures.append("Individual award credits couldn’t be loaded.") }
        }
        guard !Task.isCancelled else { return }
        records = Self.sortedRecords(local + people)
        issue = failures.isEmpty ? nil : failures.joined(separator: " ")
        loading = false
    }

    static func sortedRecords(_ input: [TitleAwardRecord]) -> [TitleAwardRecord] {
        // A winner is often also listed as a nominee for the same award and recipient.
        var seen = Set<TitleAwardRecord>()
        // Suppress a work-only row when its exact result is explained by named credits.
        func key(_ row: TitleAwardRecord, includeOutcome: Bool, includeRecipient: Bool) -> TitleAwardRecord {
            .init(year: row.year, ceremony: AwardEdition(row).ceremony, category: row.category,
                  won: includeOutcome && row.won, recipient: includeRecipient ? row.recipient : nil)
        }
        let credited = Set(input.filter { $0.year != nil && $0.recipient != nil }
            .map { key($0, includeOutcome: true, includeRecipient: false) })
        return input.sorted {
            if $0.won != $1.won { return $0.won }
            if $0.category != $1.category { return $0.category.localizedStandardCompare($1.category) == .orderedAscending }
            return ($0.recipient ?? "").localizedStandardCompare($1.recipient ?? "") == .orderedAscending
        }.filter {
            guard $0.recipient != nil || !credited.contains(key($0, includeOutcome: true, includeRecipient: false)) else {
                return false
            }
            return seen.insert(key($0, includeOutcome: false, includeRecipient: true)).inserted
        }
    }
}
