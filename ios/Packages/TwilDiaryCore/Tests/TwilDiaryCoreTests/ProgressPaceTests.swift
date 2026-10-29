import Foundation
import Testing
@testable import TwilDiaryCore

private let start = Date(timeIntervalSince1970: 1_000_000)

@Test func paceNeedsFiveSecondsOfProgressThenEstimatesTheTimeLeft() {
    var pace = ProgressPace()
    pace.record(0, at: start, scope: "compare")
    pace.record(40, at: start.addingTimeInterval(4), scope: "compare")
    #expect(pace.perSecond == nil, "Under five seconds is too little to judge")
    pace.record(100, at: start.addingTimeInterval(10), scope: "compare")
    #expect(pace.perSecond == 10)
    #expect(pace.secondsLeft(remaining: 600) == 60)
    #expect(ProgressPace.label(seconds: pace.secondsLeft(remaining: 600)) == "About 1 min left")
    #expect(pace.startedAt == start)
}

@Test func paceStartsOverForANewStageOrACountThatGoesBack() {
    var pace = ProgressPace()
    pace.record(0, at: start, scope: "history")
    pace.record(100, at: start.addingTimeInterval(10), scope: "history")
    pace.record(5, at: start.addingTimeInterval(11), scope: "titles")
    #expect(pace.samples.count == 1); #expect(pace.perSecond == nil)
    pace.record(50, at: start.addingTimeInterval(20), scope: "titles")
    pace.record(10, at: start.addingTimeInterval(21), scope: "titles")
    #expect(pace.samples == [ProgressPace.Sample(date: start.addingTimeInterval(21), done: 10)])
}

@Test func paceKeepsOnlyTheLastMinute() {
    var pace = ProgressPace()
    pace.record(0, at: start, scope: "apply")
    pace.record(10, at: start.addingTimeInterval(30), scope: "apply")
    pace.record(200, at: start.addingTimeInterval(90), scope: "apply")
    #expect(pace.samples.map(\.done) == [10, 200])
    #expect(pace.perSecond == 190.0 / 60)
}

@Test func timeLabelsReadNaturally() {
    #expect(ProgressPace.label(seconds: nil) == nil)
    #expect(ProgressPace.label(seconds: 20) == "Less than a minute left")
    #expect(ProgressPace.label(seconds: 4 * 60 + 10) == "About 4 min left")
    #expect(ProgressPace.label(seconds: 80 * 60) == "About 1 h 20 min left")
    #expect(ProgressPace.elapsed(42) == "42 s")
    #expect(ProgressPace.elapsed(70) == "1m 10s")
    #expect(ProgressPace.elapsed(3720) == "1h 02m")
}

private func run(_ stage: String, page: Int = 1, progress: Int = 0, state: String = "building") -> TraktSync.Run {
    TraktSync.Run(id: "r", state: state, stage: stage, page: page, progress: progress, ratingMode: nil, error: nil, retryAfter: 0)
}

@Test func scanStagesSplitTheComparisonIntoThirdsSizedByTheirOwnTotals() {
    let remote = TraktScanStages(run: run("plan-remote-batch", page: 501, progress: 2000), localPlays: 1000, localTitles: 300)
    #expect(remote.current == .compare); #expect(remote.done == 500); #expect(remote.total == 2000)
    #expect(remote.compare == 0.25 / 3)
    let history = TraktScanStages(run: run("plan-history-batch", page: 501), localPlays: 1000, localTitles: 300)
    #expect(history.compare == 1.5 / 3); #expect(history.total == 1000)
    let titles = TraktScanStages(run: run("plan-titles-batch", page: 301), localPlays: 1000, localTitles: 300)
    #expect(titles.compare == 1); #expect(titles.done == 300)
    #expect(TraktScanStages(run: run("history", page: 3, progress: 300), localPlays: 1, localTitles: 1).current == .download)
    let review = TraktScanStages(run: run("ready", state: "review"), localPlays: 1, localTitles: 1)
    #expect(review.current == .review); #expect(review.compare == 1)
}
