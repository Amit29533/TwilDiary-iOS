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
    /// Canvas Lists: six lists built from the catalog fixture's posters, one page.
    static func canvasLists(page: Int) -> CanvasListsPage {
        let posters = (decode("catalog-page") as CatalogPage).items.compactMap(\.posterPath)
        let names = ["Weekend comfort watches", "Anime films worth a rewatch", "Slow-burn mysteries", "Short seasons", "Animated favourites", "Late-night picks"]
        let lists = names.enumerated().map { index, name in
            CanvasList(id: index + 1, name: name, user: "preview\(index + 1)", itemCount: 12 + index, likes: 40 - index,
                       posters: posters.isEmpty ? [] : (0..<4).map { posters[(index + $0) % posters.count] })
        }
        return CanvasListsPage(lists: page == 1 ? lists : [], page: page, totalPages: 1)
    }
    /// Settings → Cloudflare: steady traffic with one read spike yesterday; storage reported until yesterday.
    static func cloudflareUsage(range: Int) -> CloudflareUsage {
        let now = Date.now
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let days = (0..<range).map { index -> CloudflareUsage.Day in
            let date = calendar.date(byAdding: .day, value: index - range + 1, to: now)!
            let wave = [1840, 2310, 1975, 2620, 3105, 2480, 2210][index % 7]
            let today = index == range - 1, spike = index == range - 2
            return CloudflareUsage.Day(date: CloudflareUsage.day(date), requests: today ? 1290 : wave, errors: index % 5 == 0 ? 3 : 0,
                                       rowsRead: spike ? 4_520_000 : today ? 612_000 : 380_000 + (wave * 90), rowsWritten: today ? 1_840 : 900 + wave / 2,
                                       storageBytes: today ? nil : 41_800_000 + index * 120_000)
        }
        let reset = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        return CloudflareUsage(configured: true, range: range, days: days,
                               limits: .init(requests: 100_000, rowsRead: 5_000_000, rowsWritten: 100_000, storageBytes: 5_000_000_000),
                               resetsAt: ISO8601DateFormatter().string(from: reset), fetchedAt: ISO8601DateFormatter().string(from: now), unavailable: [])
    }
    static func canvasListItems(page: Int) -> CanvasListItemsPage {
        let items = (decode("catalog-page") as CatalogPage).items.map { CanvasListItem(tmdbId: $0.id, mediaType: $0.mediaType, name: $0.name, year: $0.year, posterPath: $0.posterPath, backdropPath: $0.backdropPath) }
        return CanvasListItemsPage(items: page == 1 ? items : [], page: page, totalPages: 1)
    }
    static var cast: CastResponse { decode("catalog-cast") }
    static var related: RelatedResponse { decode("catalog-related") }
    static var person: PersonResponse { decode("catalog-person") }
}
#endif
