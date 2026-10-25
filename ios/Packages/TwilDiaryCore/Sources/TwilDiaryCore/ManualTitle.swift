import Foundation

public struct ManualTitleDraft: Sendable {
    public var name = "", category = "show", year = "", status = "planned", score = ""
    public init() { }
    public func validated(id: String) throws -> ManualTitleInput {
        let clean = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf16.count <= 300, !clean.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ManualTitleError("Keep titles between 1 and 300 characters") }
        guard ["movie", "show", "anime", "anime-movie"].contains(category) else { throw ManualTitleError("Choose a supported media category") }
        guard ["planned", "watching", "completed", "dropped"].contains(status) else { throw ManualTitleError("Choose a supported watch status") }
        let number = Int(year)
        guard year.isEmpty || (year.utf8.count == 4 && year.utf8.allSatisfy { (48...57).contains($0) } && number.map { (1800...2200).contains($0) } == true) else { throw ManualTitleError("Choose a valid release year") }
        let rating = Double(score)
        guard score.isEmpty || rating.map({ $0.isFinite && (1...10).contains($0) }) == true else { throw ManualTitleError("Choose a score from 1 to 10") }
        return ManualTitleInput(id: id, name: clean, category: category, year: number, status: status == "completed" ? "planned" : status, score: rating)
    }
}
public struct ManualTitleInput: Encodable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let year: Int?
    public let status: String
    public let score: Double?
    enum CodingKeys: String, CodingKey { case id, name, category, year, status, score }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(name, forKey: .name); try container.encode(category, forKey: .category)
        try container.encode(year, forKey: .year); try container.encode(status, forKey: .status); try container.encode(score, forKey: .score)
    }
}
public struct ManualTitleError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
