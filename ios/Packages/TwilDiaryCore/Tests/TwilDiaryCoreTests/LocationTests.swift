import Foundation
import Testing
@testable import TwilDiaryCore

private func location(_ id: String, device: String = "pc", volume: String = "volume", drive: String = "E:", evidence: String = "present") throws -> FileLocation {
    let value: [String: Any] = ["id": id, "titleId": "title", "deviceName": "Windows PC", "deviceId": device, "volumeId": volume, "driveLetter": drive, "root": "E:/Media///", "relativePath": "///Anime/Season 1", "season": 1, "fileCount": 12, "evidence": evidence, "checkedAt": "2026-10-23T12:00:00Z"]
    return try JSONDecoder().decode(FileLocation.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func diskIdentitySurvivesDriveLetterChangesAndNeverCombinesDifferentDevices() throws {
    let first = try location("a"), changedLetter = try location("b", drive: "G:", evidence: "unavailable"), otherPC = try location("c", device: "second", evidence: "missing")
    #expect(first.diskKey == changedLetter.diskKey)
    #expect(first.diskKey != otherPC.diskKey)
    let disks = DiskSummary.make([first, changedLetter, otherPC])
    #expect(disks.count == 2)
    let stable = try #require(disks.first { $0.key == first.diskKey })
    #expect(stable.folders == 2 && stable.titleCount == 1 && stable.present == 1 && stable.unavailable == 1)
    #expect(stable.letters == ["E:", "G:"])
    #expect(stable.evidence == "1 confirmed folder")
    #expect(disks.first { $0.key == otherPC.diskKey }?.evidence == "Files confirmed missing")
}

@Test func serverLabelsUseOnlyConfirmedRealDriveLettersAndPathsHaveOneSeparator() throws {
    let first = try location("a", drive: " e: "), second = try location("b", drive: "D:"), disconnected = try location("c", drive: "F:", evidence: "unavailable")
    #expect(first.path == "E:\\Media\\Anime\\Season 1")
    #expect(ServerAvailability.label([first, second, disconnected]) == "Available on Server: Drive D / Drive E")
    #expect(ServerAvailability.label([disconnected]) == "Not Available on Server")
    #expect(ServerAvailability.label([]) == "Not Available on Server")
}
