import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

/// "Too many requests" becomes a saved pause: Retry-After in seconds or as a date, MDBList's and
/// Simkl's reset (epoch or seconds) when the allowance is used up, a minute when unsaid; clamped.
@Test func cooldownsComeFromTheServicesOwnHeaders() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(ProviderCooldown.until(status: 200, headers: [:], now: now) == nil)
    #expect(ProviderCooldown.until(status: 429, headers: ["Retry-After": "30"], now: now) == now.addingTimeInterval(30))
    #expect(ProviderCooldown.until(status: 429, headers: ["retry-after": "Fri, 15 Jan 2027 09:00:00 GMT"], now: now) == now.addingTimeInterval(3_600))
    #expect(ProviderCooldown.until(status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"], now: now) == now.addingTimeInterval(600))
    #expect(ProviderCooldown.until(status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "90"], now: now) == now.addingTimeInterval(90))
    #expect(ProviderCooldown.until(status: 200, headers: ["X-RateLimit-Remaining": "12", "X-RateLimit-Reset": "90"], now: now) == nil)
    #expect(ProviderCooldown.until(status: 429, headers: [:], now: now) == now.addingTimeInterval(60))
    #expect(ProviderCooldown.until(status: 429, headers: ["Retry-After": "0"], now: now) == now.addingTimeInterval(5))
}

/// A watch whose answer was lost counts as delivered only when the service shows that play
/// (same title and episode, within two minutes); otherwise it's safe to send again.
@Test func aLostWatchIsCheckedAgainstTheServicesCopyBeforeResending() throws {
    let base = try SampleWorkspace.mapped()
    let movie = try #require(base.titles.first { !$0.isSeries && $0.tmdbId != nil })
    let watch = OptimisticMutation.markWatch(operationId: "o", titleId: movie.id, episodeId: nil, watchedAt: "2026-11-05T20:00:00.000Z",
                                             recordedAt: "2026-11-05T20:00:00.000Z", rewatch: false)
    let ref = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: movie.tmdbId, name: movie.name)
    #expect(LostWriteCheck.delivered(watch, in: base, library: TraktLibrary(plays: [TraktPlay(historyId: 1, title: ref, watchedAt: "2026-11-05T20:01:00Z")])))
    #expect(!LostWriteCheck.delivered(watch, in: base, library: TraktLibrary(plays: [TraktPlay(historyId: 1, title: ref, watchedAt: "2026-11-01T20:00:00Z")])))
    #expect(!LostWriteCheck.delivered(watch, in: base, library: TraktLibrary()))
    let rating = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil)
    #expect(!LostWriteCheck.delivered(rating, in: base, library: TraktLibrary()))
}
