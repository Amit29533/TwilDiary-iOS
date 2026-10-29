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
    /// AniList's markup made readable: spoilers (~! … !~) are left out while spoilers are hidden.
    func readableDescription(hideSpoilers: Bool) -> String {
        var text = description.replacingOccurrences(of: "<br>", with: "\n")
        let spoiler = /~!(.|\n)*?!~/
        text = hideSpoilers ? text.replacing(spoiler, with: "") : text.replacingOccurrences(of: "~!", with: "").replacingOccurrences(of: "!~", with: "")
        for mark in ["__", "**"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacing(/<[^>]+>/, with: "").replacing(/\n{3,}/, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AniListError: LocalizedError {
    case unavailable
    var errorDescription: String? { "AniList didn’t answer. Try again in a moment." }
}

actor AniListClient {
    static let shared = AniListClient()
    private var characterLists: [String: [AniCharacter]] = [:]
    private var details: [Int: AniCharacterDetail] = [:]

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
    private func query<T: Decodable>(_ text: String, _ variables: [String: any Sendable]) async throws -> T {
        struct Envelope<D: Decodable>: Decodable { let data: D? }
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["query": text, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
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
    static func detail(_ id: Int) -> AniCharacterDetail {
        let character = characters.first { $0.id == id } ?? characters[0]
        return AniCharacterDetail(id: character.id, name: character.name, native: character.native, alternative: ["The Slayer"], image: nil,
                                  description: "An elf mage who once helped defeat the Demon King. ~!A spoiler that stays hidden.!~",
                                  gender: "Female", age: "1000+", birthday: "1 January", bloodType: nil, favourites: 52000,
                                  appearances: [AniAppearance(id: 154587, title: "Frieren: Beyond Journey’s End", cover: nil, year: 2023, role: character.role, voiceActor: character.voiceActor)])
    }
}
#endif
