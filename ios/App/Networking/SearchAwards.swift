import Foundation
import TwilDiaryCore

enum SearchAwardCeremony: String, Decodable, CaseIterable, Identifiable {
    case emmy, bafta, actor, globe, critics, oscar
    var id: Self { self }

    var title: String {
        switch self {
        case .emmy: "Emmy Awards"
        case .bafta: "BAFTA TV Awards"
        case .actor: "Actor Awards"
        case .globe: "Golden Globes"
        case .critics: "Critics’ Choice Awards"
        case .oscar: "Academy Awards"
        }
    }

    var symbol: String {
        switch self {
        case .emmy: "sparkles.tv"
        case .bafta: "theatermasks.fill"
        case .actor: "person.fill"
        case .globe: "globe.europe.africa"
        case .critics: "star.fill"
        case .oscar: "trophy.fill"
        }
    }

    var tint: String {
        switch self {
        case .emmy, .globe, .oscar: "#f3c969"
        case .bafta: "#dfa655"
        case .actor: "#81ccba"
        case .critics: "#c4c5d9"
        }
    }
}

struct SearchAwardEdition: Decodable, Hashable, Identifiable {
    struct Category: Decodable, Hashable, Identifiable {
        let title: String
        let kind: MediaKind
        let winners: [String]
        let nominees: [String]
        var id: String { title }
    }

    let ceremony: SearchAwardCeremony
    let year: Int
    let source: URL
    let categories: [Category]
    var id: String { "\(ceremony.rawValue)-\(year)" }
    var title: String { ceremony.title + " " + String(year) }

    static let all: [Self] = {
        guard let url = Bundle.main.url(forResource: "search-awards", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let editions = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return editions.sorted { $0.year > $1.year }
    }()
}
