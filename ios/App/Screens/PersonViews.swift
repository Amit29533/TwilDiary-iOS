import SwiftUI
import TwilDiaryCore

/// One page per person: TMDB cast and AniList voice actors are the same page. Whichever side the
/// route names loads first (so the page appears at once); the other side is then matched and its
/// facts, credits and characters join the same page, instead of a second "TMDB profile" page.
struct PersonView: View {
    enum Start: Hashable { case tmdb(PersonRoute), voice(VoiceActorRoute) }
    let start: Start
    init(route: PersonRoute) { start = .tmdb(route) }
    init(voice: VoiceActorRoute) { start = .voice(voice) }
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var person: PersonDetails?
    @State private var actor: AniVoiceActorDetail?
    @State private var failure: String?
    @State private var missing = false
    @State private var matching = false
    @State private var expanded = false

    /// The page keeps the identity the route opened (favourite, identifiers, role line).
    private var voiceFirst: Bool { if case .voice = start, actor != nil { return true }; return false }
    private var prefix: String { voiceFirst ? "voice-actor" : "person" }

    var body: some View {
        Group {
            if person != nil || actor != nil {
                PersonProfilePage(name: voiceFirst ? (actor?.name ?? "") : (person?.name ?? actor?.name ?? ""),
                                  nativeName: actor?.native, role: role,
                                  image: CatalogTools.image(person?.profilePath, size: "w780") ?? actor?.image,
                                  kind: voiceFirst ? .voice : .cast, ref: voiceFirst ? (actor?.id ?? 0) : (person?.id ?? 0),
                                  favouriteSubtitle: voiceFirst ? actor?.roles.first.map { "Voice of " + $0.character.name } : person?.department,
                                  identifier: prefix,
                                  sameVoice: actor?.id, samePerson: person?.id) {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            intro
                            about
                        }
                        watched
                        if let person {
                            let sections = store.personSections(person)
                            shelf("Known for", person: person, kind: .knownFor, items: sections.knownFor)
                            shelf("Shows", person: person, kind: .shows, items: sections.shows)
                            shelf("Movies", person: person, kind: .movies, items: sections.movies)
                        }
                        if let actor, !actor.roles.isEmpty { roles(actor) }
                        if matching { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8).accessibilityIdentifier("person-matching") }
                    }
                    // The other source's facts and shelves fade in when they join the page.
                    .smoothChange(of: [person?.id ?? 0, actor?.id ?? 0, matching ? 1 : 0])
                }
            } else {
                EdgeToEdgeScroll {
                    if missing {
                        Text("No profile was found for \(routeName ?? "this person").").font(.subheadline).foregroundStyle(.secondary).padding(14)
                            .accessibilityIdentifier("person-missing")
                    } else if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                    else { DiaryLoadingPlaceholder(height: 310, label: "Loading person").padding(14) }
                }.diaryScreenBackground().navigationTitle("").toolbar(.visible, for: .navigationBar).tint(.white)
            }
        }.task(id: start) { if person == nil && actor == nil { await load() } }
    }

    private var routeName: String? { if case .voice(let route) = start { return route.name }; return nil }
    /// "15 anime" you've watched with them (from a ranking), when the page was opened from one.
    private var watchedCount: Int? { if case .voice(let route) = start, let count = route.watchedCount, count >= 0 { return count }; return nil }
    private var role: String? {
        if voiceFirst { return "Voice actor" }
        guard let person else { return "Voice actor" }
        return person.department == "Acting" ? "Actor" : person.department
    }
    // MARK: Text

    @ViewBuilder private var intro: some View {
        if case .tmdb(let route) = start, let role = ProfileText.line(route.sourceRole), let title = ProfileText.line(route.sourceTitle) {
            Button(role + " in " + title) { dismiss() }.font(.subheadline).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .topLeading).buttonStyle(.plain)
                .foregroundStyle(.primary).accessibilityIdentifier("person-source-role")
        }
    }

    /// Facts from both sources in one grid (TMDB first where both know it), then one biography:
    /// AniList's formatted text (links, spoilers, details) when it says more, else TMDB's prose.
    private var about: some View {
        let content = actor.map { ProfileFormattedBiography(description: $0.description, hideSpoilers: hideSpoilers) }
        let died = ProfileText.line(person?.deathday)
        let ageAt = died == nil ? store.now : died.flatMap { DiaryDate.parse($0 + "T00:00:00Z") }
        let tmdbAge = ageAt.flatMap { ProfileDate.age(birthday: person?.birthday, until: $0) }
        let age = tmdbAge.map(String.init) ?? actor?.age.flatMap { $0 >= 0 ? String($0) : nil }
        let birthplace = ProfileText.line(person?.birthplace)
        let born = person?.birthday.map(ProfileDate.short) ?? actor?.birthday.map(ProfileDate.short)
        let place = birthplace ?? actor?.homeTown
        let facts = [
            ProfileFact(id: prefix + "-birthday", icon: "calendar", label: "Born", value: born),
            ProfileFact(id: prefix + "-age", icon: "person", label: died == nil ? "Age" : "Age at death", value: age),
            ProfileFact(id: prefix + "-career", icon: "briefcase", label: ProfileText.careerLabel(actor?.yearsActive ?? []), value: actor.flatMap { ProfileText.careerValue($0.yearsActive) }),
            ProfileFact(id: prefix + "-favourites", icon: "heart", label: "Favourites", value: actor.flatMap { ProfileText.favouritesValue($0.favourites) }),
            ProfileFact(id: prefix + "-height", icon: "ruler", label: "Height", value: content?.facts.first { $0.id == "height" }?.markdown),
            ProfileFact(id: "voice-actor-watched", icon: "eye", label: "Watched", value: watchedCount.map { $0.formatted() + " anime" }),
            ProfileFact(id: prefix + (birthplace != nil ? "-birthplace" : "-hometown"), icon: "mappin",
                        label: birthplace != nil ? "Birthplace" : "Hometown", value: place, wide: true),
            ProfileFact(id: prefix + "-deathday", icon: "calendar", label: "Died", value: person?.deathday.map(ProfileDate.short), wide: true)
        ].compactMap { $0 }
        let tmdb = ProfileText.withoutSourceCredit(person?.biography ?? "")
        let tmdbProse = tmdb.text
        let aniProse = content?.markdown.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Facts already in the grid above aren't repeated in AniList's extra details below.
        var shownFacts: Set<String> = ["height"]
        if place != nil { shownFacts.formUnion(["birthplace", "nationality"]) }
        let useTMDB = !tmdbProse.isEmpty && aniProse.count < min(160, tmdbProse.count)
        let biographyID = voiceFirst ? "voice-actor-biography" : "profile-biography"
        let aliases = [person?.name, actor?.name, actor?.native].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 14) {
            ProfileFacts(items: facts)
            ProfileAliases(values: person?.aliases ?? [], excluding: aliases)
            if let actor, let content {
                ProfileAbout(content: content, excludingFacts: shownFacts,
                             additionalLinks: [ProfileWebsiteLink(url: URL(string: "https://anilist.co/staff/\(actor.id)")!, title: "AniList")].compactMap { $0 },
                             biographyID: biographyID, biographyOverride: useTMDB ? AttributedString(tmdbProse) : nil,
                             sourceOverride: useTMDB ? tmdb.source : nil)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ProfileBiography(text: AttributedString(tmdbProse), expanded: $expanded, identifier: biographyID)
                    if !tmdbProse.isEmpty, let source = tmdb.source { ProfileSourceNote(source: source) }
                }
            }
        }
    }

    // MARK: Shelves

    /// One Watched shelf: TMDB credits match the diary exactly; AniList titles are the fallback.
    @ViewBuilder private var watched: some View {
        let tmdb = person.map { store.personSections($0).watched } ?? []
        if let person, !tmdb.isEmpty || actor == nil {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading("Watched", route: PersonFilmographyRoute(person: person.id, section: .credits, watchedOnly: true))
                if tmdb.isEmpty { Text("No watches from these credits yet.").font(.subheadline).foregroundStyle(.secondary) }
                else { PersonCreditShelf(items: Array(tmdb.prefix(12))) }
            }
        } else if let actor {
            ProfileWatchedShelf(appearances: actor.roles.map { AniAppearance(id: $0.animeID, title: $0.anime, cover: $0.cover, year: $0.year, role: $0.role, voiceActor: nil, format: $0.format, alternateTitles: $0.alternateTitles, rating: $0.rating) })
        }
    }
    @ViewBuilder private func shelf(_ label: String, person: PersonDetails, kind: PersonSection, items: [CatalogItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading(label + (kind == .shows || kind == .movies ? " \(items.count)" : ""), route: PersonFilmographyRoute(person: person.id, section: kind))
                PersonCreditShelf(items: Array(items.prefix(12)))
            }
        }
    }
    private func sectionHeading(_ label: String, route: PersonFilmographyRoute) -> some View {
        HStack {
            Text(label).font(.title3.weight(.semibold))
            Spacer(minLength: 4)
            SectionMoreLink(label: "View more " + label, value: route,
                            identifier: "person-more-" + route.section.rawValue + (route.onServer ? "-server" : ""))
        }
    }
    /// Three characters, like every other section, then the round > to all of them.
    private func roles(_ actor: AniVoiceActorDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Characters \(actor.roles.count)").font(.title3.weight(.semibold))
                Spacer(minLength: 4)
                if actor.roles.count > 3 {
                    SectionMoreLink(label: "All characters", value: VoiceActorCharactersRoute(id: actor.id, name: actor.name),
                                    identifier: "voice-actor-characters-more")
                }
            }
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(actor.roles.prefix(3)) { role in VoiceActorRoleCard(role: role, grid: !typeSize.isAccessibilitySize) }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        failure = nil; missing = false
        switch start {
        case .tmdb(let route):
            do {
                let found = try await store.person(route.id).person
                guard !Task.isCancelled else { return }
                person = found
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { failure = error.localizedDescription }; return }
            await matchVoice()
        case .voice(let route):
            do { actor = try await voiceActor(route) }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                // AniList unreachable: the TMDB side still makes a page when its id is known.
                if route.tmdbID == nil { failure = error.localizedDescription; return }
            }
            guard !Task.isCancelled else { return }
            if actor == nil && route.tmdbID == nil { missing = true; return }
            await matchPerson(route)
            if actor == nil && person == nil && failure == nil { missing = true }
        }
    }
    private func voiceActor(_ route: VoiceActorRoute) async throws -> AniVoiceActorDetail? {
        #if DEBUG
        if store.isPreview { return ProfileFormattingPreview.enabled ? (ProfileFormattingPreview.voice(route.id ?? 11) ?? AniListPreview.voiceActor(route.id ?? 11)) : AniListPreview.voiceActor(route.id ?? 11) }
        #endif
        var found = route.id
        if found == nil, let name = route.name { found = await AniListClient.shared.staff(named: [name])[name]?.id }
        guard let id = found else { return nil }
        let result = try await AniListClient.shared.voiceActor(id)
        try Task.checkCancellation()
        return result
    }
    /// Voice route: the TMDB person (known id, a remembered match, or one found in an anime's cast).
    private func matchPerson(_ route: VoiceActorRoute) async {
        #if DEBUG
        // The formatting fixtures check AniList's own facts; they have no TMDB counterpart.
        if store.isPreview && ProfileFormattingPreview.enabled && route.tmdbID == nil { return }
        #endif
        matching = true
        defer { matching = false }
        var id = route.tmdbID
        if let actor {
            if id == nil { id = try? await store.animeNavigation.person(actor, knownID: nil, service: store) }
            if let id {
                store.animeNavigation.rememberPerson(actor.id, tmdbID: id, scope: store.sessionRevision)
                await AniListClient.shared.rememberPerson(staffID: actor.id, tmdbID: id)
            }
        }
        guard let id, !Task.isCancelled else { return }
        guard let found = try? await store.person(id).person, !Task.isCancelled else { return }
        person = found
    }
    /// TMDB route: their AniList page, only for people with voice or animation credits, and only an
    /// exact name match (AniList's search alone could pick a namesake).
    private func matchVoice() async {
        guard let person else { return }
        #if DEBUG
        if store.isPreview { return }
        #endif
        let voiced = person.credits.contains { item in
            item.character?.localizedCaseInsensitiveContains("(voice)") == true
                || (item.genres ?? []).contains { $0 == "Animation" || $0 == "16" }
        }
        let known = await AniListClient.shared.staffID(forTMDB: person.id)
        guard known != nil || voiced else { return }
        matching = true
        defer { matching = false }
        var id = known
        // Wikidata's exact link first; an exact-name search only when it has none.
        if id == nil { id = await WikidataPeople.shared.aniListStaffID(forTMDB: person.id) }
        if id == nil { id = await AniListClient.shared.staff(named: [person.name])[person.name]?.id }
        guard let id, !Task.isCancelled else { return }
        guard let found = try? await AniListClient.shared.voiceActor(id), !Task.isCancelled, !found.roles.isEmpty else { return }
        await AniListClient.shared.rememberPerson(staffID: found.id, tmdbID: person.id)
        store.animeNavigation.rememberPerson(found.id, tmdbID: person.id, scope: store.sessionRevision)
        actor = found
    }
}

struct PersonCreditShelf: View {
    let items: [CatalogItem]
    var identifier = "person-credit-shelf"
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DiaryStore.self) private var store
    var body: some View {
        ProfileShelf {
            ForEach(items, id: \.key) { item in
                if typeSize.isAccessibilitySize {
                    let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
                    let label = ProfileMediaRow(image: item.artwork, name: item.name, detail: [item.year.map(String.init), ProfileText.line(role)].compactMap { $0 }.joined(separator: " · "), score: item.rating ?? store.libraryIdentity(item).flatMap({ store.title($0)?.communityScore }), provider: "TMDB")
                    if let saved = store.libraryIdentity(item) { NavigationLink(value: saved) { label } }
                    else { NavigationLink(value: item.route) { label } }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let saved = store.libraryIdentity(item) { NavigationLink(value: saved) { CatalogPoster(item: item, profileTypography: true).zoomSource(ZoomID.title(saved)) } }
                        else { NavigationLink(value: item.route) { CatalogPoster(item: item, profileTypography: true).zoomSource(ZoomID.catalog(item.route)) } }
                        let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
                        if !role.isEmpty { ProfileCardCaption(title: role, secondary: true) }
                    }.containerRelativeFrame(.horizontal, count: 3, spacing: 12).buttonStyle(.springPress).shelfTransition()
                }
            }
        }.accessibilityIdentifier(identifier)
    }
}

struct PersonFilmographyView: View {
    let route: PersonFilmographyRoute
    @Environment(DiaryStore.self) private var store
    @AppStorage("catalogGrid") private var grid = true
    @State private var person: PersonDetails?
    @State private var failure: String?
    @State private var filters: PersonFilmographyFilters
    @State private var shown = 40
    init(route: PersonFilmographyRoute) { self.route = route; _filters = State(initialValue: PersonFilmographyFilters(section: route.section, onServer: route.onServer, watchedOnly: route.watchedOnly)) }
    var body: some View {
        VStack(spacing: 0) {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 16) {

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
                            if shown < items.count { ScrollLoadTrigger(token: shown, loading: false) { shown += 40 } }
                        }
                    } else if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else { DiaryLoadingPlaceholder(height: 240, label: "Loading filmography").padding(14) }
                }.padding(.horizontal, 14).padding(.bottom, 100)
            }.scrollDismissesKeyboard(.interactively)
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)

            .task(id: route) { await load() }.onChange(of: filters) { _, _ in shown = 40 }
    }
    private func load() async {
        failure = nil
        do { let result = try await store.person(route.person); guard !Task.isCancelled else { return }; person = result.person }
        catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
