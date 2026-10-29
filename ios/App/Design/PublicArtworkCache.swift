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
        guard let path, let url = URL(string: path), Self.publicArtwork(url), pixels.isFinite, pixels > 0 else { return nil }
        let bucket = pixels <= 256 ? 256 : pixels <= 512 ? 512 : pixels <= 1024 ? 1024 : 1536
        self.url = Self.sharper(url, pixels: bucket)
        self.pixels = bucket
    }
    /// Only public artwork hosts: TMDB images and AniList's character and cover images.
    static func publicArtwork(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        return (url.host == "image.tmdb.org" && url.path.hasPrefix("/t/p/")) || (url.host == "s4.anilist.co" && url.path.hasPrefix("/file/anilistcdn/"))
    }
    /// Large tiles and full-width backdrops ask TMDb for a bigger rendition than the saved
    /// w500/w780 URL (w780 up to 1024 px, w1280 above), so they are not upscaled. Never smaller.
    static func sharper(_ url: URL, pixels: Int) -> URL {
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[2].first == "w", let current = Int(parts[2].dropFirst()) else { return url }
        let wanted = pixels >= 1536 ? 1280 : pixels >= 1024 ? 780 : current
        guard wanted > current else { return url }
        return URL(string: "https://image.tmdb.org/t/p/w\(wanted)/" + parts[3]) ?? url
    }
}

private final class ArtworkResidentCache: @unchecked Sendable {
    let values = NSCache<NSString, PublicArtworkBitmap>()
    // Room for a few screens of decoded posters, so scrolling back never decodes them again.
    init() { values.totalCostLimit = 96 * 1024 * 1024; values.countLimit = 400 }
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
        // A larger disk copy keeps a big library's artwork across launches instead of downloading it again.
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, directory: nil)
        config.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: config)
    }
    /// Artwork reveals what the owner watches. Sign-out drops decoded bitmaps,
    /// in-flight transfers and the downloaded copies in the URL cache.
    func removeAll() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        failedUntil.removeAll()
        resident.values.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
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
                      let landed = http.url, PublicArtworkRequest.publicArtwork(landed),
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
