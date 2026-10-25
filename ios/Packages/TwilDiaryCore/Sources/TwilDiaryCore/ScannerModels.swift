import Foundation

public struct UnmatchedScan: Decodable, Identifiable, Equatable, Sendable {
    public let id: String, version: Int, deviceId: String, deviceName: String, volumeId: String, driveLetter: String
    public let root: String, relativePath: String, name: String, seasonNumber: Int?, fileCount: Int, sizeBytes: Int64?, checkedAt: String
}
public struct ScannerReviewPage: Decodable, Sendable {
    public let items: [UnmatchedScan], nextCursor: String?
    public init(items: [UnmatchedScan], nextCursor: String?) { self.items = items; self.nextCursor = nextCursor }
}
