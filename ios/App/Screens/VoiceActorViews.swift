import SwiftUI
import TwilDiaryCore

/// Opens a voice actor's page (AniList staff): by AniList id, or by name when the voice actor
/// comes from the diary's TMDB cast (their TMDB page is the fallback when AniList has no match).
struct VoiceActorRoute: Hashable {
    var id: Int?
    var name: String? = nil
    var tmdbID: Int? = nil
    /// How many of your anime they voice in.
    var watchedCount: Int? = nil
}

/// Voice actors share the profile shell; identity resolution and all role routes stay native.
struct VoiceActorView: View {
    let route: VoiceActorRoute
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("voiceActorRolesGrid") private var grid = true
    @State private var actor: AniVoiceActorDetail?
    @State private var failure: String?
    @State private var missing = false
    @State private var expanded = false
    @State private var openingPerson = false
    @State private var personFailure: String?
    @State private var personLookup: Task<Void, Never>?
    @State private var shown = 30
    var body: some View {
        Group {
            if let actor {
                PersonProfilePage(name: actor.name, nativeName: actor.native, role: "Voice actor", image: actor.image,
                                  kind: .voice, ref: actor.id, favouriteSubtitle: actor.roles.first.map { "Voice of " + $0.character.name },
                                  identifier: "voice-actor") {
                    VStack(alignment: .leading, spacing: 20) {
                        details(actor)
                        if let count = route.watchedCount {
                            Text("In " + count.counted("anime", "anime") + " you’ve watched").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("voice-actor-watched")
                        }
                        biography(actor)
                        ProfileWatchedShelf(appearances: actor.roles.map { AniAppearance(id: $0.animeID, title: $0.anime, cover: $0.cover, year: $0.year, role: $0.role, voiceActor: nil, format: $0.format, alternateTitles: $0.alternateTitles, rating: $0.rating) })
                        if !actor.roles.isEmpty { roles(actor.roles) }
                    }
                }
            } else {
                ScrollView {
                    if missing {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AniList has no page for \(route.name ?? "this voice actor").").font(.subheadline).foregroundStyle(.secondary)
                            if let tmdb = route.tmdbID {
                                NavigationLink(value: PersonRoute(id: tmdb)) { Text("Open their cast page").font(.subheadline.weight(.semibold)) }
                                    .accessibilityIdentifier("voice-actor-cast-page")
                            }
                        }.padding(14)
                    } else if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                    else { DiaryLoadingPlaceholder(height: 310, label: "Loading voice actor").padding(14) }
                }.diaryScreenBackground().navigationTitle("").toolbar(.visible, for: .navigationBar).tint(.white)
            }
        }.task(id: route) {
            if actor == nil { await load() }
            if let actor {
                store.animeNavigation.rememberPerson(actor.id, tmdbID: route.tmdbID, scope: store.sessionRevision)
                if let id = route.tmdbID { await AniListClient.shared.rememberPerson(staffID: actor.id, tmdbID: id) }
            }
        }
        .onDisappear { personLookup?.cancel() }
        .alert("Unable to open TMDB profile", isPresented: Binding(get: { personFailure != nil }, set: { if !$0 { personFailure = nil } })) {
            Button("Retry") { if let actor { openPerson(actor) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(personFailure ?? "") }
    }
    private func details(_ actor: AniVoiceActorDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                if let birthday = actor.birthday { ProfileDetailChip(icon: "calendar", label: "Born", value: ProfileDate.short(birthday), identifier: "voice-actor-birthday") }
                if let home = actor.homeTown, !home.isEmpty {
                    ProfileDetailChip(icon: "mappin.and.ellipse", label: "Hometown", value: home, identifier: "voice-actor-hometown").frame(idealWidth: 140, maxWidth: 160)
                }
                Button { openPerson(actor) } label: { ProfileSourceLogo(loading: openingPerson) }
                    .buttonStyle(.plain).fixedSize().disabled(openingPerson)
                    .accessibilityIdentifier("voice-actor-tmdb").accessibilityLabel("Open \(actor.name)’s TMDB profile")
            }
        }
    }
    private func biography(_ actor: AniVoiceActorDetail) -> some View {
        let content = ProfileBiographyContent(description: actor.description, hideSpoilers: hideSpoilers)
        let lines = content.markdown.components(separatedBy: "\n")
        let first = lines.first ?? ""
        let hasAgency = AniListText.readable(first, hideSpoilers: hideSpoilers).lowercased().hasPrefix("agency:")
        let body = hasAgency ? lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : content.markdown
        let source = ProfileWebsiteLink(url: URL(string: "https://anilist.co/staff/\(actor.id)")!, title: "AniList")!
        let sites = content.links.contains(where: { $0.id == source.id }) ? content.links : content.links + [source]
        let career = [actor.age.map { "Age \($0)" }, actor.yearsActive.first.map { "Active since \($0)" }].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 10) {
            if hasAgency {
                Text(AniListText.formatted(first, hideSpoilers: hideSpoilers)).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice-actor-intro")
            }
            if !career.isEmpty { Text(career.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary) }
            if let count = actor.favourites { Text(count.formatted() + " favourites on AniList").font(.subheadline).foregroundStyle(.secondary) }
            ProfileWebsiteButtons(links: sites)
            ProfileBiography(text: AniListText.formatted(body, hideSpoilers: hideSpoilers), expanded: $expanded, identifier: "voice-actor-biography")
        }
    }
    private func openPerson(_ actor: AniVoiceActorDetail) {
        let tab = router.selectedTab, depth = router.paths[router.selectedTab]?.count ?? 0
        openingPerson = true; personFailure = nil; personLookup?.cancel()
        personLookup = Task {
            defer { openingPerson = false }
            do {
                let id = try await store.animeNavigation.person(actor, knownID: route.tmdbID, service: store)
                try Task.checkCancellation()
                guard router.selectedTab == tab, (router.paths[tab]?.count ?? 0) == depth else { return }
                router.paths[tab, default: NavigationPath()].append(PersonRoute(id: id))
            } catch is CancellationError { }
            catch { if !Task.isCancelled { personFailure = error.localizedDescription } }
        }
    }
    private func roles(_ items: [AniRole]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Characters").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 4)
                CollectionLayoutToggle(grid: $grid, collection: "voice-actor-characters")
            }
            LazyVGrid(columns: grid ? Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3) : [GridItem(.flexible())], alignment: .leading, spacing: 16) {
                ForEach(items.prefix(shown)) { role in roleCard(role) }
            }
            if items.count > shown {
                Button("Show more characters") { shown += 30 }.font(.subheadline).frame(minHeight: 44)
            }
        }
    }
    private func roleCard(_ role: AniRole) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: CharacterRoute(id: role.character.id, sourceTitle: nil)) {
                if grid {
                    VStack(alignment: .leading, spacing: 6) {
                        roleArtwork(role).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        Text(role.character.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                    }
                } else {
                    HStack(spacing: 12) {
                        roleArtwork(role).frame(width: 64, height: 96)
                        Text(role.character.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("voice-actor-role-\(role.character.id)")
            AnimeAppearanceButton(appearance: AniAppearance(id: role.animeID, title: role.anime, cover: role.cover,
                                               year: role.year, role: role.role, voiceActor: nil,
                                               format: role.format, alternateTitles: role.alternateTitles)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.anime).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let score = role.rating, score > 0 {
                        HStack(spacing: 3) { RatingBadge(score: score); Text("AniList").font(.caption2).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("voice-actor-anime-\(role.animeID)-\(role.character.id)")
        }.multilineTextAlignment(.leading)
    }
    private func roleArtwork(_ role: AniRole) -> some View {
        Artwork(path: role.character.image, title: role.character.name).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func load() async {
        failure = nil; missing = false
        #if DEBUG
        if store.isPreview { actor = AniListPreview.voiceActor(route.id ?? 11); return }
        #endif
        do {
            var found = route.id
            if found == nil, let name = route.name { found = await AniListClient.shared.staff(named: [name])[name]?.id }
            guard let id = found else { missing = true; return }
            let result = try await AniListClient.shared.voiceActor(id)
            try Task.checkCancellation()
            actor = result
        }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// Voice actors and characters ranked from your public AniList profile, set in Settings →
/// Connections and data → AniList (shared by both tabs).
struct AniListMostWatched: View {
    enum Kind { case voiceActors, characters }
    let kind: Kind
    static let userKey = "anilistUser"
    @Environment(DiaryStore.self) private var store
    @AppStorage(AniListMostWatched.userKey) private var user = ""
    @State private var rows: [RankedRow] = []
    @State private var failure: String?
    @State private var loading = false
    var body: some View {
        MostWatchedSection(user: user.isEmpty ? nil : user, ranking: rankingRoute) { ranking }
            .task(id: user) { rows = []; failure = nil; await load(force: false) }
    }
    private var rankingRoute: PeopleRankingRoute {
        PeopleRankingRoute(category: kind == .voiceActors ? "Voice actors" : "Characters",
                           identifier: kind == .voiceActors ? "top-voice-actor" : "top-character",
                           people: rows.map { row in
            RankedPerson.aniList(row, voice: kind == .voiceActors)
        })
    }
    @ViewBuilder private var ranking: some View {
        if user.isEmpty { connectPrompt }
        else if let failure { RetryNotice(message: failure) { Task { await load(force: true) } } }
        else if loading && rows.isEmpty { DiaryLoadingPlaceholder(height: 220, label: kind == .voiceActors ? "Loading your AniList stats" : "Loading your AniList list") }
        else if rows.isEmpty { Text("Nothing to rank on AniList yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
        else { MostWatchedShelf(ranking: rankingRoute) }
    }
    private var connectPrompt: some View {
        NavigationLink(value: AppDestination.anilist) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your AniList profile").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text("Settings → Connections and data → AniList").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary)
            }.diaryPanel(padding: 14, radius: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("anilist-connect")
    }
    private func load(force: Bool) async {
        guard !user.isEmpty else { rows = []; return }
        #if DEBUG
        if store.isPreview { rows = kind == .voiceActors ? AniListPreview.topVoiceActors.map(Self.voiceRow) : AniListPreview.topCharacters.map(Self.characterRow); return }
        #endif
        if force { await AniListClient.shared.forgetStats() }
        loading = true; failure = nil
        let requestedUser = user
        defer { if requestedUser == user { loading = false } }
        do {
            // `try` can't sit inside a ?: in Swift, so the two sources are a plain if/else.
            let result: [RankedRow]
            if kind == .voiceActors { result = try await AniListClient.shared.topVoiceActors(user: requestedUser).map(Self.voiceRow) }
            else { result = try await AniListClient.shared.topCharacters(user: requestedUser).map(Self.characterRow) }
            try Task.checkCancellation()
            guard requestedUser == user else { return }
            rows = result
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    private static func voiceRow(_ stat: AniVoiceActorStat) -> RankedRow {
        RankedRow(id: stat.id, name: stat.person.name, detail: stat.native, image: stat.person.image, number: stat.count,
                  count: stat.count.counted("anime", "anime"), extra: stat.minutesWatched >= 60 ? "\(stat.minutesWatched / 60) h" : "\(stat.minutesWatched) min")
    }
    private static func characterRow(_ stat: AniCharacterStat) -> RankedRow {
        RankedRow(id: stat.id, name: stat.person.name, detail: stat.native, image: stat.person.image, number: stat.count,
                  count: stat.count.counted("anime", "anime"), extra: nil)
    }
}

/// Settings → Connections and data → AniList: the public profile Favourites ranks characters and
/// voice actors from. A username or a pasted profile link; nothing else is asked or stored.
struct AniListSettingsView: View {
    @AppStorage(AniListMostWatched.userKey) private var user = ""
    @State private var draft = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Favourites ranks your characters from your public AniList profile. Only the username is used: no sign-in, no password.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Username or profile link").font(.system(size: 15, weight: .semibold))
                    TextField("twilight29533 or anilist.co/user/…", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done).onSubmit(save).padding(.horizontal, 12).frame(minHeight: 44)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("anilist-user-field")
                    if !draft.isEmpty && AniListError.username(draft) == nil {
                        Text("That doesn’t look like an AniList username or profile link.").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    Button("Save", action: save).buttonStyle(.glassProminent)
                        .disabled(AniListError.username(draft) == nil || AniListError.username(draft) == user).accessibilityIdentifier("anilist-user-save")
                }.diaryPanel(padding: 14, radius: 16)
                if !user.isEmpty {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected").font(.system(size: 13)).foregroundStyle(.secondary)
                            Text("@" + user).font(.system(size: 15, weight: .semibold))
                        }
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) { user = ""; draft = "" }.accessibilityIdentifier("anilist-user-remove")
                    }.diaryPanel(padding: 14, radius: 16)
                    Link("Open profile on AniList", destination: URL(string: "https://anilist.co/user/" + user)!).font(.system(size: 14))
                }
            }.padding(14).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle("AniList").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onAppear { draft = user }
    }
    private func save() {
        guard let name = AniListError.username(draft) else { return }
        user = name; draft = name
        Task { await AniListClient.shared.forgetStats() }
    }
}

/// Cast or voice actors ranked from your diary: the people in the most titles you've watched or
/// are watching (top-billed TMDB cast). Cast counts live action; voice actors count anime,
/// anime films and Animation, with AniList's photo and page for each when AniList has them.
/// The first count fills in as the server loads casts it hasn't seen.
struct MostWatchedCast: View {
    enum Kind: Hashable { case cast, voice }
    let kind: Kind
    @Environment(DiaryStore.self) private var store
    @State private var rows: [RankedRow] = []
    @State private var aniList: [Int: AniPerson] = [:]
    @State private var progress: (counted: Int, total: Int)?
    @State private var failure: String?
    @State private var loading = false
    var body: some View {
        MostWatchedSection(ranking: rankingRoute) { ranking }
            .task { await load() }
    }
    private var rankingRoute: PeopleRankingRoute {
        let status: String? = progress.flatMap { value in
            value.counted < value.total ? "\(value.counted) of \(value.total) titles counted" : nil
        }
        return PeopleRankingRoute(category: kind == .voice ? "Voice actors" : "Cast",
                                  identifier: kind == .voice ? "top-voice-actor" : "top-cast",
                                  people: rows.map { row in
            RankedPerson.diary(row, voice: kind == .voice, staffID: aniList[row.id]?.id)
        }, status: status)
    }
    @ViewBuilder private var ranking: some View {
        if let failure, rows.isEmpty { RetryNotice(message: failure) { Task { await load() } } }
        else if loading && rows.isEmpty { DiaryLoadingPlaceholder(height: 220, label: kind == .voice ? "Counting your voice actors" : "Counting your cast") }
        else if rows.isEmpty {
            Text(kind == .voice ? "Watch some anime and the voice actors you hear most show up here." : "Watch a few live-action titles and the cast you see most shows up here.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            MostWatchedShelf(ranking: rankingRoute)
        }
    }
    private struct Page: Decodable {
        struct Item: Decodable {
            let id: Int; let name: String; let image: String?; let character: String?; let title: String?
            let titles: Int; let plays: Int
        }
        let items: [Item]
        let counted: Int
        let total: Int
        let pending: Int
    }
    /// A finished count is kept for an hour, so switching tabs doesn't make the server count again
    /// (each ranking reads several thousand D1 rows on the free plan).
    @MainActor private static var saved: [Kind: (rows: [RankedRow], aniList: [Int: AniPerson], counted: Int, total: Int, at: Date)] = [:]
    private func row(_ item: Page.Item) -> RankedRow {
        let role = [item.character, item.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return RankedRow(id: item.id, name: item.name, detail: role.isEmpty ? nil : role,
                         image: aniList[item.id]?.image ?? CatalogTools.image(item.image, size: "w185"), number: item.titles,
                         count: item.titles.counted(kind == .voice ? "anime" : "title", kind == .voice ? "anime" : "titles"),
                         extra: item.plays.counted("play", "plays"))
    }
    private func load() async {
        #if DEBUG
        if store.isPreview {
            rows = kind == .voice
                ? [RankedRow(id: 1001, name: "Atsumi Tanezaki", detail: "Frieren · Frieren", image: nil, number: 14, count: "14 anime", extra: "210 plays"),
                   RankedRow(id: 1002, name: "Kana Ichinose", detail: "Fern · Frieren", image: nil, number: 11, count: "11 anime", extra: "160 plays")]
                : [RankedRow(id: 525, name: "Kim Yeong-ok", detail: "Kim Gam-ri · Hometown Cha-Cha-Cha", image: nil, number: 5, count: "5 titles", extra: "74 plays"),
                   RankedRow(id: 77, name: "Jeon Bae-soo", detail: "Woo Gwang-woo · Extraordinary Attorney Woo", image: nil, number: 5, count: "5 titles", extra: "72 plays")]
            if ProcessInfo.processInfo.arguments.contains("--ui-favourites-gallery") {
                rows += (3...7).map { index in
                    RankedRow(id: 700 + index, name: "Reference \(kind == .voice ? "Voice Actor" : "Cast Member") \(index)",
                              detail: "An intentionally long character role in a reference title", image: nil,
                              number: 8 - index, count: "\(8 - index) \(kind == .voice ? "anime" : "titles")", extra: "\(70 - index) plays")
                }
            }
            return
        }
        #endif
        if let saved = Self.saved[kind], Date().timeIntervalSince(saved.at) < 3600 {
            rows = saved.rows; aniList = saved.aniList; progress = (saved.counted, saved.total)
            for (id, actor) in saved.aniList { await AniListClient.shared.rememberPerson(staffID: actor.id, tmdbID: id) }
            return
        }
        loading = true; failure = nil
        defer { loading = false }
        var last = -1
        do {
            // A round loads a few missing casts; stop when done or when a round adds nothing.
            for _ in 0..<40 {
                let page: Page = try await store.read(CatalogTools.apiPath("/api/stats/cast", query: kind == .voice ? ["kind": "voice"] : [:]))
                rows = page.items.map(row)
                progress = (page.counted, page.total)
                let finished = page.pending == 0 || page.counted == last || Task.isCancelled
                if finished {
                    // Voice actors: AniList's photos and pages, found by name (best effort).
                    if kind == .voice, !Task.isCancelled {
                        let found = await AniListClient.shared.staff(named: page.items.map(\.name))
                        aniList = Dictionary(page.items.compactMap { item in found[item.name].map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
                        for (id, actor) in aniList { await AniListClient.shared.rememberPerson(staffID: actor.id, tmdbID: id) }
                        rows = page.items.map(row)
                    }
                    if !Task.isCancelled { Self.saved[kind] = (rows: rows, aniList: aniList, counted: page.counted, total: page.total, at: Date()) }
                    break
                }
                last = page.counted
            }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
