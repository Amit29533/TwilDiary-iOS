import Foundation

enum ProfileText {
    /// Bios from TMDB and AniList often end with the same credit lines ("Description above from the
    /// Wikipedia article …, licensed under CC-BY-SA, full list of contributors on Wikipedia.",
    /// "From Wikipedia, the free encyclopedia", "(Source: Crunchyroll)"). They're cut from the prose
    /// and returned as one short source name instead, so every bio ends cleanly.
    static func withoutSourceCredit(_ text: String) -> (text: String, source: String?) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var source: String?
        let wikipedia = try? NSRegularExpression(pattern: #"\s*Description above (?:is )?from the Wikipedia article[^\n]*?(?:full list of contributors on Wikipedia|licensed under CC-BY-SA[^\n.]*)?\.?\s*$"#, options: [.caseInsensitive])
        if let wikipedia, let match = wikipedia.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(match.range, in: body) {
            body.removeSubrange(range); source = "Wikipedia"
        }
        if let range = body.range(of: #"^\s*From Wikipedia, the free encyclopedia\.?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            body.removeSubrange(range); source = "Wikipedia"
        }
        // A last line or bracket like "(Source: Crunchyroll)", "Source: ANN" or "[Written by MAL Rewrite]".
        let trailing = try? NSRegularExpression(pattern: #"\s*[(\[]?\s*(?:Source|Sources|Written by)\s*:?\s*([^)\]\n]{1,80})[)\]]?\s*$"#, options: [.caseInsensitive])
        if let trailing, let match = trailing.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range, in: body), let name = Range(match.range(at: 1), in: body) {
            let start = body[..<range.lowerBound]
            // Only a credit on its own line or in brackets, never a sentence that mentions a source.
            if start.isEmpty || start.hasSuffix("\n") || body[range].contains("(") || body[range].contains("[") {
                source = source ?? String(body[name]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                body.removeSubrange(range)
            }
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), source)
    }
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
    /// Compact fact values: the number or span alone, its label says the rest.
    static func favouritesValue(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        return count.formatted()
    }
    static func careerValue(_ years: [Int]) -> String? {
        let valid = years.filter { (1...9999).contains($0) }
        guard let first = valid.first else { return nil }
        if valid.count == 1 { return String(first) }
        if valid.count == 2, let last = valid.last, last >= first { return String(first) + "–" + String(last) }
        return valid.map(String.init).joined(separator: ", ")
    }
    static func careerLabel(_ years: [Int]) -> String {
        years.filter { (1...9999).contains($0) }.count == 1 ? "Active since" : "Active years"
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
    /// What kind of thing a labelled field is, so the page can group it (owner's request: pick
    /// the common fields out of AniList descriptions and show each kind in its own container).
    /// From 100 top characters and 50 top voice actors on AniList: height (most), affiliation,
    /// occupation, relatives, rank/grade/bounty, powers (quirk, cursed technique, devil fruit…),
    /// species and nationality; for voice actors agency, hobbies, favourites, awards and trivia.
    enum Kind: Int, CaseIterable, Comparable {
        case profile, affiliation, role, powers, relations, interests, other
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .profile: "Profile"
            case .affiliation: "Affiliations"
            case .role: "Role and rank"
            case .powers: "Powers and abilities"
            case .relations: "Family and relations"
            case .interests: "Likes and hobbies"
            case .other: "More details"
            }
        }
        var icon: String {
            switch self {
            case .profile: "person.text.rectangle"
            case .affiliation: "building.2"
            case .role: "rosette"
            case .powers: "sparkles"
            case .relations: "person.2"
            case .interests: "heart.text.square"
            case .other: "info.circle"
            }
        }
        static func of(_ id: String) -> Kind {
            let profile = ["nationality", "birthplace", "residency", "hometown", "origin", "alma-mater", "graduated", "education", "species",
                           "race", "gender", "kind", "classification", "birthyear", "weight", "eye-color", "eye-colour", "hair-color", "hair-colour", "zodiac", "age"]
            let affiliation = ["affiliation", "affiliations", "allegiance", "organization", "organisation", "guild", "team", "teams", "agency", "class",
                               "school", "crew", "group", "unit", "squad", "year", "clan", "house", "faction", "band"]
            let role = ["occupation", "occupations", "position", "grade", "rank", "bounty", "number", "title", "titles", "job", "status", "epithet", "alias", "role"]
            let relations = ["relatives", "family", "spouse", "partner", "partners", "siblings", "sibling", "parents", "children", "father", "mother",
                             "brother", "sister", "son", "daughter", "husband", "wife"]
            if profile.contains(id) { return .profile }
            if affiliation.contains(id) { return .affiliation }
            if role.contains(id) { return .role }
            if relations.contains(id) { return .relations }
            if id.hasPrefix("favorite") || id.hasPrefix("favourite") || ["hobbies", "hobby", "likes", "dislikes", "interests", "special-skills"].contains(id) { return .interests }
            let powers = ["combat-style", "cursed-technique", "quirk", "zanpakutou", "zanpakuto", "abilities", "ability", "skills-&-abilities", "skills",
                          "magic", "technique", "techniques", "knightmare-frame", "franxx", "weapon", "weapons", "stand", "devil-contracts", "nen", "powers",
                          "fighting-style", "breathing-style", "element", "summon", "familiar", "mecha"]
            if powers.contains(id) || id.contains("devil-fruit") || id.contains("technique") || id.contains("ability") { return .powers }
            return .other
        }
    }
    struct Fact: Identifiable {
        let id: String
        let label: String
        let icon: String
        let markdown: String
        var kind: Kind { Kind.of(id) }
        /// The value as separate items when it's a list ("Eden Academy, Unknown Organization"),
        /// splitting on commas and semicolons outside brackets and links.
        var items: [String] {
            var parts: [String] = [], current = "", depth = 0
            let characters = Array(markdown)
            for (index, character) in characters.enumerated() {
                if "([<".contains(character) { depth += 1 } else if ")]>".contains(character) { depth = max(0, depth - 1) }
                // "3,000,000,000 Berries": a comma between digits is part of a number.
                let inNumber = character == "," && index > 0 && index + 1 < characters.count
                    && characters[index - 1].isNumber && characters[index + 1].isNumber
                if (character == "," || character == ";") && depth == 0 && !inNumber {
                    parts.append(current); current = ""
                } else { current.append(character) }
            }
            parts.append(current)
            let clean = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Prose with commas (a sentence) stays one item; links count only their visible text.
            return clean.count > 1 && clean.allSatisfy({ Self.visible($0).count <= 60 }) ? clean : [markdown]
        }
        /// The text a reader sees: link titles without their addresses, no HTML tags.
        static func visible(_ markdown: String) -> String {
            markdown.replacing(/\]\([^)]*\)/, with: "]").replacing(/<[^>]+>/, with: "")
                .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        }
    }
    /// A bulleted section of the description ("Awards", "Trivia", "Non-anime roles").
    struct Section: Identifiable {
        let title: String
        let items: [String]
        var id: String { title.lowercased() }
        var icon: String {
            let key = title.lowercased()
            if key.contains("award") || key.contains("honor") || key.contains("honour") { return "trophy" }
            if key.contains("trivia") || key.contains("fact") { return "lightbulb" }
            if key.contains("music") || key.contains("song") || key.contains("album") || key.contains("discograph") { return "music.note" }
            if key.contains("role") || key.contains("credit") || key.contains("work") || key.contains("radio") || key.contains("program") { return "mic" }
            if key.contains("career") || key.contains("life") || key.contains("education") || key.contains("biograph") { return "book" }
            return "list.bullet"
        }
    }
    let markdown: String
    /// Where the prose came from ("Wikipedia", "Crunchyroll"), when it said so in a credit line.
    let source: String?
    let links: [ProfileWebsiteLink]
    let references: [ProfileReferenceLink]
    let facts: [Fact]
    let sections: [Section]
    init(description: String, hideSpoilers: Bool) {
        let content = ProfileBiographyContent(description: description, hideSpoilers: hideSpoilers)
        links = content.links
        references = content.references
        // Any "__Label:__ value" (or **Label:** value) line is a field; a label alone on a line
        // followed by bullets is a section.
        let field = try? NSRegularExpression(pattern: #"^\s*(?:[-*]\s+)?(?:\*\*|__)\s*([^*_\n:]{2,40}?)\s*:?\s*(?:\*\*|__)\s*:?\s*(.+?)\s*$"#)
        let heading = try? NSRegularExpression(pattern: #"^\s*(?:#{1,6}\s*)?(?:\*\*|__)?\s*([^*_\n:#]{2,40}?)\s*:?\s*(?:\*\*|__)?\s*:?\s*$"#)
        let bullet = try? NSRegularExpression(pattern: #"^\s*(?:[-*•]|\d+[.)])\s+(.+?)\s*$"#)
        let skipped: Set<String> = ["note", "notes", "source", "sources", "spoiler", "spoilers", "warning"]
        func match(_ regex: NSRegularExpression?, _ line: String) -> [String]? {
            guard let found = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (1..<found.numberOfRanges).compactMap { Range(found.range(at: $0), in: line).map { String(line[$0]) } }
        }
        let lines = content.markdown.components(separatedBy: "\n")
        var body: [String] = [], fields: [Fact] = [], seen = Set<String>(), found: [Section] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            // A heading (bold or #) followed by bullet lines: a section of its own.
            if let title = match(heading, line)?.first, line.contains("__") || line.contains("**") || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                var items: [String] = [], next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty, items.isEmpty { next += 1 }
                while next < lines.count, let item = match(bullet, lines[next])?.first { items.append(item); next += 1 }
                if !items.isEmpty && !skipped.contains(title.lowercased()) {
                    found.append(Section(title: title.trimmingCharacters(in: .whitespaces), items: items)); index = next; continue
                }
            }
            if let parts = match(field, line), parts.count == 2 {
                let label = parts[0].trimmingCharacters(in: .whitespaces), value = parts[1]
                let id = label.lowercased().replacingOccurrences(of: " ", with: "-")
                // Long labelled paragraphs stay prose, with no data silently discarded.
                if value.count <= 400, !value.trimmingCharacters(in: .whitespaces).isEmpty, !skipped.contains(label.lowercased()),
                   label.count <= 32, seen.insert(id).inserted {
                    let icon: String
                    switch id { case "height": icon = "ruler"; case "weight": icon = "scalemass"; case "blood-type": icon = "drop"
                    default: icon = Kind.of(id).icon }
                    fields.append(Fact(id: id, label: label.prefix(1).uppercased() + label.dropFirst(), icon: icon, markdown: value))
                    index += 1; continue
                }
            }
            body.append(line); index += 1
        }
        facts = fields
        sections = found
        // A spoiler-only role list must not leave a dangling section heading.
        while let last = body.last {
            if last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body.removeLast(); continue }
            if last.range(of: #"^\s*(?:#{1,6}\s+.+|(?:\*\*|__)[^\n]+:(?:\*\*|__)|(?:\*\*|__)[^\n]+(?:\*\*|__):)\s*$"#, options: .regularExpression) != nil { body.removeLast(); continue }
            break
        }
        let cleaned = ProfileText.withoutSourceCredit(body.joined(separator: "\n").replacing(/\n{3,}/, with: "\n\n"))
        markdown = cleaned.text
        source = cleaned.source
    }
    /// Awards a TMDB biography mentions ("won an Academy Award", "two Golden Globes"), by name.
    static func awards(in text: String) -> [String] {
        let names: [(String, String)] = [("Academy Award|Oscar", "Academy Award"), ("Golden Globe", "Golden Globe"), ("Primetime Emmy|Emmy", "Emmy"),
                                         ("BAFTA", "BAFTA"), ("Grammy", "Grammy"), ("Tony Award", "Tony Award"),
                                         ("Screen Actors Guild|SAG Award", "SAG Award"), ("Critics' Choice|Critics Choice", "Critics’ Choice"),
                                         ("Baeksang", "Baeksang Arts Award"), ("Blue Dragon", "Blue Dragon Award"), ("Japan Academy", "Japan Academy Prize"),
                                         ("Seiyuu Award|Seiyu Award", "Seiyu Award"), ("Cannes", "Cannes"), ("Venice Film Festival|Volpi Cup", "Venice"),
                                         ("Berlin(?:ale| International Film Festival)|Silver Bear|Golden Bear", "Berlinale"), ("Saturn Award", "Saturn Award"),
                                         ("Annie Award", "Annie Award"), ("KBS Drama Award|SBS Drama Award|MBC Drama Award", "Korean drama award")]
        return names.compactMap { pattern, name in text.range(of: #"\b(?:"# + pattern + #")"#, options: [.regularExpression, .caseInsensitive]) != nil ? name : nil }
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
