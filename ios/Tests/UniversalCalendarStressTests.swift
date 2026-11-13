import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Canned TMDB, AniList and Wikidata replies, so the calendar's Everything code runs for real in
/// the simulator with no key and no network.
private final class CalendarStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var start: TimeInterval = 0
    /// Set by the test, read on the loading thread: behind a lock, so the sanitizer sees no race of the test's own.
    static var airingStart: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return start }
        set { lock.lock(); start = newValue; lock.unlock() }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return ["api.themoviedb.org", "graphql.anilist.co", "query.wikidata.org"].contains(host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        if url.host == "api.themoviedb.org", url.path.hasSuffix("discover/tv") {
            body = Self.shows
        } else if url.host == "api.themoviedb.org" {
            let day = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "primary_release_date.gte" }?.value ?? "2026-11-14"
            body = Self.movies(day)
        } else if url.host == "graphql.anilist.co" {
            body = Self.anime(Self.airingStart)
        } else {
            body = #"{"results":{"bindings":[]}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static let shows: String = {
        var items = (0..<12).map { index in
            #"{"id":\#(100 + index),"name":"Show \#(index)","poster_path":"/p\#(index).jpg","genre_ids":[18],"popularity":\#(100 - index),"original_language":"en","first_air_date":"2020-01-01"}"#
        }
        // Japanese animation: left out when anime comes from AniList.
        items.append(#"{"id":999,"name":"Anime on TMDB","genre_ids":[16],"popularity":50,"original_language":"ja","first_air_date":"2020-01-01"}"#)
        return #"{"results":[\#(items.joined(separator: ","))]}"#
    }()
    static func movies(_ day: String) -> String {
        let items = (0..<10).map { index in
            #"{"id":\#(500 + index),"title":"Movie \#(index)","poster_path":"/m\#(index).jpg","genre_ids":[18],"popularity":\#(80 - index),"release_date":"\#(day)"}"#
        }
        return #"{"results":[\#(items.joined(separator: ","))]}"#
    }
    static func anime(_ start: TimeInterval) -> String {
        let slots = (0..<30).map { index in
            #"{"airingAt":\#(Int(start) + 3_600 * (index + 1)),"episode":\#(index + 1),"media":{"id":\#(1000 + index % 10),"format":"TV","isAdult":false,"popularity":\#(500 - index),"averageScore":80,"genres":["Drama","Action"],"title":{"english":"Anime \#(index % 10)","romaji":"Anime \#(index % 10)"},"coverImage":{"large":"https://example.test/a.jpg"},"startDate":{"year":2026}}}"#
        }
        return #"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"airingSchedules":[\#(slots.joined(separator: ","))]}}}"#
    }
}

/// The calendar's Everything tab crashed on the owner's phone with task memory overwritten while
/// it loaded beside the schedule calculation. This loads it many times, two loads overlapping and
/// the schedule worked out at the same time; the Thread Sanitizer check runs it to catch any
/// unsafe overlap even when it doesn't crash.
@MainActor final class UniversalCalendarStressTests: XCTestCase {
    func testEverythingLoadsRepeatedlyBesideTheScheduleWithoutRepeatsOrRaces() async throws {
        URLProtocol.registerClass(CalendarStub.self)
        defer { URLProtocol.unregisterClass(CalendarStub.self) }
        let store = DiaryStore(outboxStore: MemorySyncOutboxStore(), providerSettingsStore: MemoryProviderSettingsStore())
        XCTAssertTrue(store.updateCustomTmdbToken("stub-token-for-the-calendar-test"))
        let workspace = PreviewData.workspace
        let base = try XCTUnwrap(DiaryDate.parse("2026-11-14T12:00:00Z"))
        for round in 0..<24 {
            let now = base.addingTimeInterval(Double(round) * 86_400)
            CalendarStub.airingStart = now.timeIntervalSince1970
            let schedule = Task.detached(priority: .userInitiated) {
                UpcomingSchedule(workspace: workspace, now: now, category: .all, horizonDays: 30, dedupeByTitle: true, mode: .upcoming).items.count
            }
            let filter = UniversalReleases.Filter.allCases[round % UniversalReleases.Filter.allCases.count]
            let genres: Set<String> = round % 5 == 0 ? ["Drama"] : []
            async let first = UniversalReleases.load(store: store, days: [7, 14, 30][round % 3], filter: filter, genres: genres, now: now)
            async let second = UniversalReleases.load(store: store, days: 7, filter: .all, genres: [], now: now.addingTimeInterval(43 * 86_400))
            let (a, b) = try await (first, second)
            _ = await schedule.value
            for items in [a, b] {
                XCTAssertEqual(Set(items.map(\.id)).count, items.count, "each release once")
                XCTAssertFalse(items.contains { $0.name == "Anime on TMDB" && filter == .all }, "TMDB's Japanese animation is left to AniList")
            }
            XCTAssertFalse(b.isEmpty)
            if filter != .anime { XCTAssertFalse(a.isEmpty) }
        }
    }
}
