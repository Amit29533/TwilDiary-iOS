import XCTest
import UserNotifications
@testable import TwilDiary

/// A poster served from TMDB's image host, counting its downloads.
private final class PosterStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var downloads: Int {
        get { lock.lock(); defer { lock.unlock() }; return count }
        set { lock.lock(); count = newValue; lock.unlock() }
    }
    /// A 1×1 PNG.
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image.tmdb.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.downloads += 1
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Self.image)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Owner's request: the show's or anime's picture on every alert. The simulator can't show the
/// poster in place of the app icon (that needs the Communication Notifications permission from
/// the install's signing); this checks the alert carries the poster, and keeps it without a poster.
@MainActor final class NotificationArtworkTests: XCTestCase {
    private func alert() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Silo"; content.body = "S2 E3 is out today."; content.threadIdentifier = "tv:125988"
        return content
    }
    func testAlertCarriesThePosterAndDownloadsItOnce() async throws {
        URLProtocol.registerClass(PosterStub.self)
        defer { URLProtocol.unregisterClass(PosterStub.self) }
        PosterStub.downloads = 0
        let poster = "https://image.tmdb.org/t/p/w500/test-\(UUID().uuidString).png"
        let first = await NotificationArtwork.finish(alert(), from: "Silo", conversation: "tv:125988", poster: poster)
        XCTAssertEqual(first.attachments.count, 1, "the poster is attached")
        XCTAssertEqual(first.attachments.first?.identifier, "poster")
        XCTAssertEqual(first.body, "S2 E3 is out today.")
        let second = await NotificationArtwork.finish(alert(), from: "Silo", conversation: "tv:125988", poster: poster)
        XCTAssertEqual(second.attachments.count, 1, "the next alert gets its own copy")
        XCTAssertEqual(PosterStub.downloads, 1, "the poster is downloaded once and kept on the phone")
    }
    func testAlertWithoutAPosterStillGoes() async {
        let plain = await NotificationArtwork.finish(alert(), from: "Silo", conversation: "tv:125988", poster: nil)
        XCTAssertTrue(plain.attachments.isEmpty)
        XCTAssertEqual(plain.title, "Silo"); XCTAssertEqual(plain.body, "S2 E3 is out today.")
    }
}
