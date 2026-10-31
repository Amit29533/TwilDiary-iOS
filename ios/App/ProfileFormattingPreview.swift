#if DEBUG
import Foundation
import TwilDiaryCore

/// Public factual fields from the profile audit plus synthetic biography prose.
/// No credentials, live diary writes or network access are needed for this matrix.
enum ProfileFormattingPreview {
    struct Birthday: Decodable, Sendable { let year: Int?; let month: Int?; let day: Int? }
    struct Sample: Decodable, Sendable {
        let id: Int
        let kind: String
        let name: String
        let native: String?
        let aliases: [String]
        let birthday: Birthday?
        let age: String?
        let gender: String?
        let bloodType: String?
        let homeTown: String?
        let yearsActive: [Int]
        let favourites: Int?
        let description: String
        let deathday: String?
        var dateText: String? { birthday.flatMap { ProfileDate.partial(year: $0.year, month: $0.month, day: $0.day) } }
    }
    static let samples: [Sample] = {
        struct File: Decodable { let profiles: [Sample] }
        let url = Bundle.main.url(forResource: "catalog-profile-format-matrix", withExtension: "json")!
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).profiles
    }()
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-profile-format=") }) }
    static func character(_ id: Int) -> AniCharacterDetail? {
        guard let sample = samples.first(where: { $0.kind == "character" && $0.id == id }) else { return nil }
        return AniCharacterDetail(id: sample.id, name: sample.name, native: sample.native, alternative: sample.aliases, image: nil,
                                  description: sample.description, gender: sample.gender, age: sample.age, birthday: sample.dateText,
                                  bloodType: sample.bloodType, favourites: sample.favourites, appearances: AniListPreview.detail(2).appearances)
    }
    static func voice(_ id: Int) -> AniVoiceActorDetail? {
        guard let sample = samples.first(where: { $0.kind == "voice" && $0.id == id }) else { return nil }
        return AniVoiceActorDetail(id: sample.id, name: sample.name, native: sample.native, image: nil, description: sample.description,
                                   age: sample.age.flatMap(Int.init), birthday: sample.dateText, homeTown: sample.homeTown,
                                   yearsActive: sample.yearsActive, favourites: sample.favourites, roles: AniListPreview.voiceActor(12).roles)
    }
    static func person(_ id: Int) throws -> PersonResponse? {
        guard let sample = samples.first(where: { $0.kind == "cast" && $0.id == id }) else { return nil }
        let birthday = sample.birthday.flatMap { date -> String? in
            guard let year = date.year, let month = date.month, let day = date.day else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        let value: [String: Any] = ["person": ["id": id, "name": sample.name, "biography": sample.description, "birthday": birthday as Any? ?? NSNull(),
                            "deathday": sample.deathday as Any? ?? NSNull(), "aliases": sample.aliases,
                            "birthplace": sample.homeTown ?? "", "department": "Acting", "credits": []], "stale": false]
        return try JSONDecoder().decode(PersonResponse.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
#endif
