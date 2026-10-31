import Foundation

enum ProfileText {
    static func line(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : clean
    }
    static func aliases(_ values: [String], excluding names: [String]) -> [String] {
        func key(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        var seen = Set(names.compactMap(line).map(key))
        return values.compactMap(line).filter { seen.insert(key($0)).inserted }
    }
    static func watched(_ count: Int, anime: Bool) -> String? {
        guard count >= 0 else { return nil }
        return count.formatted() + (anime ? " anime watched" : count == 1 ? " title watched" : " titles watched")
    }
    static func favourites(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        return count.formatted() + (count == 1 ? " favourite on AniList" : " favourites on AniList")
    }
    static func career(_ years: [Int]) -> String? {
        let valid = years.filter { (1...9999).contains($0) }
        guard let first = valid.first else { return nil }
        if valid.count == 1 { return "Active since " + String(first) }
        if valid.count == 2, let last = valid.last, last >= first { return "Active " + String(first) + "–" + String(last) }
        return "Active " + valid.map(String.init).joined(separator: ", ")
    }
}

/// Extract only explicitly labelled, standalone facts. The existing sanitizer runs
/// first so hidden spoilers cannot become visible metadata or website buttons.
struct ProfileFormattedBiography {
    struct Fact: Identifiable {
        let id: String
        let label: String
        let icon: String
        let markdown: String
        var wide: Bool { !["height", "weight", "blood-type"].contains(id) }
    }
    let markdown: String
    let links: [ProfileWebsiteLink]
    let references: [ProfileReferenceLink]
    let facts: [Fact]
    init(description: String, hideSpoilers: Bool) {
        let content = ProfileBiographyContent(description: description, hideSpoilers: hideSpoilers)
        links = content.links
        references = content.references
        let pattern = #"^\s*(?:[-*]\s+)?(?:\*\*|__)?(Height|Weight|Agency|Blood type|Birthplace|Occupation|Affiliation|Nationality|Combat Style|Relatives|Family|Hobbies|Skills & Abilities|Allegiance|Position|Knightmare Frame)(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*(.+?)\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var body: [String] = [], fields: [Fact] = [], seen = Set<String>()
        for line in content.markdown.components(separatedBy: "\n") {
            guard let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else { body.append(line); continue }
            let name = String(line[nameRange]).lowercased(), value = String(line[valueRange])
            // Long labelled paragraphs stay prose, with no data silently discarded.
            guard value.count <= 400, !value.trimmingCharacters(in: .whitespaces).isEmpty else { body.append(line); continue }
            guard seen.insert(name).inserted else { body.append(line); continue }
            let icon: String
            switch name { case "height": icon = "ruler"; case "weight": icon = "scalemass"; case "agency", "affiliation": icon = "building.2"; case "birthplace", "nationality": icon = "mappin.and.ellipse"; case "relatives", "family": icon = "person.2"; default: icon = "info.circle" }
            fields.append(Fact(id: name.replacingOccurrences(of: " ", with: "-"), label: String(line[nameRange]).capitalized, icon: icon, markdown: value))
        }
        facts = fields
        // A spoiler-only role list must not leave a dangling section heading.
        while let last = body.last {
            if last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body.removeLast(); continue }
            if last.range(of: #"^\s*(?:#{1,6}\s+.+|(?:\*\*|__)[^\n]+:(?:\*\*|__)|(?:\*\*|__)[^\n]+(?:\*\*|__):)\s*$"#, options: .regularExpression) != nil { body.removeLast(); continue }
            break
        }
        markdown = body.joined(separator: "\n").replacing(/\n{3,}/, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ProfileDate {
    static func age(birthday: String?, until end: Date) -> Int? {
        guard let birthday, birthday.range(of: #"^(?:\d{4}-\d{2}-\d{2}|\d{1,2} [A-Za-z]+ \d{4})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd", "d MMMM yyyy", "d MMM yyyy"] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: birthday), date <= end else { continue }
            return formatter.calendar.dateComponents([.year], from: date, to: end).year
        }
        return nil
    }
}
