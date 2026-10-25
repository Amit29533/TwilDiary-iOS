import Foundation
import TwilDiaryCore

/// Disposable UI-test responses only. Release navigation always uses authenticated APIs.
#if DEBUG
enum PreviewCatalog {
    private static func decode<T: Decodable>(_ name: String) -> T {
        let url = Bundle.main.url(forResource: name, withExtension: "json")!
        return try! JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    static func page(query: String = "", page: Int = 1, type: String = "all") -> CatalogPage {
        let fixture: CatalogPage = decode("catalog-page")
        return CatalogPage(items: fixture.items.filter { (type == "all" || $0.mediaType.rawValue == type) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }, page: 1, totalPages: 1)
    }
    static func discovery(_ query: [String: String]) -> CatalogPage {
        var filters = DiscoveryFilters(section: .genres)
        filters.type = query["type"] ?? "tv"; filters.genre = query["genre"] ?? ""
        filters.year = query["year"] ?? ""; filters.sort = query["sort"] ?? "popular"; filters.minimum = query["minimum"] ?? "0"
        let fixture: CatalogPage = decode("catalog-page")
        let items = filters.applying(fixture.items), page = max(1, Int(query["page"] ?? "1") ?? 1)
        return CatalogPage(items: Array(items.dropFirst((page - 1) * 12).prefix(12)), page: page, totalPages: max(1, (items.count + 11) / 12))
    }
    static func browse(_ route: CatalogRoute) -> CatalogBrowse {
        let url = Bundle.main.url(forResource: "catalog-browse", withExtension: "json")!
        var value = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var details = value["details"] as! [String: Any]
        details["id"] = route.id; details["mediaType"] = route.kind.rawValue
        details["suggestedCategory"] = route.kind == .movie ? "movie" : "anime"
        details["runtimeMinutes"] = route.kind == .movie ? 112 : 24
        if route.kind == .movie { details["seasons"] = [] }
        value["details"] = details
        return try! JSONDecoder().decode(CatalogBrowse.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static var cast: CastResponse { decode("catalog-cast") }
    static var related: RelatedResponse { decode("catalog-related") }
    static var person: PersonResponse { decode("catalog-person") }
}
#endif
