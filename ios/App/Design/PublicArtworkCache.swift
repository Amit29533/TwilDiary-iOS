import Foundation
import ImageIO
import CoreGraphics

/// Public, immutable bitmaps only. Private diary responses and credentials never
/// enter this cache. NSCache supports concurrent lookups from rendering/decoding.
final class PublicArtworkBitmap: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image; super.init() }
}

struct PublicArtworkRequest: Hashable, Sendable {
    let url: URL
    let pixels: Int
    var key: String { url.absoluteString + "#" + String(pixels) }
    init?(path: String?, pixels: Double) {
        guard let path, let url = URL(string: path), url.scheme == "https",
              url.host == "image.tmdb.org", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/t/p/"), pixels.isFinite, pixels > 0 else { return nil }
        self.url = url
        self.pixels = pixels <= 256 ? 256 : pixels <= 512 ? 512 : pixels <= 1024 ? 1024 : 1536
    }
}

private final class ArtworkResidentCache: @unchecked Sendable {
    let values = NSCache<NSString, PublicArtworkBitmap>()
    init() { values.totalCostLimit = 64 * 1024 * 1024; values.countLimit = 256 }
}

actor PublicArtworkCache {
    static let shared = PublicArtworkCache()
    private nonisolated let resident = ArtworkResidentCache()
    private let session: URLSession
    private var pending: [PublicArtworkRequest: Task<PublicArtworkBitmap?, Never>] = [:]
    private var failedUntil: [PublicArtworkRequest: Date] = [:]
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.urlCache = URLCache(memoryCapacity: 12 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, directory: nil)
        config.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: config)
    }
    nonisolated func cached(_ request: PublicArtworkRequest) -> PublicArtworkBitmap? {
        resident.values.object(forKey: request.key as NSString)
    }
    func image(_ request: PublicArtworkRequest) async -> PublicArtworkBitmap? {
        guard !Task.isCancelled else { return nil }
        if let value = cached(request) { return value }
        if let active = pending[request] { return await active.value }
        if let retry = failedUntil[request], retry > .now { return nil }
        let session = session
        // Task inherits this decoding actor, never the UI actor. A recycled cell
        // cancels only its observation; shared work continues for other cells.
        let task = Task { () -> PublicArtworkBitmap? in
            do {
                let (data, response) = try await session.data(from: request.url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https", http.url?.host == "image.tmdb.org",
                      http.mimeType?.hasPrefix("image/") == true, data.count <= 12 * 1024 * 1024,
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: request.pixels,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return PublicArtworkBitmap(image)
            } catch { return nil }
        }
        pending[request] = task
        let result = await task.value
        pending.removeValue(forKey: request)
        if let result {
            resident.values.setObject(result, forKey: request.key as NSString,
                                      cost: result.image.bytesPerRow * result.image.height)
            failedUntil.removeValue(forKey: request)
        } else {
            failedUntil = failedUntil.filter { $0.value > .now }
            if failedUntil.count >= 128 { failedUntil.removeAll(keepingCapacity: true) }
            failedUntil[request] = .now.addingTimeInterval(30)
        }
        return result
    }
}
