import Foundation

/// What reached the service holding your diary from somewhere else since the last read: a watch
/// Infuse scrobbled to Trakt, a rating or a watchlist add made on trakt.tv. Found by comparing the
/// phone's copy before a read (which already has your own TwilDiary edits) with the copy after
/// it, so your own edits, sent to every service as you made them, aren't passed on twice.
/// Only additions: a watch, a new or changed rating, Planned, Dropped. Nothing is taken off.
public struct OutsideChanges: Equatable, Sendable {
    public struct Play: Equatable, Sendable {
        public let tmdb: Int
        public let movie: Bool
        public let season: Int?
        public let episode: Int?
        public let watchedAt: String
        /// The same movie or episode was watched before (a rewatch, for services that keep them).
        public let rewatch: Bool
        public var key: String { (movie ? "movie:" : "tv:") + String(tmdb) }
    }
    public struct Title: Equatable, Sendable {
        public let tmdb: Int
        public let movie: Bool
        public var key: String { (movie ? "movie:" : "tv:") + String(tmdb) }
    }
    public var plays: [Play] = []
    public var ratings: [(title: Title, rating: Int)] = []
    public var planned: [Title] = []
    public var dropped: [Title] = []
    /// More than `limit` changes at once (an import on the service's website): left for a match
    /// you start yourself, so a whole history isn't pushed out in the background.
    public var tooMany = false

    public var isEmpty: Bool { plays.isEmpty && ratings.isEmpty && planned.isEmpty && dropped.isEmpty }
    public var count: Int { plays.count + ratings.count + planned.count + dropped.count }
    /// Every title involved ("tv:1399").
    public var keys: Set<String> { Set(plays.map(\.key) + ratings.map(\.title.key) + planned.map(\.key) + dropped.map(\.key)) }

    public static func == (a: OutsideChanges, b: OutsideChanges) -> Bool {
        a.plays == b.plays && a.planned == b.planned && a.dropped == b.dropped && a.tooMany == b.tooMany
            && a.ratings.map { "\($0.title.key)=\($0.rating)" } == b.ratings.map { "\($0.title.key)=\($0.rating)" }
    }

    /// `old`: the copy before this read; nil or never read (`fetchedAt` nil): nothing is passed on,
    /// so connecting a service doesn't push its whole history out.
    public static func find(old: TraktLibrary?, new: TraktLibrary, limit: Int = 300) -> OutsideChanges {
        guard let old, old.fetchedAt != nil else { return OutsideChanges() }
        var result = OutsideChanges()
        func title(_ ref: TraktTitleRef) -> Title? { ref.tmdbId.map { Title(tmdb: $0, movie: ref.kind == .movie) } }
        func item(_ play: TraktPlay) -> String? {
            guard let key = play.title.diaryKey else { return nil }
            return play.season.map { key + "|s\($0)e\(play.episode ?? 0)" } ?? key
        }
        // The same watch is the same item at the same minute (a copy made from your edit has the
        // time you logged; Trakt keeps it to the second).
        func moment(_ play: TraktPlay) -> String? {
            guard let item = item(play), let when = play.watchedAt, when.count >= 16 else { return nil }
            return item + "@" + String(when.prefix(16))
        }
        let known = Set(old.plays.compactMap(moment))
        let seenBefore = Set(old.plays.compactMap(item))
        var added = Set<String>()
        for play in new.plays.sorted(by: { ($0.watchedAt ?? "") < ($1.watchedAt ?? "") }) where play.isMovieOrEpisode {
            guard let moment = moment(play), !known.contains(moment), added.insert(moment).inserted,
                  let item = item(play), let ref = title(play.title), let when = play.watchedAt else { continue }
            let earlier = seenBefore.contains(item) || result.plays.contains { $0.matches(item) }
            result.plays.append(Play(tmdb: ref.tmdb, movie: ref.movie, season: play.season, episode: play.episode, watchedAt: when, rewatch: earlier))
        }
        let oldRatings = Dictionary(old.ratings.compactMap { rating in rating.title.diaryKey.map { ($0, rating.rating) } }, uniquingKeysWith: { first, _ in first })
        var rated = Set<String>()
        for rating in new.ratings {
            guard let key = rating.title.diaryKey, oldRatings[key] != rating.rating, (1...10).contains(rating.rating),
                  rated.insert(key).inserted, let ref = title(rating.title) else { continue }
            result.ratings.append((ref, rating.rating))
        }
        func adds(_ old: [TraktListed], _ new: [TraktListed]) -> [Title] {
            let before = Set(old.compactMap(\.title.diaryKey))
            var seen = Set<String>()
            return new.compactMap { listed in
                guard let key = listed.title.diaryKey, !before.contains(key), seen.insert(key).inserted else { return nil }
                return title(listed.title)
            }
        }
        result.planned = adds(old.watchlist, new.watchlist)
        result.dropped = adds(old.dropped, new.dropped)
        if result.count > limit { return OutsideChanges(tooMany: true) }
        return result
    }
}

extension OutsideChanges.Play {
    /// Whether this play is the movie or episode `item` names ("tv:1399|s1e2", "movie:603").
    func matches(_ item: String) -> Bool {
        let base = (movie ? "movie:" : "tv:") + String(tmdb)
        return (season.map { base + "|s\($0)e\(episode ?? 0)" } ?? base) == item
    }
}
