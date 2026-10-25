import Foundation

public struct DiskSummary: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String, deviceName: String
    public var letters: [String], titleIDs: Set<String>, folders: Int, present: Int, unavailable: Int, missing: Int, unverified: Int, checkedAt: String?
    public var titleCount: Int { titleIDs.count }
    public var evidence: String {
        if present > 0 { return "\(present) confirmed folder\(present == 1 ? "" : "s")" }
        if unavailable == folders { return "Disconnected · mappings kept" }
        if missing == folders { return "Files confirmed missing" }
        return "Availability not confirmed"
    }
    public static func make(_ locations: [FileLocation]) -> [Self] {
        var groups: [String: Self] = [:]
        for location in locations {
            let key = location.diskKey
            var value = groups[key] ?? Self(key: key, deviceName: location.deviceName, letters: [], titleIDs: [], folders: 0, present: 0, unavailable: 0, missing: 0, unverified: 0, checkedAt: nil)
            if !value.letters.contains(location.driveLetter) { value.letters.append(location.driveLetter) }
            value.titleIDs.insert(location.titleId); value.folders += 1
            switch location.evidence { case "present": value.present += 1; case "unavailable": value.unavailable += 1; case "missing": value.missing += 1; default: value.unverified += 1 }
            if let stamp = location.checkedAt, value.checkedAt.map({ stamp > $0 }) ?? true { value.checkedAt = stamp }
            groups[key] = value
        }
        return groups.values.sorted { left, right in
            if left.deviceName != right.deviceName { return LibraryQuery.nameBefore(left.deviceName, right.deviceName) }
            if left.letters != right.letters { return LibraryQuery.nameBefore(left.letters.joined(separator: ","), right.letters.joined(separator: ",")) }
            return left.key < right.key
        }
    }
}

public enum ServerAvailability {
    public static func label(_ locations: [FileLocation]) -> String {
        let present = locations.filter { $0.evidence == "present" }
        guard !present.isEmpty else { return "Not Available on Server" }
        let drives = Set(present.map { location in
            var name = location.driveLetter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if name.hasSuffix(":") { name.removeLast() }; return name
        }.filter { !$0.isEmpty }).sorted()
        return "Available on Server" + (drives.isEmpty ? "" : ": " + drives.map { "Drive " + $0 }.joined(separator: " / "))
    }
}

/// Owner-configured shortcuts from the web source; labels do not imply a confirmed scan.
public struct HomeDiskShortcut: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public static let all: [Self] = [
        Self(key: "drive:E:", label: "E: Toshiba (4TB)"),
        Self(key: "drive:F:", label: "F: Legion (1TB)"),
        Self(key: "drive:G:", label: "G: Seagate (1TB)")
    ]
}
