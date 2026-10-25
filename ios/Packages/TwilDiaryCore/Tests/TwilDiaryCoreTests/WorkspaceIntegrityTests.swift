import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func duplicateSnapshotSectionsAreRejectedWithoutDiscardingValidRewatches() throws {
    let original = SampleWorkspace.make()
    let title = try #require(original.titles.first)
    let episode = try #require(original.episodes.first)
    let event = try #require(original.events.first)
    let location = FileLocation(id: "copy", titleId: title.id, deviceName: "Fixture", deviceId: nil, volumeId: nil,
                                driveLetter: "E:", root: "E:\\", relativePath: "Title", season: nil,
                                fileCount: 1, evidence: "present", sizeBytes: nil, checkedAt: nil)
    var cases: [(Workspace, String)] = []
    var titles = original; titles.titles.append(title); cases.append((titles, "titles"))
    var episodes = original; episodes.episodes.append(episode); cases.append((episodes, "episodes"))
    var events = original; events.events.append(event); cases.append((events, "watches"))
    var locations = original; locations.locations = [location, location]; cases.append((locations, "locations"))
    for (workspace, section) in cases {
        #expect(throws: WorkspaceIntegrityError.duplicateIdentity(section: section)) { try workspace.validatingIdentities() }
    }
    #expect(try original.validatingIdentities().titles == original.titles)
    var rewatch = original
    rewatch.events.append(WatchEvent(id: "different-event", operationId: "different-operation", titleId: event.titleId, episodeId: event.episodeId,
                                    watchedAt: event.watchedAt, recordedAt: event.recordedAt, revokedAt: nil, origin: event.origin, version: event.version))
    #expect(try rewatch.validatingIdentities().events.count == original.events.count + 1)
}

@Test func malformedInMemorySnapshotsCannotCrashOrDoubleCountHomeAndHistory() throws {
    let original = SampleWorkspace.make()
    let now = try #require(DiaryDate.parse("2026-10-23T12:00:00Z"))
    let zone = try #require(TimeZone(secondsFromGMT: 0))
    let expected = HomeOverview(workspace: original, now: now, calendar: DiaryDate.calendar(timeZone: zone))
    let history = HistoryQuery().entries(in: original, timeZone: zone)
    var repeated = original
    repeated.titles += original.titles; repeated.episodes += original.episodes; repeated.events += original.events
    let actual = HomeOverview(workspace: repeated, now: now, calendar: DiaryDate.calendar(timeZone: zone))
    #expect(actual.minutes == expected.minutes)
    #expect(actual.watches == expected.watches)
    let rows = HistoryQuery().entries(in: repeated, timeZone: zone)
    #expect(rows.map(\.id) == history.map(\.id))
    #expect(rows.map(\.rewatched) == history.map(\.rewatched))
}

@Test func incompleteCrossSectionReferencesAreRejectedWithoutDroppingRecords() throws {
    let original = SampleWorkspace.make()
    let event = try #require(original.events.first { $0.episodeId != nil })
    let episodeID = try #require(event.episodeId)
    let other = try #require(original.titles.first { $0.id != event.titleId })
    var missingTitle = original; missingTitle.titles.removeAll { $0.id == event.titleId }
    var missingEpisode = original; missingEpisode.episodes.removeAll { $0.id == episodeID }
    var wrongOwner = original
    wrongOwner.events = [WatchEvent(id: "cross-owner", operationId: "cross-operation", titleId: other.id, episodeId: episodeID,
                                   watchedAt: event.watchedAt, recordedAt: event.recordedAt, revokedAt: nil, origin: "manual", version: 1)]
    var missingLocation = original
    missingLocation.locations = [FileLocation(id: "orphan-location", titleId: "missing-title", deviceName: "Fixture", deviceId: nil, volumeId: nil,
                                              driveLetter: "E:", root: "E:\\", relativePath: "Fixture", season: nil,
                                              fileCount: 1, evidence: "present", sizeBytes: nil, checkedAt: nil)]
    for workspace in [missingTitle, missingEpisode, wrongOwner, missingLocation] {
        #expect(throws: WorkspaceIntegrityError.incompleteSnapshot) { try workspace.validatingIdentities() }
    }
    #expect(try original.validatingIdentities().events == original.events)
}
