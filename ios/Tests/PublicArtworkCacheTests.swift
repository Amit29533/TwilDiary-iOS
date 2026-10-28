import XCTest
import UIKit
@testable import TwilDiary

private final class ArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var status = 200
        private var count = 0
        func reset(_ data: Data, status: Int = 200) { lock.lock(); defer { lock.unlock() }; self.data = data; self.status = status; count = 0 }
        func reply() -> (Data, Int) { lock.lock(); defer { lock.unlock() }; count += 1; return (data, status) }
        func requests() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status) = Self.state.reply()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                  headerFields: ["Content-Type":"image/png"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class PublicArtworkCacheTests: XCTestCase {
    private func cache() -> PublicArtworkCache {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArtworkURLProtocol.self]
        return PublicArtworkCache(configuration: config)
    }
    private func request(pixels: Double = 128) throws -> PublicArtworkRequest {
        try XCTUnwrap(PublicArtworkRequest(path: "https://image.tmdb.org/t/p/w780/" + UUID().uuidString + ".png", pixels: pixels))
    }
    func testArtworkRejectsPrivateAndUnexpectedDestinationsAndInvalidSizes() {
        for path in ["http://image.tmdb.org/t/p/w342/a.jpg", "https://example.test/t/p/w342/a.jpg", "https://secret@image.tmdb.org/t/p/w342/a.jpg", "https://image.tmdb.org/api/private", "https://image.tmdb.org/t/p/w342/a.jpg?token=secret"] {
            XCTAssertNil(PublicArtworkRequest(path: path, pixels: 200))
        }
        for value in [Double.nan, .infinity, 0, -1] { XCTAssertNil(PublicArtworkRequest(path: "https://image.tmdb.org/t/p/w342/a.jpg", pixels: value)) }
    }
    func testArtworkUsesStableResolutionBucketsInsteadOfReloadingForEveryLayoutPixel() throws {
        let value = try request(), path = value.url.absoluteString
        XCTAssertEqual(PublicArtworkRequest(path:path, pixels:127), PublicArtworkRequest(path:path, pixels:128))
        XCTAssertEqual(PublicArtworkRequest(path:path, pixels:257)?.pixels, 512)
        XCTAssertEqual(PublicArtworkRequest(path:path, pixels:10000)?.pixels, 1536)
    }
    func testLargeArtworkAsksTMDbForASharperRenditionButNeverASmallerOne() {
        let poster = "https://image.tmdb.org/t/p/w500/a.jpg"
        XCTAssertEqual(PublicArtworkRequest(path: poster, pixels: 400)?.url.absoluteString, poster)
        XCTAssertEqual(PublicArtworkRequest(path: poster, pixels: 900)?.url.absoluteString, "https://image.tmdb.org/t/p/w780/a.jpg")
        XCTAssertEqual(PublicArtworkRequest(path: poster, pixels: 1206)?.url.absoluteString, "https://image.tmdb.org/t/p/w1280/a.jpg")
        XCTAssertEqual(PublicArtworkRequest(path: "https://image.tmdb.org/t/p/original/a.jpg", pixels: 1206)?.url.absoluteString, "https://image.tmdb.org/t/p/original/a.jpg")
        XCTAssertEqual(PublicArtworkRequest(path: "https://image.tmdb.org/t/p/w1280/a.jpg", pixels: 300)?.url.absoluteString, "https://image.tmdb.org/t/p/w1280/a.jpg")
    }
    func testArtworkIsDownsampledAndRetainedForSynchronousRecycledCellLookup() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width:1200,height:800), format:format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:1200,height:800))
        }
        ArtworkURLProtocol.state.reset(try XCTUnwrap(image.pngData()))
        let cache = cache(), request = try request()
        let bitmap = await cache.image(request)
        XCTAssertEqual(try XCTUnwrap(bitmap).image.width, 256)
        XCTAssertNotNil(cache.cached(request))
        _ = await cache.image(request)
        XCTAssertEqual(ArtworkURLProtocol.state.requests(), 1)
    }
    func testConcurrentCellsShareOneTransferAndFailureDoesNotRetryOnEveryScroll() async throws {
        ArtworkURLProtocol.state.reset(Data(), status:503)
        let cache = cache(), request = try request()
        async let first = cache.image(request)
        async let second = cache.image(request)
        let values = await (first,second)
        XCTAssertNil(values.0); XCTAssertNil(values.1)
        let retry = await cache.image(request)
        XCTAssertNil(retry); XCTAssertEqual(ArtworkURLProtocol.state.requests(),1)
    }
}
