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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Awards and nominations").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                // The round chevron every section uses for "see all".
                SectionMoreLink(label: "See all awards and nominations", value: destination, identifier: "title-awards-all")
            }
            if rows.isEmpty {
                NavigationLink(value: destination) {
                    Label("View award history", systemImage: "trophy").font(.subheadline).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            } else {
                // One card: a row per ceremony, its wins and other nominations as small counters.
                NavigationLink(value: destination) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.prefix(5).enumerated()), id: \.element.ceremony) { index, row in
                            if index > 0 { Divider().padding(.leading, 44) }
                            HStack(spacing: 8) {
                                // The row's place, as the ranked lists elsewhere.
                                Text("\(index + 1).").font(.system(size: 15, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(index < 3 ? HomeStyle.chipText : HomeStyle.secondary)
                                    .frame(width: 22, alignment: .leading)
                                Text(row.ceremony).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 8)
                                if row.wins > 0 { counter("trophy.fill", row.wins, tint: Color(themed: "#e7ca90")) }
                                if row.nominations > 0 { counter("medal", row.nominations, tint: .secondary) }
                            }
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.ceremony): \(row.wins) won, \(row.nominations) more nominations")
                        }
                    }
                    .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .task(id: [String(describing: route), imdbID ?? ""]) {
            let movie = route.kind == .movie
            let local = (try? await TitleAwardHistory.shared.titleRecords(route)) ?? []
            guard !Task.isCancelled else { return }
            if !local.isEmpty && rows.isEmpty { rows = TitleAwardsPage.ceremonyCounts(AwardNames.merge(archive: local, people: [], movie: movie)) }
            let people = store.isPreview ? [] : ((try? await TitleAwardHistory.shared.peopleRecords(route, imdbID: imdbID)) ?? [])
            guard !Task.isCancelled else { return }
            rows = TitleAwardsPage.ceremonyCounts(AwardNames.merge(archive: local, people: people, movie: movie))
        }
    }
}

/// A small counter: the icon and the number in a soft capsule.
private func counter(_ symbol: String, _ count: Int, tint: Color) -> some View {
    HStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
        Text(count.formatted()).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(HomeStyle.primary)
    }.padding(.horizontal, 8).frame(height: 24).background(tint.opacity(0.14), in: Capsule())
}

/// A count beside its icon: "🏆 2", "🎖 3".
private struct AwardCountStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
            configuration.title.font(.system(size: 15)).foregroundStyle(.secondary).monospacedDigit()
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

    /// One ceremony's awards on the page, most decorated ceremony first.
    private struct Ceremony: Identifiable {
        let name: String
        let rows: [TitleAwardRecord]
        var id: String { name }
        var wins: Int { rows.filter(\.won).count }
    }
    private func ceremonies(_ rows: [TitleAwardRecord]) -> [Ceremony] {
        let short = ["Actor Awards": "SAG Awards", "Academy Awards": "Oscars"]
        return Dictionary(grouping: rows) { AwardEdition($0).ceremony }.map { name, rows in
            Ceremony(name: short[name] ?? name, rows: rows.sorted {
                if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) > ($1.year ?? 0) }
                if $0.won != $1.won { return $0.won }
                return $0.category.localizedStandardCompare($1.category) == .orderedAscending
            })
        }.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            if $0.rows.count != $1.rows.count { return $0.rows.count > $1.rows.count }
            return $0.name < $1.name
        }
    }
    private var artwork: String? {
        store.libraryIdentity(CatalogItem(id: route.id, mediaType: route.kind, name: title)).flatMap { store.title($0) }.flatMap { $0.backdrop ?? $0.poster }
    }

    var body: some View {
        // Explore's layout: the show's picture at the top, its name, then the awards by ceremony.
        ExploreBrowsePage(title: title, symbol: "trophy.fill", subtitle: "Awards & Nominations", artwork: artwork) {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !records.isEmpty {
                    let counts = Self.ceremonyCounts(records)
                    HStack(spacing: 10) {
                        summaryChip("trophy.fill", counts.map(\.wins).reduce(0, +), "wins", tint: Color(themed: "#e7ca90"))
                        summaryChip("medal", counts.map(\.nominations).reduce(0, +), "nominations", tint: .secondary)
                        Spacer(minLength: 0)
                    }
                    Picker("Award results", selection: $winsOnly) {
                        Text("All").tag(false)
                        Text("Wins").tag(true)
                    }.pickerStyle(.segmented)
                    let groups = ceremonies(records.filter { !winsOnly || $0.won })
                    ForEach(groups) { ceremony in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(ceremony.name).font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 8)
                                // Wins and the other nominations, each with its own icon (as the title page's card).
                                if ceremony.wins > 0 { counter("trophy.fill", ceremony.wins, tint: Color(themed: "#e7ca90")) }
                                if ceremony.rows.count > ceremony.wins { counter("medal", ceremony.rows.count - ceremony.wins, tint: .secondary) }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(ceremony.rows.enumerated()), id: \.element) { index, row in
                                    if index > 0 { Divider().padding(.leading, 60) }
                                    result(row)
                                }
                            }
                            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                        }
                    }
                    if groups.isEmpty && !loading {
                        Text("No wins recorded in this history.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading award credits…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let issue {
                    if records.isEmpty { RetryNotice(message: issue) { attempt += 1 } }
                    else {
                        // Some awards are here: a quiet line, not a card in the middle of them.
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                            Text("Some people's awards didn't load.").foregroundStyle(.secondary)
                            Button("Try again") { attempt += 1 }.fontWeight(.semibold)
                        }.font(.footnote).accessibilityElement(children: .combine)
                    }
                }
                if !loading && records.isEmpty && issue == nil {
                    ContentUnavailableView("No award records", systemImage: "trophy")
                }
                if !records.isEmpty {
                    Text("From the TMDB Awards Database and Wikidata; coverage varies by ceremony and year.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }
        .task(id: attempt) { await load() }
    }

    private func summaryChip(_ symbol: String, _ count: Int, _ label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(count.formatted()).font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(HomeStyle.primary)
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).frame(height: 34).background(HomeStyle.card, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .accessibilityElement(children: .combine)
    }

    /// One award: its year, the category and who it went to, and a trophy (won) or medal.
    private func result(_ row: TitleAwardRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.year.map(String.init) ?? "—").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.category).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recipient = row.recipient { Text(recipient).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Image(systemName: row.won ? "trophy.fill" : "medal").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(row.won ? Color(themed: "#e7ca90") : Color.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([row.year.map(String.init), row.category, row.recipient, row.won ? "won" : "nominated"].compactMap { $0 }.joined(separator: ", "))
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
