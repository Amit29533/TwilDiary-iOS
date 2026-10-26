import SwiftUI
import TwilDiaryCore

struct PersonView: View {
    let route: PersonRoute
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var person: PersonDetails?
    @State private var failure: String?
    @State private var expanded = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let person {
                    VStack(alignment: .leading, spacing: 28) {
                        header(person)
                        VStack(alignment: .leading, spacing: 28) {
                            if let role = route.sourceRole, let title = route.sourceTitle, !role.isEmpty, !title.isEmpty {
                                Button(role + " in " + title) { dismiss() }.font(.system(size: 15)).buttonStyle(.plain)
                            }
                            if !person.biography.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.biography).font(.system(size: 16)).lineSpacing(6).foregroundStyle(.secondary).lineLimit(expanded ? nil : 4)
                                    Button(expanded ? "Less" : "More") { expanded.toggle() }.font(.system(size: 14)).frame(minHeight: 36).accessibilityLabel(expanded ? "Collapse biography" : "Expand biography")
                                }
                            }
                            facts(person)
                            server(person)
                            let sections = PersonSections(person: person, workspace: store.workspace)
                            shelf("Known for", person: person, kind: .knownFor, items: sections.knownFor)
                            shelf("Shows", person: person, kind: .shows, items: sections.shows)
                            shelf("Movies", person: person, kind: .movies, items: sections.movies)
                            Link("Biography, credits and artwork: TMDB", destination: URL(string: "https://www.themoviedb.org/person/\(person.id)")!).font(.system(size: 13)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14)
                    }.padding(.bottom, 28)
                        .background(alignment: .top) {
                            Artwork(path: CatalogTools.image(person.profilePath, size: "w780"), title: person.name).frame(height: 310 + geometry.safeAreaInsets.top)
                                .overlay(LinearGradient(stops: [.init(color: .black.opacity(2.0 / 15), location: 0), .init(color: .black.opacity(7.0 / 15), location: 0.55), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)).offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false).accessibilityHidden(true)
                        }
                } else if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                else { DiaryLoadingPlaceholder(height: 310, label: "Loading person").padding(14) }
            }.scrollClipDisabled().diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .task(id: route.id) { if person == nil { await load() } }
        }
    }
    private func header(_ person: PersonDetails) -> some View {
        HStack(spacing: 14) {
            Artwork(path: CatalogTools.image(person.profilePath), title: person.name).frame(width: 80, height: 80).clipShape(Circle()).overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2))
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.system(size: 26.4, weight: .semibold)).tracking(-1.1).padding(.bottom, 4)
                if let birthday = person.birthday { Text("Born " + personDate(birthday)).font(.system(size: 13)).foregroundStyle(.secondary) }
                if !person.birthplace.isEmpty { Text(person.birthplace).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.top, 145).padding(.bottom, 10)
    }
    private func facts(_ person: PersonDetails) -> some View {
        let sections = PersonSections(person: person, workspace: store.workspace)
        let earliest = person.credits.filter { $0.mediaType == .movie && ($0.year ?? -1) >= (Int(person.birthday?.prefix(4) ?? "0") ?? 0) && ($0.year ?? Int.max) <= DiaryDate.calendar().component(.year, from: store.now) }.min { ($0.year ?? 0) < ($1.year ?? 0) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Facts & trivia").font(.system(size: 20, weight: .semibold))
            VStack(spacing: 0) {
                if !person.department.isEmpty { fact("Known for", person.department) }
                if !person.birthplace.isEmpty { fact("Birthplace", person.birthplace) }
                if let death = person.deathday { fact("Died", personDate(death)) }
                if let aliases = person.aliases, !aliases.isEmpty { fact("Also known as", aliases.joined(separator: " · ")) }
                if let earliest { fact("Earliest listed movie", earliest.name + " · " + String(earliest.year ?? 0)) }
                fact("Listed credits", "\(sections.movies.count) movies · \(sections.shows.count) shows")
            }.padding(.horizontal, 16).padding(.vertical, 4).background(.white.opacity(0.016), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        let key = label.lowercased().replacingOccurrences(of: " ", with: "-")
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(label).foregroundStyle(.secondary).frame(width: 104, alignment: .leading).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("person-fact-" + key + "-label")
                Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("person-fact-" + key + "-value")
            }.font(.system(size: 13)).padding(.vertical, 12)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }
    private func server(_ person: PersonDetails) -> some View {
        let sections = PersonSections(person: person, workspace: store.workspace)
        return VStack(alignment: .leading, spacing: 14) {
            sectionHeading("On your server", route: PersonFilmographyRoute(person: person.id, section: .credits, onServer: true))
            if sections.localShows.isEmpty && sections.localMovies.isEmpty { Text("None of these titles are on your disks yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
            shelf("Shows", person: person, kind: .shows, items: sections.localShows, onServer: true)
            shelf("Movies", person: person, kind: .movies, items: sections.localMovies, onServer: true)
        }
    }
    @ViewBuilder private func shelf(_ label: String, person: PersonDetails, kind: PersonSection, items: [CatalogItem], onServer: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading(label + (kind == .shows || kind == .movies ? " \(items.count)" : ""), route: PersonFilmographyRoute(person: person.id, section: kind, onServer: onServer))
                PersonCreditShelf(items: Array(items.prefix(12)))
            }
        }
    }
    private func sectionHeading(_ label: String, route: PersonFilmographyRoute) -> some View {
        HStack { Text(label).font(.system(size: 20, weight: .semibold)); Spacer(minLength: 4); NavigationLink(value: route) { Text("View more").font(.system(size: 13)) }.accessibilityIdentifier("person-more-" + route.section.rawValue + (route.onServer ? "-server" : "")) }
    }
    private func load() async {
        failure = nil
        do { let result = try await store.person(route.id); guard !Task.isCancelled else { return }; person = result.person }
        catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct PersonCreditShelf: View {
    let items: [CatalogItem]
    @Environment(DiaryStore.self) private var store
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) { NavigationLink(value: saved) { CatalogPoster(item: item) } }
                        else { NavigationLink(value: item.route) { CatalogPoster(item: item) } }
                        let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
                        if !role.isEmpty { Text(role).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    }.containerRelativeFrame(.horizontal, count: 3, spacing: 12).buttonStyle(.plain)
                }
            }
        }.scrollIndicators(.hidden)
    }
}

struct PersonFilmographyView: View {
    let route: PersonFilmographyRoute
    @Environment(DiaryStore.self) private var store
    @AppStorage("catalogGrid") private var grid = true
    @State private var person: PersonDetails?
    @State private var failure: String?
    @State private var filters: PersonFilmographyFilters
    @State private var showSearch = false
    @State private var shown = 40
    init(route: PersonFilmographyRoute) { self.route = route; _filters = State(initialValue: PersonFilmographyFilters(section: route.section, onServer: route.onServer)) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    HStack(alignment: .center, spacing: 8) {
                        Text(person.map { filters.heading(person: $0, section: route.section) } ?? route.section.label)
                            .font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("person-filmography-heading")
                        Spacer(minLength: 0)
                        CollectionLayoutToggle(grid: $grid, collection: "catalog")
                    }
                    if let person {
                        if let error = filters.error { Text(error).font(.system(size: 13)).foregroundStyle(.secondary) }
                        else {
                            let items = filters.applying(person: person, workspace: store.workspace, section: route.section)
                            Text("\(items.count) \(items.count == 1 ? "title" : "titles")" + (filters.onServer ? " · On your server" : "")).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("person-result-count")
                            if items.isEmpty { ContentUnavailableView("No titles in this mix", systemImage: "film", description: Text("Try another genre, year, rating or collection.")) }
                            else { CatalogGrid(items: Array(items.prefix(shown)), showsLayoutToggle: false) }
                            if shown < items.count { Button("Load more") { shown += 40 }.buttonStyle(.glass).frame(maxWidth: .infinity) }
                        }
                    } else if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else { DiaryLoadingPlaceholder(height: 240, label: "Loading filmography").padding(14) }
                }.padding(.horizontal, 14).padding(.bottom, 100)
            }.scrollDismissesKeyboard(.interactively)
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showSearch.toggle() } label: { DiaryIcon(name: "search", size: 22) }.accessibilityLabel("Search").accessibilityIdentifier("search-person-filmography") } }
            .task(id: route) { await load() }.onChange(of: filters) { _, _ in shown = 40 }
    }
    private func load() async {
        failure = nil
        do { let result = try await store.person(route.person); guard !Task.isCancelled else { return }; person = result.person }
        catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private func personDate(_ value: String) -> String {
    guard let date = DiaryDate.parse(value + "T00:00:00Z") else { return value }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "d MMMM yyyy"
    return formatter.string(from: date)
}
