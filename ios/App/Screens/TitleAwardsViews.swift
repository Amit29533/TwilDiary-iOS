import SwiftUI
import TwilDiaryCore

/// The title page's awards: each ceremony with how many it won and how many more it was
/// nominated for, the most decorated first, and See all for the whole history.
struct TitleAwardsSection: View {
    let route: CatalogRoute
    let title: String
    let imdbID: String?
    @Environment(DiaryStore.self) private var store
    @State private var rows: [TitleAwardsPage.CeremonyCount] = []

    var body: some View {
        let destination = ShowPageRoute.titleAwards(route, title: title, imdbID: imdbID)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Awards and nominations").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                NavigationLink("See all", value: destination).font(.system(size: 17, weight: .semibold)).foregroundStyle(ThemeStore.accent)
                    .frame(minHeight: 44).buttonStyle(.plain).accessibilityLabel("See all awards and nominations")
                    .accessibilityIdentifier("title-awards-all")
            }
            if rows.isEmpty {
                NavigationLink(value: destination) {
                    Label("View award history", systemImage: "trophy").font(.subheadline).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            } else {
                NavigationLink(value: destination) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows.prefix(5), id: \.ceremony) { row in
                            HStack(spacing: 10) {
                                Text(row.ceremony).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                if row.wins > 0 {
                                    Label("\(row.wins)", systemImage: "trophy.fill").labelStyle(AwardCountStyle(tint: Color(themed: "#e7ca90")))
                                }
                                if row.nominations > 0 {
                                    Label("\(row.nominations)", systemImage: "medal").labelStyle(AwardCountStyle(tint: .secondary))
                                }
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.ceremony): \(row.wins) won, \(row.nominations) more nominations")
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .task(id: route) {
            let local = (try? await TitleAwardHistory.shared.titleRecords(route)) ?? []
            let people = store.isPreview ? [] : ((try? await TitleAwardHistory.shared.peopleRecords(route, imdbID: imdbID)) ?? [])
            guard !Task.isCancelled else { return }
            rows = TitleAwardsPage.ceremonyCounts(AwardNames.merge(archive: local, people: people, movie: route.kind == .movie))
        }
    }
}

/// A count beside its icon: "🏆 2", "🎖 3".
private struct AwardCountStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
            configuration.title.font(.system(size: 17)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

extension TitleAwardsPage {
    struct CeremonyCount: Equatable {
        let ceremony: String
        let wins: Int
        let nominations: Int
    }
    /// Each ceremony's awards, counted once per year and category however many people shared it:
    /// the ones it won, and the ones it was only nominated for. Most wins first, then most in all.
    static func ceremonyCounts(_ records: [TitleAwardRecord]) -> [CeremonyCount] {
        let shortNames = ["Actor Awards": "SAG Awards", "Academy Awards": "Oscars"]
        var won: [String: Set<String>] = [:], nominated: [String: Set<String>] = [:]
        for record in records {
            let ceremony = AwardEdition(record).ceremony
            let key = "\(record.year ?? 0)|\(record.category)"
            if record.won { won[ceremony, default: []].insert(key) } else { nominated[ceremony, default: []].insert(key) }
        }
        let ceremonies = Set(won.keys).union(nominated.keys)
        return ceremonies.map { ceremony in
            let wins = won[ceremony] ?? []
            return CeremonyCount(ceremony: shortNames[ceremony] ?? ceremony, wins: wins.count, nominations: (nominated[ceremony] ?? []).subtracting(wins).count)
        }.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            if $0.wins + $0.nominations != $1.wins + $1.nominations { return $0.wins + $0.nominations > $1.wins + $1.nominations }
            return $0.ceremony < $1.ceremony
        }
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
        let movie = route.kind == .movie
        if records.isEmpty { records = Self.sortedRecords(AwardNames.merge(archive: local, people: [], movie: movie)) }
        var people: [TitleAwardRecord] = []
        if !store.isPreview {
            do { people = try await TitleAwardHistory.shared.peopleRecords(route, imdbID: imdbID) }
            catch { failures.append("Individual award credits couldn’t be loaded.") }
        }
        guard !Task.isCancelled else { return }
        records = Self.sortedRecords(AwardNames.merge(archive: local, people: people, movie: movie))
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
