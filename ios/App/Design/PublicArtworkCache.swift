import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

/// Public, immutable bitmaps only. Private diary responses and credentials never
/// enter this cache. NSCache supports concurrent lookups from rendering/decoding.
final class PublicArtworkBitmap: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image; super.init() }
}

struct PublicArtworkRequest: Hashable, Sendable {
    let url: URL
    let pixels: Int
    let fallbackURL: URL?
    var key: String { url.absoluteString + "#" + String(pixels) }
    /// `pixels`: the longest side on screen (what the bitmap is decoded to). `width`: the width on
    /// screen, which picks TMDB's rendition (its sizes are widths: "w500" is 500 px wide). Going by
    /// the longest side, a 3-across poster (taller than wide) fetched and decoded w780 for a ~350 px
    /// wide cell.
    init?(path: String?, pixels: Double, width: Double? = nil, prefersOriginal: Bool = false) {
        guard let path, let url = URL(string: path), Self.publicArtwork(url), pixels.isFinite, pixels > 0 else { return nil }
        func bucketed(_ value: Double) -> Int { value <= 256 ? 256 : value <= 512 ? 512 : value <= 1024 ? 1024 : 1536 }
        let bucket = bucketed(pixels)
        let across = width.flatMap { $0.isFinite && $0 > 0 ? bucketed($0) : nil } ?? bucket
        let requested = prefersOriginal ? Self.originalPortrait(url) : Self.sharper(url, pixels: across)
        self.url = requested
        self.pixels = bucket
        self.fallbackURL = prefersOriginal && requested != url ? url : nil
    }
    /// Original is a supported TMDB rendition for profiles of any aspect ratio.
    /// AniList already supplies its largest public image URL; do not invent a larger one.
    private static func originalPortrait(_ url: URL) -> URL {
        let parts = url.path.split(separator: "/")
        guard url.host == "image.tmdb.org", parts.count == 4 else { return url }
        return URL(string: "https://image.tmdb.org/t/p/original/" + parts[3]) ?? url
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
        // Downloads are kept as the app's own files (`folder`, pruned to a size), so the URL cache
        // no longer keeps a second copy of each on disk.
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0, directory: nil)
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
        try? FileManager.default.removeItem(at: Self.folder)
    }
    /// Downloaded artwork kept as files (public TMDB and AniList images only), so opening the app
    /// shows posters and Home's hero at once instead of downloading them again.
    nonisolated static let folder = URL.cachesDirectory.appending(path: "Artwork", directoryHint: .isDirectory)
    /// The kept files stay under `limit` (300 MB): anything unused for 60 days goes, then the least
    /// recently used (a file's date moves each time it's shown again). Run once a launch, in the
    /// background, as Cinopsys prunes its own caches.
    nonisolated static func prune(limit: Int = 300 * 1024 * 1024, unusedFor: TimeInterval = 60 * 86_400) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let urls = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date.now.addingTimeInterval(-unusedFor)
        var kept: [(url: URL, used: Date, size: Int)] = [], total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let used = values.contentModificationDate ?? .distantPast, size = values.totalFileAllocatedSize ?? 0
            if used < cutoff { try? manager.removeItem(at: url) } else { kept.append((url, used, size)); total += size }
        }
        guard total > limit else { return }
        for file in kept.sorted(by: { $0.used < $1.used }) {
            guard total > limit * 8 / 10 else { break }
            try? manager.removeItem(at: file.url); total -= file.size
        }
    }
    nonisolated static func file(_ url: URL) -> URL {
        folder.appending(path: SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    nonisolated static func decode(_ data: Data, pixels: Int) -> PublicArtworkBitmap? {
        guard data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return PublicArtworkBitmap(image)
    }
    nonisolated func cached(_ request: PublicArtworkRequest) -> PublicArtworkBitmap? {
        resident.values.object(forKey: request.key as NSString)
    }
    /// `retrying`: asked again after a failure (the short wait after a failure is skipped).
    func image(_ request: PublicArtworkRequest, retrying: Bool = false) async -> PublicArtworkBitmap? {
        guard !Task.isCancelled else { return nil }
        if let value = cached(request) { return value }
        if let active = pending[request] { return await active.value }
        if !retrying, let retry = failedUntil[request], retry > .now { return nil }
        let session = session
        // Detached: the file read, download and decode run side by side for every poster on
        // screen, never on the UI actor and not one at a time on this actor (a Task would inherit
        // it, and a screen of Canvas list cards then filled in one poster after another). A
        // recycled cell cancels only its observation; shared work continues for other cells.
        let task = Task.detached(priority: .userInitiated) { () -> PublicArtworkBitmap? in
            // A missing/oversized original must not leave a profile without its
            // existing resized image. Both attempts use the same public-host checks.
            for url in request.fallbackURL.map({ [request.url, $0] }) ?? [request.url] {
              guard !Task.isCancelled else { return nil }
              // Kept from before: decoded from the file, no download.
              let saved = Self.file(url)
              if let data = try? Data(contentsOf: saved), let bitmap = Self.decode(data, pixels: request.pixels) {
                  // Shown again: it counts as recently used when the folder is pruned.
                  try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: saved.path)
                  return bitmap
              }
              do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let landed = http.url, PublicArtworkRequest.publicArtwork(landed),
                      http.mimeType?.hasPrefix("image/") == true, data.count <= 12 * 1024 * 1024,
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: request.pixels,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { continue }
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? data.write(to: Self.file(url), options: .atomic)
                return PublicArtworkBitmap(image)
              } catch { continue }
            }
            return nil
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
