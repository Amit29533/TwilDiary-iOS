import Foundation

/// Anime characters come from AniList: TMDB lists only the cast (voice actors), not the
/// characters themselves. AniList's public API needs no key; the phone asks it directly,
/// so it costs the TwilDiary server nothing. Nothing private is sent, only a title and year.
struct AniPerson: Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let image: String?
}
struct AniCharacter: Codable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let native: String?
    let image: String?
    /// MAIN, SUPPORTING or BACKGROUND.
    let role: String?
    let voiceActor: AniPerson?
    var roleName: String { role == "MAIN" ? "Main" : role == "SUPPORTING" ? "Supporting" : "Background" }
}
struct AniAppearance: Hashable, Sendable, Identifiable {
    let id: Int
    let title: String
    let cover: String?
    let year: Int?
    let role: String?
    let voiceActor: AniPerson?
}
struct AniCharacterDetail: Sendable {
    let id: Int
    let name: String
    let native: String?
    let alternative: [String]
    let image: String?
    let description: String
    let gender: String?
    let age: String?
    let birthday: String?
    let bloodType: String?
    let favourites: Int?
    let appearances: [AniAppearance]
    var voiceActors: [AniPerson] {
        var seen = Set<Int>()
        return appearances.compactMap(\.voiceActor).filter { seen.insert($0.id).inserted }
    }
    func readableDescription(hideSpoilers: Bool) -> String { AniListText.readable(description, hideSpoilers: hideSpoilers) }
}
/// One character a voice actor plays, in one anime.
struct AniRole: Hashable, Sendable, Identifiable {
    let character: AniPerson
    let animeID: Int
    let anime: String
    let cover: String?
    let year: Int?
    let role: String?
    var id: String { "\(character.id)-\(animeID)" }
}
struct AniVoiceActorDetail: Sendable {
    let id: Int
    let name: String
    let native: String?
    let image: String?
    let description: String
    let age: Int?
    let birthday: String?
    let homeTown: String?
    let yearsActive: [Int]
    let favourites: Int?
    /// Most popular anime first; one entry per character and anime.
    let roles: [AniRole]
    func readableDescription(hideSpoilers: Bool) -> String { AniListText.readable(description, hideSpoilers: hideSpoilers) }
}
/// A row of the AniList stats page "Voice actors": how many of your anime they voice in.
struct AniVoiceActorStat: Hashable, Sendable, Identifiable {
    let person: AniPerson
    let native: String?
    let count: Int
    let minutesWatched: Int
    var id: Int { person.id }
}
/// Characters ranked from your AniList anime list: main characters by how many of your anime
/// (seasons and films count separately) they're in.
struct AniCharacterStat: Hashable, Sendable, Identifiable {
    let person: AniPerson
    let native: String?
    let count: Int
    var id: Int { person.id }
}
enum AniListText {
    /// AniList's markup made readable: spoilers (~! … !~) are left out while spoilers are hidden.
    static func readable(_ description: String, hideSpoilers: Bool) -> String {
        var text = description.replacingOccurrences(of: "<br>", with: "\n")
        let spoiler = /~!(.|\n)*?!~/
        text = hideSpoilers ? text.replacing(spoiler, with: "") : text.replacingOccurrences(of: "~!", with: "").replacingOccurrences(of: "!~", with: "")
        for mark in ["__", "**"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacing(/<[^>]+>/, with: "").replacing(/\n{3,}/, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AniListError: LocalizedError {
    case unavailable, notFound
    var errorDescription: String? {
        self == .notFound ? "AniList has no user or page by that name." : "AniList didn’t answer. Try again in a moment."
    }
    /// "twilight29533", "@twilight29533" or a profile link (anilist.co/user/twilight29533/…).
    static func username(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "anilist.co/user/", options: .caseInsensitive) {
            text = String(text[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        if text.hasPrefix("@") { text.removeFirst() }
        return text.range(of: "^[A-Za-z0-9_-]{2,40}$", options: .regularExpression) != nil ? text : nil
    }
}

actor AniListClient {
    static let shared = AniListClient()
    private var characterLists: [String: [AniCharacter]] = [:]
    private var details: [Int: AniCharacterDetail] = [:]
    private var voiceActors: [Int: AniVoiceActorDetail] = [:]
    private var userStats: [String: [AniVoiceActorStat]] = [:]
    private var userCharacters: [String: [AniCharacterStat]] = [:]

    /// The anime's characters, main roles first, each with their Japanese voice actor. Empty when
    /// AniList has no anime of that name released within a year of `year` (better none than wrong).
    func characters(title: String, year: Int?, movie: Bool) async throws -> [AniCharacter] {
        let key = "\(title.lowercased())|\(year ?? 0)|\(movie)"
        if let saved = characterLists[key] { return saved }
        struct Found: Decodable { let Page: PageResult; struct PageResult: Decodable { let media: [Media] } }
        struct Media: Decodable { let id: Int; let format: String?; let startDate: DateParts? }
        let found: Found = try await query("""
            query($search: String) { Page(perPage: 6) { media(search: $search, type: ANIME, sort: SEARCH_MATCH) { id format startDate { year } } } }
            """, ["search": title])
        let candidates = found.Page.media.filter { media in
            guard let year else { return true }
            guard let started = media.startDate?.year else { return false }
            return abs(started - year) <= 1
        }
        // A film matches AniList's MOVIE format; a show anything else.
        guard let match = candidates.first(where: { ($0.format == "MOVIE") == movie }) ?? candidates.first else {
            characterLists[key] = []; return []
        }
        struct Characters: Decodable { let Media: MediaResult; struct MediaResult: Decodable { let characters: Connection } }
        struct Connection: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let role: String?; let node: Node; let voiceActors: [Staff] }
        let page: Characters = try await query("""
            query($id: Int) { Media(id: $id) { characters(sort: [ROLE, RELEVANCE, ID], perPage: 25) { edges { role node { id name { full native } image { large } } voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) { id name { full } image { large } } } } } }
            """, ["id": match.id])
        let list = page.Media.characters.edges.map { edge in
            AniCharacter(id: edge.node.id, name: edge.node.name.full ?? "Unknown", native: edge.node.name.native, image: edge.node.image?.large,
                         role: edge.role, voiceActor: edge.voiceActors.first.map { AniPerson(id: $0.id, name: $0.name.full ?? "Unknown", image: $0.image?.large) })
        }
        characterLists[key] = list
        return list
    }

    func character(_ id: Int) async throws -> AniCharacterDetail {
        if let saved = details[id] { return saved }
        struct Result: Decodable { let Character: CharacterNode }
        struct CharacterNode: Decodable {
            let id: Int; let name: Name; let image: Image?; let description: String?; let gender: String?; let age: String?
            let dateOfBirth: DateParts?; let bloodType: String?; let favourites: Int?; let media: Connection
        }
        struct Connection: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let characterRole: String?; let node: MediaNode; let voiceActors: [Staff] }
        struct MediaNode: Decodable { let id: Int; let title: Title; let coverImage: Image?; let startDate: DateParts? }
        struct Title: Decodable { let romaji: String?; let english: String? }
        let result: Result = try await query("""
            query($id: Int) { Character(id: $id) { id name { full native alternative } image { large } description(asHtml: false) gender age dateOfBirth { year month day } bloodType favourites media(sort: [POPULARITY_DESC], type: ANIME, perPage: 12) { edges { characterRole node { id title { romaji english } coverImage { large } startDate { year } } voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) { id name { full } image { large } } } } } }
            """, ["id": id])
        let node = result.Character
        let detail = AniCharacterDetail(
            id: node.id, name: node.name.full ?? "Unknown", native: node.name.native, alternative: node.name.alternative ?? [],
            image: node.image?.large, description: node.description ?? "", gender: node.gender, age: node.age,
            birthday: node.dateOfBirth?.text, bloodType: node.bloodType, favourites: node.favourites,
            appearances: node.media.edges.map { edge in
                AniAppearance(id: edge.node.id, title: edge.node.title.english ?? edge.node.title.romaji ?? "Untitled", cover: edge.node.coverImage?.large,
                              year: edge.node.startDate?.year, role: edge.characterRole,
                              voiceActor: edge.voiceActors.first.map { AniPerson(id: $0.id, name: $0.name.full ?? "Unknown", image: $0.image?.large) })
            })
        details[id] = detail
        return detail
    }

    /// A voice actor (AniList staff): profile and the characters they voice, most popular anime first.
    func voiceActor(_ id: Int) async throws -> AniVoiceActorDetail {
        if let saved = voiceActors[id] { return saved }
        struct Result: Decodable { let Staff: StaffNode }
        struct StaffNode: Decodable {
            let id: Int; let name: Name; let image: Image?; let description: String?; let age: Int?
            let dateOfBirth: DateParts?; let homeTown: String?; let yearsActive: [Int]?; let favourites: Int?; let characterMedia: Connection
        }
        struct Connection: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let characterRole: String?; let node: MediaNode; let characters: [Node] }
        struct MediaNode: Decodable { let id: Int; let title: Title; let coverImage: Image?; let startDate: DateParts? }
        struct Title: Decodable { let romaji: String?; let english: String? }
        let result: Result = try await query("""
            query($id: Int) { Staff(id: $id) { id name { full native } image { large } description(asHtml: false) age dateOfBirth { year month day } homeTown yearsActive favourites characterMedia(sort: [POPULARITY_DESC], type: ANIME, perPage: 40) { edges { characterRole node { id title { romaji english } coverImage { large } startDate { year } } characters { id name { full } image { large } } } } } }
            """, ["id": id])
        let node = result.Staff
        var seen = Set<String>()
        let roles = node.characterMedia.edges.flatMap { edge in
            edge.characters.map { character in
                AniRole(character: AniPerson(id: character.id, name: character.name.full ?? "Unknown", image: character.image?.large),
                        animeID: edge.node.id, anime: edge.node.title.english ?? edge.node.title.romaji ?? "Untitled",
                        cover: edge.node.coverImage?.large, year: edge.node.startDate?.year, role: edge.characterRole)
            }
        }.filter { seen.insert($0.id).inserted }
        let detail = AniVoiceActorDetail(
            id: node.id, name: node.name.full ?? "Unknown", native: node.name.native, image: node.image?.large,
            description: node.description ?? "", age: node.age, birthday: node.dateOfBirth?.text, homeTown: node.homeTown,
            yearsActive: node.yearsActive ?? [], favourites: node.favourites, roles: roles)
        voiceActors[id] = detail
        return detail
    }

    /// The AniList stats page "Voice actors" for a public profile: most anime watched first.
    func topVoiceActors(user: String) async throws -> [AniVoiceActorStat] {
        let key = user.lowercased()
        if let saved = userStats[key] { return saved }
        struct Result: Decodable { let User: UserNode? }
        struct UserNode: Decodable { let statistics: Statistics }
        struct Statistics: Decodable { let anime: Anime }
        struct Anime: Decodable { let voiceActors: [Row] }
        struct Row: Decodable { let count: Int; let minutesWatched: Int; let voiceActor: Staff? }
        let result: Result = try await query("""
            query($name: String) { User(name: $name) { statistics { anime { voiceActors(limit: 30, sort: [COUNT_DESC]) { count minutesWatched voiceActor { id name { full native } image { large } } } } } } }
            """, ["name": user])
        guard let found = result.User else { throw AniListError.notFound }
        let rows = found.statistics.anime.voiceActors.compactMap { row in
            row.voiceActor.map { actor in
                AniVoiceActorStat(person: AniPerson(id: actor.id, name: actor.name.full ?? "Unknown", image: actor.image?.large),
                                  native: actor.name.native, count: row.count, minutesWatched: row.minutesWatched)
            }
        }
        userStats[key] = rows
        return rows
    }
    /// Main characters in the most anime on a public AniList list (watched, watching or rewatching).
    func topCharacters(user: String) async throws -> [AniCharacterStat] {
        let key = user.lowercased()
        if let saved = userCharacters[key] { return saved }
        struct Result: Decodable { let Page: PageNode }
        struct PageNode: Decodable { let pageInfo: PageInfo; let mediaList: [Entry] }
        struct PageInfo: Decodable { let hasNextPage: Bool? }
        struct Entry: Decodable { let media: Media? }
        struct Media: Decodable { let id: Int; let characters: Characters? }
        struct Characters: Decodable { let nodes: [Node] }
        var tally: [Int: (character: Node, anime: Set<Int>)] = [:]
        // At most 10 pages of 50 entries: 500 anime, a handful of requests.
        for page in 1...10 {
            let result: Result = try await query("""
                query($name: String, $page: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } mediaList(userName: $name, type: ANIME, status_in: [COMPLETED, CURRENT, REPEATING]) { media { id characters(role: MAIN, perPage: 6, sort: [ROLE, RELEVANCE, ID]) { nodes { id name { full native } image { large } } } } } } }
                """, ["name": user, "page": page])
            for entry in result.Page.mediaList {
                guard let media = entry.media else { continue }
                for character in media.characters?.nodes ?? [] {
                    var row = tally[character.id] ?? (character, [])
                    row.anime.insert(media.id)
                    tally[character.id] = row
                }
            }
            if result.Page.pageInfo.hasNextPage != true { break }
        }
        let rows = tally.values
            .map { AniCharacterStat(person: AniPerson(id: $0.character.id, name: $0.character.name.full ?? "Unknown", image: $0.character.image?.large),
                                    native: $0.character.name.native, count: $0.anime.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.person.name < $1.person.name }
        let top = Array(rows.prefix(30))
        userCharacters[key] = top
        return top
    }
    /// Pull to refresh asks AniList again.
    func forgetStats() { userStats = [:]; userCharacters = [:] }

    // MARK: Shared shapes and the request

    fileprivate struct Name: Decodable { let full: String?; let native: String?; let alternative: [String]? }
    fileprivate struct Image: Decodable { let large: String? }
    fileprivate struct Node: Decodable { let id: Int; let name: Name; let image: Image? }
    fileprivate struct Staff: Decodable { let id: Int; let name: Name; let image: Image? }
    fileprivate struct DateParts: Decodable {
        let year: Int?; let month: Int?; let day: Int?
        var text: String? {
            guard let month, let day, (1...12).contains(month) else { return nil }
            let name = Calendar(identifier: .gregorian).monthSymbols[month - 1]
            return year.map { "\(day) \(name) \($0)" } ?? "\(day) \(name)"
        }
    }
    /// AniList's GraphQL reply: the answer under `data`.
    private struct Envelope<D: Decodable>: Decodable { let data: D? }
    private func query<T: Decodable>(_ text: String, _ variables: [String: any Sendable]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["query": text, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw AniListError.unavailable }
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw AniListError.notFound }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONDecoder().decode(Envelope<T>.self, from: data).data else { throw AniListError.unavailable }
        return value
    }
}

#if DEBUG
/// UI tests never reach AniList.
enum AniListPreview {
    static let characters = [
        AniCharacter(id: 1, name: "Frieren", native: "フリーレン", image: nil, role: "MAIN", voiceActor: AniPerson(id: 11, name: "Atsumi Tanezaki", image: nil)),
        AniCharacter(id: 2, name: "Fern", native: "フェルン", image: nil, role: "MAIN", voiceActor: AniPerson(id: 12, name: "Kana Ichinose", image: nil)),
        AniCharacter(id: 3, name: "Stark", native: "シュタルク", image: nil, role: "MAIN", voiceActor: AniPerson(id: 13, name: "Chiaki Kobayashi", image: nil)),
        AniCharacter(id: 4, name: "Himmel", native: "ヒンメル", image: nil, role: "SUPPORTING", voiceActor: AniPerson(id: 14, name: "Nobuhiko Okamoto", image: nil))
    ]
    static let topVoiceActors = [
        AniVoiceActorStat(person: AniPerson(id: 11, name: "Atsumi Tanezaki", image: nil), native: "種﨑敦美", count: 14, minutesWatched: 4210),
        AniVoiceActorStat(person: AniPerson(id: 12, name: "Kana Ichinose", image: nil), native: "市ノ瀬加那", count: 11, minutesWatched: 3020),
        AniVoiceActorStat(person: AniPerson(id: 13, name: "Chiaki Kobayashi", image: nil), native: "小林千晃", count: 9, minutesWatched: 2480)
    ]
    static let topCharacters = [
        AniCharacterStat(person: AniPerson(id: 1, name: "Frieren", image: nil), native: "フリーレン", count: 3),
        AniCharacterStat(person: AniPerson(id: 2, name: "Fern", image: nil), native: "フェルン", count: 2)
    ]
    static func voiceActor(_ id: Int) -> AniVoiceActorDetail {
        let stat = topVoiceActors.first { $0.id == id } ?? topVoiceActors[0]
        let character = characters.first { $0.voiceActor?.id == stat.id } ?? characters[0]
        return AniVoiceActorDetail(id: stat.id, name: stat.person.name, native: stat.native, image: nil,
                                   description: "A voice actor from Japan. ~!A spoiler that stays hidden.!~", age: 33, birthday: "27 September",
                                   homeTown: "Tokyo", yearsActive: [2006], favourites: 9000,
                                   roles: [AniRole(character: AniPerson(id: character.id, name: character.name, image: nil), animeID: 154587,
                                                   anime: "Frieren: Beyond Journey’s End", cover: nil, year: 2023, role: character.role)])
    }
    static func detail(_ id: Int) -> AniCharacterDetail {
        let character = characters.first { $0.id == id } ?? characters[0]
        return AniCharacterDetail(id: character.id, name: character.name, native: character.native, alternative: ["The Slayer"], image: nil,
                                  description: "An elf mage who once helped defeat the Demon King. ~!A spoiler that stays hidden.!~",
                                  gender: "Female", age: "1000+", birthday: "1 January", bloodType: nil, favourites: 52000,
                                  appearances: [AniAppearance(id: 154587, title: "Frieren: Beyond Journey’s End", cover: nil, year: 2023, role: character.role, voiceActor: character.voiceActor)])
    }
}
#endif
