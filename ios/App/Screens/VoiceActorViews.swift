import SwiftUI
import TwilDiaryCore

/// Opens a voice actor's page (AniList staff).
struct VoiceActorRoute: Hashable {
    let id: Int
    /// From your AniList stats: how many of your anime they voice in.
    var watchedCount: Int? = nil
}

/// A voice actor, laid out like a character's page: large art, names, a heart, the bio (spoilers
/// left out while Hide spoilers is on), facts and the characters they voice, each opening its page.
struct VoiceActorView: View {
    let route: VoiceActorRoute
    @Environment(DiaryStore.self) private var store
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var actor: AniVoiceActorDetail?
    @State private var failure: String?
    @State private var expanded = false
    @State private var hearts = 0
    private var favourites: FavouritesStore { .shared }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let actor {
                    VStack(alignment: .leading, spacing: 28) {
                        header(actor)
                        VStack(alignment: .leading, spacing: 28) {
                            if let count = route.watchedCount {
                                Text("In " + count.counted("anime", "anime") + " you’ve watched").font(.system(size: 15)).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("voice-actor-watched")
                            }
                            let text = actor.readableDescription(hideSpoilers: hideSpoilers)
                            if !text.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(AniListText.formatted(actor.description, hideSpoilers: hideSpoilers)).font(.system(size: 16)).lineSpacing(6)
                                        .foregroundStyle(.secondary).lineLimit(expanded ? nil : 4)
                                    Button(expanded ? "Less" : "More") { expanded.toggle() }.font(.system(size: 14)).frame(minHeight: 36)
                                }
                            }
                            facts(actor)
                            if !actor.roles.isEmpty { roles(actor.roles) }
                            Link("Voice actor details: AniList", destination: URL(string: "https://anilist.co/staff/\(actor.id)")!).font(.system(size: 13)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14)
                    }.padding(.bottom, 28)
                        .background(alignment: .top) {
                            Artwork(path: actor.image, title: actor.name).frame(height: 310 + geometry.safeAreaInsets.top)
                                .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.2), location: 0), .init(color: .black.opacity(0.55), location: 0.55), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                                .offset(y: -geometry.safeAreaInsets.top).allowsHitTesting(false).accessibilityHidden(true)
                        }
                } else if let failure { RetryNotice(message: failure) { Task { await load() } }.padding(14) }
                else { DiaryLoadingPlaceholder(height: 310, label: "Loading voice actor").padding(14) }
            }.scrollClipDisabled().diaryScreenBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .task(id: route.id) { if actor == nil { await load() } }
        }
    }
    private func header(_ actor: AniVoiceActorDetail) -> some View {
        let saved = favourites.contains(.voice, actor.id)
        return HStack(spacing: 14) {
            Artwork(path: actor.image, title: actor.name).frame(width: 80, height: 80).clipShape(Circle()).overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2))
            VStack(alignment: .leading, spacing: 4) {
                Text(actor.name).font(.system(size: 26.4, weight: .semibold)).tracking(-1.1).lineLimit(2).minimumScaleFactor(0.8)
                if let native = actor.native { Text(native).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button {
                favourites.toggle(.voice, ref: actor.id, name: actor.name, image: actor.image,
                                  subtitle: actor.roles.first.map { "Voice of " + $0.character.name }, store: store)
                if !saved { hearts += 1 }
            } label: { RoundTool(icon: "heart", tint: saved ? theme.accent : Color(webHex: "#c5c0cf")) }
                .buttonStyle(.springPress).starBurst(trigger: hearts).sensoryFeedback(.impact(weight: .light), trigger: saved)
                .accessibilityLabel(saved ? "Remove from favourites" : "Add to favourites").accessibilityIdentifier("voice-actor-favourite")
        }.padding(.horizontal, 14).padding(.top, 145).padding(.bottom, 10)
    }
    private func facts(_ actor: AniVoiceActorDetail) -> some View {
        var rows: [(label: String, value: String)] = []
        if let age = actor.age { rows.append(("Age", String(age))) }
        if let birthday = actor.birthday { rows.append(("Birthday", birthday)) }
        if let home = actor.homeTown, !home.isEmpty { rows.append(("Hometown", home)) }
        if let since = actor.yearsActive.first { rows.append(("Active since", String(since))) }
        if let count = actor.favourites { rows.append(("Favourited by", count.formatted() + " on AniList")) }
        return VStack(alignment: .leading, spacing: 14) {
            if !rows.isEmpty {
                Text("Facts").font(.system(size: 20, weight: .semibold))
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        HStack(alignment: .top, spacing: 16) {
                            Text(row.label).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                            Text(row.value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 13)).padding(.vertical, 12)
                        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 4).background(.white.opacity(0.016), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
            }
        }
    }
    private func roles(_ items: [AniRole]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Characters").font(.system(size: 20, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 16) {
                ForEach(items.prefix(30)) { role in
                    NavigationLink(value: CharacterRoute(id: role.character.id, sourceTitle: nil)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Artwork(path: role.character.image, title: role.character.name).aspectRatio(96.0 / 136.0, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(role.character.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.primary)
                            Text(role.anime).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.multilineTextAlignment(.leading).accessibilityElement(children: .combine)
                    }.buttonStyle(.springPress).accessibilityIdentifier("voice-actor-role-\(role.character.id)")
                }
            }
        }
    }
    private func load() async {
        failure = nil
        #if DEBUG
        if store.isPreview { actor = AniListPreview.voiceActor(route.id); return }
        #endif
        do { actor = try await AniListClient.shared.voiceActor(route.id) }
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
                    HStack {
                        Text(expanded ? "Show top \(Self.collapsed)" : "Show all \(rows.count)").font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 8)
                        DiaryIcon(name: "chevron-down", size: 14).rotationEffect(.degrees(expanded ? 180 : 0))
                    }.foregroundStyle(.secondary).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
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

/// Cast ranked from your diary: the people in the most titles you've watched or are watching
/// (top-billed TMDB cast). The first count fills in as the server loads casts it hasn't seen.
struct MostWatchedCast: View {
    @Environment(DiaryStore.self) private var store
    @State private var rows: [RankedRow] = []
    @State private var progress: (counted: Int, total: Int)?
    @State private var failure: String?
    @State private var loading = false
    var body: some View {
        MostWatchedSection(note: "From your diary: the people in the most titles you’ve watched or are watching.") { ranking }
            .task { await load() }
    }
    @ViewBuilder private var ranking: some View {
        if let failure, rows.isEmpty { RetryNotice(message: failure) { Task { await load() } } }
        else if loading && rows.isEmpty { DiaryLoadingPlaceholder(height: 120, label: "Counting your cast") }
        else if rows.isEmpty { Text("Watch a few titles and the cast you see most shows up here.").font(.system(size: 13)).foregroundStyle(.secondary) }
        else {
            if let progress, progress.counted < progress.total {
                // While counting it fills in; if TMDB couldn't give a few casts, it says so plainly.
                Text(loading ? "Counting… \(progress.counted) of \(progress.total) titles" : "\(progress.counted) of \(progress.total) titles counted")
                    .font(.system(size: 13)).foregroundStyle(.secondary).accessibilityIdentifier("cast-counting")
            }
            MostWatchedList(rows: rows, identifier: "top-cast") { PersonRoute(id: $0.id) }
        }
    }
    private struct Page: Decodable {
        struct Item: Decodable { let id: Int; let name: String; let image: String?; let titles: Int; let plays: Int }
        let items: [Item]
        let counted: Int
        let total: Int
        let pending: Int
    }
    /// A finished count is kept for an hour, so switching tabs doesn't make the server count again
    /// (each ranking reads several thousand D1 rows on the free plan).
    @MainActor private static var saved: (rows: [RankedRow], counted: Int, total: Int, at: Date)?
    private func load() async {
        #if DEBUG
        if store.isPreview {
            rows = [RankedRow(id: 525, name: "Kana Hanazawa", detail: nil, image: nil, number: 9, count: "9 titles", extra: "112 plays"),
                    RankedRow(id: 77, name: "Yuki Kaji", detail: nil, image: nil, number: 7, count: "7 titles", extra: "88 plays")]
            return
        }
        #endif
        if let saved = Self.saved, Date().timeIntervalSince(saved.at) < 3600 {
            rows = saved.rows; progress = (saved.counted, saved.total); return
        }
        loading = true; failure = nil
        defer { loading = false }
        var last = -1
        do {
            // A round loads a few missing casts; stop when done or when a round adds nothing.
            for _ in 0..<40 {
                let page: Page = try await store.read("/api/stats/cast")
                rows = page.items.map { item in
                    RankedRow(id: item.id, name: item.name, detail: nil, image: CatalogTools.image(item.image, size: "w185"), number: item.titles,
                              count: item.titles.counted("title", "titles"), extra: item.plays.counted("play", "plays"))
                }
                progress = (page.counted, page.total)
                if page.pending == 0 || page.counted == last || Task.isCancelled {
                    if !Task.isCancelled { Self.saved = (rows, page.counted, page.total, Date()) }
                    break
                }
                last = page.counted
            }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
