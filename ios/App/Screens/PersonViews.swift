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
        Group {
            if let person {
                PersonProfilePage(name: person.name, nativeName: person.aliases?.first, role: person.department,
                                  image: CatalogTools.image(person.profilePath, size: "w780"), kind: .cast, ref: person.id,
                                  favouriteSubtitle: person.department, identifier: "person") {
                    VStack(alignment: .leading, spacing: 22) {
                        details(person)
                        if let role = route.sourceRole, let title = route.sourceTitle, !role.isEmpty, !title.isEmpty {
                            Button(role + " in " + title) { dismiss() }.font(.system(size: 15)).buttonStyle(.plain)
                                .foregroundStyle(.primary).accessibilityIdentifier("person-source-role")
                        }
                        ProfileBiography(text: AttributedString(person.biography), expanded: $expanded)
                        server(person)
                        let sections = store.personSections(person)
                        shelf("Known for", person: person, kind: .knownFor, items: sections.knownFor)
                        shelf("Shows", person: person, kind: .shows, items: sections.shows)
                        shelf("Movies", person: person, kind: .movies, items: sections.movies)
                    }
                }
            } else {
                ScrollView {
                    if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                    else { DiaryLoadingPlaceholder(height: 310, label: "Loading person").padding(14) }
                }.diaryScreenBackground().navigationTitle("").toolbar(.visible, for: .navigationBar)
            }
        }.task(id: route.id) { if person == nil { await load() } }
    }
    private func details(_ person: PersonDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                if let birthday = person.birthday {
                    ProfileDetailChip(icon: "calendar", label: "Born", value: personDate(birthday), identifier: "person-birthday")
                }
                if !person.birthplace.isEmpty {
                    ProfileDetailChip(icon: "mappin.and.ellipse", label: "Birthplace", value: person.birthplace, identifier: "person-birthplace")
                        .frame(idealWidth: 140, maxWidth: 180)
                }
                // This page already is the native TMDB profile; its logo is source attribution.
                Link(destination: URL(string: "https://www.themoviedb.org/person/\(person.id)")!) { ProfileSourceLogo() }
                    .buttonStyle(.plain).accessibilityLabel("View source on TMDB website")
            }
            if let death = person.deathday { ProfileDetailLine(label: "Died", value: personDate(death)) }
            if let aliases = person.aliases, !aliases.isEmpty { ProfileDetailLine(label: "Also known as", value: aliases.joined(separator: " · ")) }
        }
    }
    private func server(_ person: PersonDetails) -> some View {
        let sections = store.personSections(person)
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
                        if let saved = store.libraryIdentity(item) { NavigationLink(value: saved) { CatalogPoster(item: item).zoomSource(ZoomID.title(saved)) } }
                        else { NavigationLink(value: item.route) { CatalogPoster(item: item).zoomSource(ZoomID.catalog(item.route)) } }
                        let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
                        if !role.isEmpty { Text(role).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    }.containerRelativeFrame(.horizontal, count: 3, spacing: 12).buttonStyle(.springPress)
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
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "d MMM yyyy"
    return formatter.string(from: date)
}
