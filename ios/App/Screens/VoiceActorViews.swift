import SwiftUI
import TwilDiaryCore

/// Opens a voice actor's page (AniList staff): by AniList id, or by name when the voice actor
/// comes from the diary's TMDB cast. PersonView(voice:) shows it with their TMDB side merged in.
struct VoiceActorRoute: Hashable {
    var id: Int?
    var name: String? = nil
    var tmdbID: Int? = nil
    /// How many of your anime they voice in.
    var watchedCount: Int? = nil
}

/// All of a voice actor's characters (the profile shows three), as a grid or a list.
struct VoiceActorCharactersRoute: Hashable {
    let id: Int
    let name: String
}

struct VoiceActorCharactersView: View {
    let route: VoiceActorCharactersRoute
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("voiceActorRolesGrid") private var grid = true
    @State private var roles: [AniRole]?
    @State private var failure: String?
    @State private var shown = 30
    private var usesGrid: Bool { grid && !typeSize.isAccessibilitySize }
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(roles.map { $0.count.counted("character", "characters") } ?? "Characters").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if !typeSize.isAccessibilitySize { CollectionLayoutToggle(grid: $grid, collection: "voice-actor-characters") }
                }
                if let roles {
                    LazyVGrid(columns: usesGrid ? Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3) : [GridItem(.flexible())],
                              alignment: .leading, spacing: 16) {
                        ForEach(roles.prefix(shown)) { role in VoiceActorRoleCard(role: role, grid: usesGrid) }
                    }
                    if roles.count > shown { ScrollLoadTrigger(token: shown, loading: false) { shown += 30 } }
                } else if let failure { RetryNotice(message: failure) { Task { await load() } } }
                else { DiaryLoadingPlaceholder(height: 300, label: "Loading characters") }
            }.padding(.horizontal, 14).padding(.bottom, 40).smoothChange(of: roles == nil)
        }.diaryScreenBackground().navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task(id: route) { if roles == nil { await load() } }
    }
    private func load() async {
        failure = nil
        #if DEBUG
        if store.isPreview {
            let actor = ProfileFormattingPreview.enabled ? (ProfileFormattingPreview.voice(route.id) ?? AniListPreview.voiceActor(route.id)) : AniListPreview.voiceActor(route.id)
            roles = actor.roles; return
        }
        #endif
        do { roles = try await AniListClient.shared.voiceActor(route.id).roles }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// A character card: the character opens their page; the anime below opens the title.
struct VoiceActorRoleCard: View {
    let role: AniRole
    let grid: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: CharacterRoute(id: role.character.id, sourceTitle: nil)) {
                if grid {
                    VStack(alignment: .leading, spacing: 6) {
                        artwork.posterAspect()
                        ProfileCardCaption(title: role.character.name)
                    }
                } else {
                    HStack(spacing: 12) {
                        artwork.frame(width: 64, height: 96)
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
                    ProfileCardCaption(title: role.anime, secondary: true)
                    if let score = role.rating, score > 0 {
                        RatingBadge(score: score, source: "AniList")
                            .accessibilityIdentifier("voice-actor-anime-rating-\(role.animeID)-\(role.character.id)")
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("voice-actor-anime-\(role.animeID)-\(role.character.id)")
        }.multilineTextAlignment(.leading)
    }
    private var artwork: some View {
        Artwork(path: role.character.image, title: role.character.name, alignment: .top).clipShape(RoundedRectangle(cornerRadius: 12))
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
        }, source: "AniList")
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
        EdgeToEdgeScroll {
            // Design (board 8): the service card, ACCOUNT, CHANGE PROFILE, then the profile link.
            VStack(alignment: .leading, spacing: 16) {
                SettingsServiceHeader(logo: .anilist, title: "AniList", subtitle: "Characters and voice actors",
                                      badge: user.isEmpty ? ("Not set", .missing) : ("Connected", .good)) {
                    HStack(spacing: 8) {
                        Text("Ranks your favourite characters.").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                        Spacer(minLength: 0)
                        SettingsInfoButton(text: "Favourites ranks your characters from your public AniList profile. Only the username is used: no sign-in, no password.")
                    }
                }
                if !user.isEmpty {
                    SettingsGroup(label: "Account") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connected").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                                Text("@" + user).font(.system(size: 16, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove", role: .destructive) { user = ""; draft = "" }
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(webHex: "#ffb3c0"))
                                .padding(.horizontal, 16).frame(height: 36).background(Color(webHex: "#3a1d26"), in: Capsule())
                                .buttonStyle(.plain).accessibilityIdentifier("anilist-user-remove")
                        }.padding(.horizontal, 15).frame(minHeight: 64)
                    }
                }
                SettingsGroup(label: user.isEmpty ? "Profile" : "Change profile") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Username or profile link").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        TextField("twilight29533 or anilist.co/user/…", text: $draft).settingsField()
                            .submitLabel(.done).onSubmit(save).accessibilityIdentifier("anilist-user-field")
                        if !draft.isEmpty && AniListError.username(draft) == nil {
                            Text("That doesn’t look like an AniList username or profile link.").font(.system(size: 12)).foregroundStyle(Color(webHex: "#f5c26b"))
                        }
                        Button("Save", action: save).buttonStyle(SettingsWideButtonStyle(outlined: true))
                            .disabled(AniListError.username(draft) == nil || AniListError.username(draft) == user).accessibilityIdentifier("anilist-user-save")
                    }.padding(15)
                }
                if !user.isEmpty {
                    Link(destination: URL(string: "https://anilist.co/user/" + user)!) { SettingsLinkLabel(text: "Open profile on AniList") }
                        .padding(.horizontal, 4)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
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
    /// The section's title; nil when the card around it has its own (Statistics → Faces of all time).
    var heading: String? = "Most watched"
    /// Statistics → Faces of all time: three round photos and a See all tile.
    var round = false
    @Environment(DiaryStore.self) private var store
    @State private var rows: [RankedRow] = []
    @State private var aniList: [Int: AniPerson] = [:]
    @State private var progress: (counted: Int, total: Int)?
    @State private var failure: String?
    @State private var loading = false
    var body: some View {
        MostWatchedSection(heading: heading, ranking: round ? nil : rankingRoute) { ranking }
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
            MostWatchedShelf(ranking: rankingRoute, round: round)
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
