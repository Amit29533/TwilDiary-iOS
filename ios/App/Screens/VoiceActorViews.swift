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
                Text(role.anime).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
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

/// One row of a "Most watched" ranking.
struct RankedRow: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String?
    let image: String?
    /// The number ranked on (anime or titles); `count` is how it reads.
    let number: Int
    let count: String
    let extra: String?
}

/// "Most watched" exactly as all three Favourites tabs show it: a header (with the AniList
/// profile when the ranking comes from there), the ranking, and where it comes from.
struct MostWatchedSection<Content: View>: View {
    let note: String
    var user: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Most watched").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 8)
                if let user {
                    NavigationLink(value: AppDestination.anilist) { Text("@" + user).font(.system(size: 13)).foregroundStyle(.secondary) }
                        .accessibilityLabel("AniList profile " + user + ", change in Settings").accessibilityIdentifier("anilist-user")
                }
            }
            content
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The ranking rows: rank, round photo, name, count, opening their page. The top 5 show, with
/// "Show all" for the rest, so the hearted posters stay right under the card.
struct MostWatchedList<Route: Hashable>: View {
    let rows: [RankedRow]
    let identifier: String
    let route: (RankedRow) -> Route
    @State private var expanded = false
    private static var collapsed: Int { 5 }
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.prefix(expanded ? rows.count : Self.collapsed).enumerated()), id: \.element.id) { index, row in
                NavigationLink(value: route(row)) {
                    HStack(spacing: 12) {
                        Text(String(index + 1)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                        Artwork(path: row.image, title: row.name).frame(width: 48, height: 48).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            if let detail = row.detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.count).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                            if let extra = row.extra { Text(extra).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                        DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("\(identifier)-\(row.id)")
            }
            if rows.count > Self.collapsed {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    // Centred under the rows, the chevron beside the words.
                    HStack(spacing: 6) {
                        Text(expanded ? "Show top \(Self.collapsed)" : "Show all \(rows.count)").font(.system(size: 14, weight: .semibold))
                        DiaryIcon(name: "chevron-down", size: 14).rotationEffect(.degrees(expanded ? 180 : 0))
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("\(identifier)-more")
            }
        }.diaryPanel(padding: 4, radius: 16)
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
        MostWatchedSection(note: note, user: user.isEmpty ? nil : user) { ranking }
            .task(id: user) { rows = []; failure = nil; await load(force: false) }
    }
    private var note: String {
        kind == .voiceActors
            ? "From your AniList stats: the voice actors in the most anime you’ve watched there."
            : "From your AniList list: main characters in the most anime you’ve watched there."
    }
    @ViewBuilder private var ranking: some View {
        if user.isEmpty { connectPrompt }
        else if let failure { RetryNotice(message: failure) { Task { await load(force: true) } } }
        else if loading && rows.isEmpty { DiaryLoadingPlaceholder(height: 120, label: kind == .voiceActors ? "Loading your AniList stats" : "Loading your AniList list") }
        else if rows.isEmpty { Text("Nothing to rank on AniList yet.").font(.system(size: 13)).foregroundStyle(.secondary) }
        else if kind == .voiceActors { MostWatchedList(rows: rows, identifier: "top-voice-actor") { VoiceActorRoute(id: $0.id, watchedCount: $0.number) } }
        else { MostWatchedList(rows: rows, identifier: "top-character") { CharacterRoute(id: $0.id) } }
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
        defer { loading = false }
        do {
            // `try` can't sit inside a ?: in Swift, so the two sources are a plain if/else.
            if kind == .voiceActors { rows = try await AniListClient.shared.topVoiceActors(user: user).map(Self.voiceRow) }
            else { rows = try await AniListClient.shared.topCharacters(user: user).map(Self.characterRow) }
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
                Text("Favourites ranks your characters and voice actors from your public AniList profile. Only the username is used: no sign-in, no password.")
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
        MostWatchedSection(note: kind == .voice
                           ? "From your diary: the voice actors in the most anime you’ve watched or are watching."
                           : "From your diary: the people in the most live-action titles you’ve watched or are watching.") { ranking }
            .task { await load() }
    }
    @ViewBuilder private var ranking: some View {
        if let failure, rows.isEmpty { RetryNotice(message: failure) { Task { await load() } } }
        else if loading && rows.isEmpty { DiaryLoadingPlaceholder(height: 120, label: kind == .voice ? "Counting your voice actors" : "Counting your cast") }
        else if rows.isEmpty {
            Text(kind == .voice ? "Watch some anime and the voice actors you hear most show up here." : "Watch a few live-action titles and the cast you see most shows up here.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        } else {
            if let progress, progress.counted < progress.total {
                // While counting it fills in; if TMDB couldn't give a few casts, it says so plainly.
                Text(loading ? "Counting… \(progress.counted) of \(progress.total) titles" : "\(progress.counted) of \(progress.total) titles counted")
                    .font(.system(size: 13)).foregroundStyle(.secondary).accessibilityIdentifier("cast-counting")
            }
            if kind == .voice {
                MostWatchedList(rows: rows, identifier: "top-voice-actor") { row in
                    VoiceActorRoute(id: aniList[row.id]?.id, name: row.name, tmdbID: row.id, watchedCount: row.number)
                }
            } else {
                MostWatchedList(rows: rows, identifier: "top-cast") { PersonRoute(id: $0.id) }
            }
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
