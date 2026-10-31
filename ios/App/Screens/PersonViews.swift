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
                PersonProfilePage(name: person.name, role: person.department == "Acting" ? "Actor" : person.department,
                                  image: CatalogTools.image(person.profilePath, size: "w780"), kind: .cast, ref: person.id,
                                  favouriteSubtitle: person.department, identifier: "person", source: .credits(PersonFilmographyRoute(person: person.id, section: .credits))) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let role = route.sourceRole, let title = route.sourceTitle, !role.isEmpty, !title.isEmpty {
                            Button(role + " in " + title) { dismiss() }.font(.subheadline).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading).buttonStyle(.plain)
                                .foregroundStyle(.primary).accessibilityIdentifier("person-source-role")
                        }
                        details(person)
                        ProfileBiography(text: AttributedString(person.biography), expanded: $expanded)
                        watched(person)
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
        let ageAt = person.deathday.flatMap { DiaryDate.parse($0 + "T00:00:00Z") } ?? store.now
        let age = ProfileDate.age(birthday: person.birthday, until: ageAt)
        let facts = [
            ProfileFact(id: "person-birthday", icon: "calendar", label: "Born", value: person.birthday.map(ProfileDate.short)),
            ProfileFact(id: "person-age", icon: "person", label: person.deathday == nil ? "Age" : "Age at death", value: age.map(String.init)),
            ProfileFact(id: "person-birthplace", icon: "mappin.and.ellipse", label: "Birthplace", value: person.birthplace, wide: true),
            ProfileFact(id: "person-deathday", icon: "calendar", label: "Died", value: person.deathday.map(ProfileDate.short), wide: true)
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 12) {
            ProfileFacts(items: facts)
            ProfileAliases(values: person.aliases ?? [], excluding: [person.name])
        }
    }
    private func watched(_ person: PersonDetails) -> some View {
        let sections = store.personSections(person)
        return VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Watched", route: PersonFilmographyRoute(person: person.id, section: .credits, watchedOnly: true))
            if sections.watched.isEmpty { Text("No watches from these credits yet.").font(.subheadline).foregroundStyle(.secondary) }
            else { PersonCreditShelf(items: Array(sections.watched.prefix(12))) }
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
        HStack { Text(label).font(.title3.weight(.semibold)); Spacer(minLength: 4); NavigationLink(value: route) { Text("View more").font(.system(size: 13)) }.accessibilityIdentifier("person-more-" + route.section.rawValue + (route.onServer ? "-server" : "")) }
    }
    private func load() async {
        failure = nil
        do { let result = try await store.person(route.id); guard !Task.isCancelled else { return }; person = result.person }
        catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct PersonCreditShelf: View {
    let items: [CatalogItem]
    var identifier = "person-credit-shelf"
    @Environment(DiaryStore.self) private var store
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        if let saved = store.libraryIdentity(item) { NavigationLink(value: saved) { CatalogPoster(item: item, profileTypography: true).zoomSource(ZoomID.title(saved)) } }
                        else { NavigationLink(value: item.route) { CatalogPoster(item: item, profileTypography: true).zoomSource(ZoomID.catalog(item.route)) } }
                        let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
                        if !role.isEmpty { ProfileCardCaption(title: role, secondary: true) }
                    }.containerRelativeFrame(.horizontal, count: 3, spacing: 12).buttonStyle(.springPress)
                }
            }
        }.scrollIndicators(.hidden).accessibilityIdentifier(identifier)
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
    init(route: PersonFilmographyRoute) { self.route = route; _filters = State(initialValue: PersonFilmographyFilters(section: route.section, onServer: route.onServer, watchedOnly: route.watchedOnly)) }
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
                            Text("\(items.count) \(items.count == 1 ? "title" : "titles")" + (filters.watchedOnly ? " · Watched" : filters.onServer ? " · On your server" : "")).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityIdentifier("person-result-count")
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
