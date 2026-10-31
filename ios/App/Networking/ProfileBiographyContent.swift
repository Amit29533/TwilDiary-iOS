import Foundation

/// Move standalone website lists to icon buttons, leaving prose and its inline
/// links intact. Input must be sanitized as a whole before any line is split.
struct ProfileBiographyContent {
    let markdown: String
    let links: [ProfileWebsiteLink]
    let references: [ProfileReferenceLink]
    init(description: String, hideSpoilers: Bool) {
        let clean = AniListText.markdown(description, hideSpoilers: hideSpoilers)
        var body: [String] = [], sites: [ProfileWebsiteLink] = [], native: [ProfileReferenceLink] = []
        var seen = Set<String>()
        for line in clean.components(separatedBy: "\n") {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            guard let attributed = try? AttributedString(markdown: line, options: options) else { body.append(line); continue }
            var found: [ProfileWebsiteLink] = [], references: [ProfileReferenceLink] = [], prose = ""
            for run in attributed.runs {
                if let url = run.link, let link = ProfileWebsiteLink(url: url, title: String(attributed[run.range].characters)) {
                    if ProfileDeepLink.parse(url) != nil {
                        references.append(ProfileReferenceLink(title: String(attributed[run.range].characters), url: url))
                    } else { found.append(link) }
                } else { prose += String(attributed[run.range].characters) }
            }
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|·•,;/–—-"))
            if (!found.isEmpty || !references.isEmpty), prose.trimmingCharacters(in: separators).isEmpty {
                for link in found where seen.insert(link.id).inserted { sites.append(link) }
                for link in references where seen.insert(link.id).inserted { native.append(link) }
            } else { body.append(line) }
        }
        markdown = body.joined(separator: "\n").replacing(/\n{3,}/, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        links = sites
        references = native
    }
}

struct ProfileReferenceLink: Identifiable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

struct ProfileWebsiteLink: Identifiable, Hashable {
    let url: URL
    let label: String
    let asset: String?
    let symbol: String
    var id: String { url.absoluteString }
    init?(url: URL, title: String) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.url = url
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        symbol = title.localizedCaseInsensitiveContains("profile") ? "person.crop.rectangle" : "globe"
        if matches("youtube.com") || matches("youtu.be") { label = "YouTube"; asset = "site-youtube" }
        else if matches("twitter.com") || matches("x.com") { label = "X"; asset = "site-x" }
        else if matches("instagram.com") { label = "Instagram"; asset = "site-instagram" }
        else if matches("anilist.co") { label = "AniList profile"; asset = "site-anilist" }
        else if matches("wikipedia.org") { label = title.isEmpty ? "Wikipedia" : title; asset = nil }
        else { label = title.isEmpty ? host : title; asset = nil }
    }
}

enum ProfileDate {
    static func partial(year: Int?, month: Int?, day: Int?) -> String? {
        let year = year.flatMap { (1...9999).contains($0) ? $0 : nil }
        guard let month else { return year.map(String.init) }
        guard (1...12).contains(month) else { return year.map(String.init) }
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let name = calendar.monthSymbols[month - 1]
        guard let day else { return name + (year.map { " " + String($0) } ?? "") }
        guard let date = calendar.date(from: DateComponents(year: year ?? 2000, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: date), days.contains(day) else { return nil }
        return String(day) + " " + name + (year.map { " " + String($0) } ?? "")
    }

    /// Preserve partial birthdays (and leap days); never invent a birth year.
    static func short(_ value: String) -> String {
        if value.range(of: #"^\d{4}$"#, options: .regularExpression) != nil { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.defaultDate = Date(timeIntervalSince1970: 946684800) // leap year 2000
        let fullYear = value.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil
        for input in fullYear ? ["d MMMM yyyy", "d MMM yyyy", "yyyy-MM-dd", "MMMM yyyy", "MMM yyyy"] : ["d MMMM", "d MMM", "MMMM", "MMM"] {
            formatter.dateFormat = input
            if let date = formatter.date(from: value) {
                formatter.dateFormat = input == "MMMM yyyy" || input == "MMM yyyy" ? "MMM yyyy" : input == "MMMM" || input == "MMM" ? "MMM" : fullYear ? "d MMM yyyy" : "d MMM"
                return formatter.string(from: date)
            }
        }
        return value
    }
}
