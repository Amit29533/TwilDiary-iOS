import SwiftUI
import TwilDiaryCore

/// One page per person: TMDB cast and AniList voice actors are the same page. Whichever side the
/// route names loads first (so the page appears at once); the other side is then matched and its
/// facts, credits and characters join the same page, instead of a second "TMDB profile" page.
struct PersonView: View {
    @PosterSizing private var posterSize
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
    /// Them on your Jellyfin server (the In JellySpace card), when they're there.
    @State private var jellyPerson: JellyPersonLinks.Found?
    @State private var failure: String?
    @State private var missing = false
    @State private var matching = false
    @State private var expanded = false
    /// TMDB, Commons and MyAnimeList pictures beyond the server's list.
    @State private var morePhotos: [PersonPhoto] = []

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
                                  sameVoice: actor?.id, samePerson: person?.id,
                                  heroFacts: facts, photos: photos, showsPhotoShelf: false, backdrop: backdrop) {
                    // Design (Actor Profile, page 1): About under the header, then Photos, then the credits.
                    VStack(alignment: .leading, spacing: Gap.section) {
                        VStack(alignment: .leading, spacing: 12) {
                            intro
                            about
                        }
                        // Their films and shows on your Jellyfin server, just above what you've watched.
                        if let jellyPerson { JellyPersonCard(found: jellyPerson) }
                        watched
                        if let person {
                            let sections = store.personSections(person)
                            // Lead roles first in Known for; released work before announced work in Shows and Movies.
                            let year = Calendar.current.component(.year, from: store.now)
                            shelf("Known for", person: person, kind: .knownFor, items: Array(StudioPeople.rankKnownFor(person.credits).prefix(12)))
                            shelf("Shows", person: person, kind: .shows, items: StudioPeople.releasedFirst(sections.shows, currentYear: year))
                            shelf("Movies", person: person, kind: .movies, items: StudioPeople.releasedFirst(sections.movies, currentYear: year))
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
                    else { DiaryLoadingPlaceholder(label: "Loading person", layout: .profile).padding(14) }
                }.diaryScreenBackground().navigationTitle("").toolbar(.visible, for: .navigationBar).tint(.white)
            }
        }.task(id: start) { if person == nil && actor == nil { await load() } }
            .task(id: "\(person?.id ?? 0):\(actor?.id ?? 0)") { await loadMorePhotos() }
            // On your Jellyfin server? Found by their names, matched by TMDB id.
            .task(id: person?.id) {
                guard let person, JellySpace.client != nil else { return }
                let found = await JellyPersonLinks.find(tmdb: person.id, names: [person.name] + (person.aliases ?? []))
                withAnimation(.smooth) { jellyPerson = found }
            }
    }

    /// Their best-known title's cover: for a voice actor, the cover of their most popular anime (AniList
    /// lists roles by popularity); for cast, TMDB's backdrop of what they're known for.
    private var backdrop: String? {
        // The wide banner (or biggest cover) of their most popular anime; the small poster is a last resort.
        if voiceFirst || person == nil, let cover = actor?.roles.lazy.compactMap({ $0.banner }).first ?? actor?.roles.first(where: { $0.cover != nil })?.cover { return cover }
        if let person {
            // A main part first (a film, or 6+ episodes of a show): a guest spot's cover showed that
            // show's star behind this person's name.
            let candidates = store.personSections(person).knownFor + person.credits
            let main = candidates.filter { !StudioPeople.isSelf($0) && ($0.mediaType == .movie || ($0.episodeCount ?? 0) >= 6) }
            if let item = (main + candidates).first(where: { $0.backdrop != nil || $0.backdropPath != nil }) {
                return item.backdrop ?? CatalogTools.image(item.backdropPath, size: "w780")
            }
        }
        return actor?.roles.lazy.compactMap({ $0.banner }).first ?? actor?.roles.first(where: { $0.cover != nil })?.cover
    }
    /// The server's photos, then TMDB's, Commons and MyAnimeList's (each picture once).
    private var photos: [PersonPhoto] {
        let aniList = actor?.image.map { [PersonPhoto(path: $0, kind: "portrait", aspectRatio: 2.0 / 3.0, title: nil)] } ?? []
        return ProfilePhotoSources.merge(person?.photos ?? [], morePhotos, aniList)
    }
    private func loadMorePhotos() async {
        #if DEBUG
        if store.isPreview { return }
        #endif
        var found: [PersonPhoto] = []
        if let person { found += await ProfilePhotoSources.shared.cast(tmdbID: person.id, token: TMDBDirect.token(store)) }
        if let actor { found += await ProfilePhotoSources.shared.voiceActor(name: actor.name, native: actor.native) }
        guard !Task.isCancelled else { return }
        withAnimation(.smooth) { morePhotos = found }
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
        if case .tmdb(let route) = start, let title = ProfileText.line(route.sourceTitle) {
            ProfileSourceRow(title: title, role: route.sourceRole) { dismiss() }.accessibilityIdentifier("person-source-role")
        }
    }

    /// Facts from both sources in one grid (TMDB first where both know it), then one biography:
    /// AniList's formatted text (links, spoilers, details) when it says more, else TMDB's prose.
    /// Born, age, birthplace and the rest: the first three sit beside the photo.
    private var facts: [ProfileFact] {
        let content = actor.map { ProfileFormattedBiography(description: $0.description, hideSpoilers: hideSpoilers) }
        let died = ProfileText.line(person?.deathday)
        let ageAt = died == nil ? store.now : died.flatMap { DiaryDate.parse($0 + "T00:00:00Z") }
        let tmdbAge = ageAt.flatMap { ProfileDate.age(birthday: person?.birthday, until: $0) }
        let age = tmdbAge.map(String.init) ?? actor?.age.flatMap { $0 >= 0 ? String($0) : nil }
        let birthplace = ProfileText.line(person?.birthplace)
        let born = person?.birthday.map(ProfileDate.short) ?? actor?.birthday.map(ProfileDate.short)
        let place = birthplace ?? actor?.homeTown
        return [
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
    }
    /// About only when there's something to say (a biography, other names or AniList's details).
    @ViewBuilder private var about: some View {
        let others = (person?.aliases ?? []).filter { ![person?.name, actor?.name, actor?.native].contains($0) }
        if actor != nil || !ProfileText.withoutSourceCredit(person?.biography ?? "").text.isEmpty || !others.isEmpty { aboutContent }
    }
    private var aboutContent: some View {
        let content = actor.map { ProfileFormattedBiography(description: $0.description, hideSpoilers: hideSpoilers) }
        // The facts sit in the header (or the card under it); About keeps the prose.
        let place = ProfileText.line(person?.birthplace) ?? actor?.homeTown
        let tmdb = ProfileText.withoutSourceCredit(person?.biography ?? "")
        let tmdbProse = tmdb.text
        let aniProse = content?.markdown.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Facts already in the grid above aren't repeated in AniList's extra details below.
        var shownFacts: Set<String> = ["height"]
        if place != nil { shownFacts.formUnion(["birthplace", "nationality"]) }
        let useTMDB = !tmdbProse.isEmpty && aniProse.count < min(160, tmdbProse.count)
        let biographyID = voiceFirst ? "voice-actor-biography" : "profile-biography"
        let aliases = [person?.name, actor?.name, actor?.native].compactMap { $0 }
        // The biography first, then the other names.
        return VStack(alignment: .leading, spacing: 14) {
            Text("About").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                .accessibilityAddTraits(.isHeader).padding(.top, 6)
            if let actor, let content {
                ProfileAbout(content: content, excludingFacts: shownFacts,
                             additionalLinks: [ProfileWebsiteLink(url: URL(string: "https://anilist.co/staff/\(actor.id)")!, title: "AniList")].compactMap { $0 },
                             biographyID: biographyID, biographyOverride: useTMDB ? AttributedString(tmdbProse) : nil,
                             sourceOverride: useTMDB ? tmdb.source : nil)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ProfileBiography(text: AttributedString(tmdbProse), expanded: $expanded, identifier: biographyID, collapsedLines: 3,
                                     style: .app(size: 17))
                    if !tmdbProse.isEmpty, let source = tmdb.source { ProfileSourceNote(source: source) }
                }
            }
            ProfileAliases(values: person?.aliases ?? [], excluding: aliases)
            // Awards the TMDB biography mentions, picked out of the prose.
            ProfileAwards(awards: ProfileFormattedBiography.awards(in: tmdbProse))
        }
    }

    // MARK: Shelves

    /// One Watched shelf: TMDB credits match the diary exactly; AniList titles are the fallback.
    @ViewBuilder private var watched: some View {
        let tmdb = person.map { store.personSections($0).watched } ?? []
        if let person, !tmdb.isEmpty || actor == nil {
            VStack(alignment: .leading, spacing: Gap.heading) {
                sectionHeading("Watched", count: tmdb.isEmpty ? nil : tmdb.count, route: PersonFilmographyRoute(person: person.id, section: .credits, watchedOnly: true))
                if tmdb.isEmpty { Text("No watches from these credits yet.").font(.subheadline).foregroundStyle(.secondary) }
                else if tmdb.count <= 2 {
                    // One or two titles as rows (a shelf of one left a wide empty gap).
                    VStack(spacing: 0) {
                        ForEach(Array(tmdb.enumerated()), id: \.element.key) { index, item in
                            if index > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 28 + posterSize.small) }
                            watchedRow(item)
                        }
                    }.background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                else { PersonCreditShelf(items: Array(tmdb.prefix(12))) }
            }
        } else if let actor {
            ProfileWatchedShelf(appearances: actor.roles.map { AniAppearance(id: $0.animeID, title: $0.anime, cover: $0.cover, year: $0.year, role: $0.role, voiceActor: nil, format: $0.format, alternateTitles: $0.alternateTitles, rating: $0.rating) })
        }
    }
    @ViewBuilder private func shelf(_ label: String, person: PersonDetails, kind: PersonSection, items: [CatalogItem]) -> some View {
        if !items.isEmpty {
            // The count as a grey pill beside the heading ("Shows 45" read as one word).
            let counted = kind == .shows || kind == .movies
            VStack(alignment: .leading, spacing: Gap.heading) {
                sectionHeading(label, count: counted ? items.count : nil, route: PersonFilmographyRoute(person: person.id, section: kind))
                PersonCreditShelf(items: Array(items.prefix(12)))
            }
        }
    }
    /// A watched title as a row: poster, name, "2024 · Fink (voice)" and its rating.
    private func watchedRow(_ item: CatalogItem) -> some View {
        let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
        let row = HStack(spacing: 13) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: posterSize.small, height: posterSize.smallHeight).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.app(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                Text([item.year.map(String.init), ProfileText.line(role)].compactMap { $0 }.joined(separator: " · ")).font(.app(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let score = item.rating, score > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(Color(uiColor: .systemOrange))
                    Text(score.formatted(.number.precision(.fractionLength(1)))).foregroundStyle(HomeStyle.primary).monospacedDigit()
                }.font(.app(size: 13)).accessibilityElement(children: .combine)
            }
        }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
        return Group {
            if let saved = store.libraryIdentity(item) { CardLink(value: saved) { row } }
            else { CardLink(value: item.route) { row } }
        }.buttonStyle(.plain).accessibilityIdentifier("person-watched-row-\(item.key)")
    }
    private func sectionHeading(_ label: String, count: Int? = nil, route: PersonFilmographyRoute) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1)
            // Never squeezed: a long heading truncates first, and the pill never runs under the > button.
            if let count { CountPill(count: count) }
            Spacer(minLength: 4)
            SectionMoreLink(label: "View more " + label, value: route,
                            identifier: "person-more-" + route.section.rawValue + (route.onServer ? "-server" : ""))
        }.frame(minHeight: Gap.headingRow)
    }
    /// Characters as a sideways row (the first 20), then the round > to all of them.
    private func roles(_ actor: AniVoiceActorDetail) -> some View {
        // Each character once, however many seasons they're in.
        let characters = actor.characters
        return VStack(alignment: .leading, spacing: Gap.heading) {
            HStack {
                Text("Characters").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                CountPill(count: characters.count)
                Spacer(minLength: 4)
                if characters.count > 1 {
                    SectionMoreLink(label: "All characters", value: VoiceActorCharactersRoute(id: actor.id, name: actor.name),
                                    identifier: "voice-actor-characters-more")
                }
            }.frame(minHeight: Gap.headingRow)
            ProfileShelf {
                ForEach(characters.prefix(20)) { role in
                    VoiceActorRoleCard(role: role, grid: !typeSize.isAccessibilitySize)
                        .containerRelativeFrame(.horizontal) { width, _ in typeSize.isAccessibilitySize ? width : min(150, max(104, (width - 24) / 2.85)) }
                }
            }.scrollClipDisabled()
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
            catch { if !Task.isCancelled { failure = FriendlyError.message(error) }; return }
            await matchVoice()
        case .voice(let route):
            do { actor = try await voiceActor(route) }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                // AniList unreachable: the TMDB side still makes a page when its id is known.
                if route.tmdbID == nil { failure = FriendlyError.message(error); return }
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
        prefetchAnime(result)
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
        prefetchAnime(found)
    }
    /// One Wikidata request links every role's anime to TMDB, so a tap usually opens at once.
    private func prefetchAnime(_ actor: AniVoiceActorDetail) {
        Task { await WikidataAnime.shared.routes(actor.roles.map { WikidataAnime.Anime(id: $0.animeID, format: $0.format) }) }
    }
}

struct PersonCreditShelf: View {
    @PosterSizing private var posterSize
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
                    if let saved = store.libraryIdentity(item) { CardLink(value: saved) { label } }
                    else { CardLink(value: item.route) { label } }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        let role = (item.character?.isEmpty == false ? item.character : item.job) ?? ""
                        // The role joins the year line ("2008 · Marcus Pike"), so every caption is one height.
                        if let saved = store.libraryIdentity(item) { CardLink(value: saved) { CatalogPoster(item: item, role: role).zoomSource(ZoomID.title(saved)) } }
                        else { CardLink(value: item.route) { CatalogPoster(item: item, role: role).zoomSource(ZoomID.catalog(item.route)) } }
                    }.frame(width: posterSize.shelf).buttonStyle(.springPress).shelfTransition()
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
        let filtered = person.map { filters.applying(person: $0, workspace: store.workspace, section: route.section) } ?? []
        // In the page's default order: lead roles first in Known for, released work first in Shows and Movies.
        let year = Calendar.current.component(.year, from: store.now)
        let items: [CatalogItem] = {
            if route.section == .knownFor && filters.sort == "popular" { return StudioPeople.rankKnownFor(filtered) }
            if (route.section == .shows || route.section == .movies) && filters.sort == "newest" { return StudioPeople.releasedFirst(filtered, currentYear: year) }
            return filtered
        }()
        // A picture from the titles at the top, then "Known for" with the person's name and the count
        // under it, then the grid.
        ExploreBrowsePage(title: section, symbol: "person.crop.rectangle.stack",
                          subtitle: person.map { "\($0.name) · \(items.count) \(items.count == 1 ? "title" : "titles")" },
                          artwork: ExploreBrowseHeader.artwork(in: items),
                          titleIdentifier: "person-filmography-heading", accessory: AnyView(StudioLayoutSwitch(grid: $grid, identifier: "catalog-layout"))) {
            VStack(alignment: .leading, spacing: 16) {
                if person != nil {
                    if let error = filters.error { Text(error).font(.app(size: 13)).foregroundStyle(.secondary) }
                    else {
                        // The count is in the heading's line ("Robert De Niro · 12 titles"); it isn't
                        // repeated here (owner's call).
                        if items.isEmpty { ContentUnavailableView("No titles in this mix", systemImage: "film", description: Text("Try another genre, year, rating or collection.")) }
                        else { CatalogGrid(items: Array(items.prefix(shown)), showsLayoutToggle: false).layoutFade(grid) }
                        if shown < items.count { ScrollLoadTrigger(token: shown, loading: false) { shown += 40 } }
                    }
                } else if let failure { RetryNotice(message: failure) { Task { await load() } } }
                else { DiaryLoadingPlaceholder(label: "Loading filmography", layout: .posterGrid(columns: 3, rows: 2)).padding(14) }
            }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 100)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: route) { await load() }.onChange(of: filters) { _, _ in shown = 40 }
    }
    /// "Known for", "Watched" or "Titles on your server" (the name is on the line under it).
    private var section: String { filters.watchedOnly ? "Watched" : route.section == .credits && filters.onServer ? "Titles on your server" : route.section.label }
    private func load() async {
        failure = nil
        do { let result = try await store.person(route.person); guard !Task.isCancelled else { return }; person = result.person }
        catch is CancellationError { }
        catch { if !Task.isCancelled { failure = FriendlyError.message(error) } }
    }
}
