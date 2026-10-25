import SwiftUI
import ImageIO
import CoreImage
import UIKit
import TwilDiaryCore

/// CGImage is immutable. Only its immutable bitmap crosses the decoding actor;
/// UIImage and every SwiftUI state update stay on the main actor.
struct GlassArtworkBitmap: @unchecked Sendable {
    let image: CGImage
    let red: Double
    let green: Double
    let blue: Double
}

actor GlassArtworkCache {
    static let shared = GlassArtworkCache()
    private var images: [String: GlassArtworkBitmap] = [:]
    private var order: [String] = []
    private var pending: [String: Task<GlassArtworkBitmap?, Never>] = [:]
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0, directory: nil)
        session = URLSession(configuration: configuration)
    }
    func image(_ path: String) async -> GlassArtworkBitmap? {
        guard let url = Self.publicArtworkURL(path) else { return nil }
        let key = url.absoluteString
        if let saved = images[key] { return saved }
        if let active = pending[key] { return await active.value }
        let session = session
        let task = Task { () -> GlassArtworkBitmap? in
            do {
                let (data, response) = try await session.data(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.host == "image.tmdb.org", data.count <= 2_000_000,
                      response.mimeType?.hasPrefix("image/") == true,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 128,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return Self.bitmap(image)
            } catch { return nil }
        }
        pending[key] = task
        let result = await task.value
        pending.removeValue(forKey: key)
        if let result { save(result, key: key) }
        return result
    }
    func local(_ bitmap: GlassArtworkBitmap, key: String) -> GlassArtworkBitmap? {
        if let saved = images[key] { return saved }
        let ratio = min(1, 128.0 / Double(max(bitmap.image.width, bitmap.image.height)))
        let width = max(1, Int(Double(bitmap.image.width) * ratio)), height = max(1, Int(Double(bitmap.image.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let thumbnail = context.makeImage(), let result = Self.bitmap(thumbnail) else { return nil }
        save(result, key: key)
        return result
    }
    private func save(_ bitmap: GlassArtworkBitmap, key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = bitmap
        while order.count > 12 { images.removeValue(forKey: order.removeFirst()) }
    }
    nonisolated static func publicArtworkURL(_ path: String) -> URL? {
        guard var components = URLComponents(string: path), components.scheme == "https", components.host == "image.tmdb.org",
              components.user == nil, components.password == nil, components.port == nil, components.query == nil, components.fragment == nil,
              components.path.range(of: #"^/t/p/(?:w\d+|original)/[a-zA-Z0-9_-]{1,180}\.(?:jpg|png|webp)$"#, options: .regularExpression) != nil else { return nil }
        components.path = "/t/p/w342/" + (components.path.split(separator: "/").last.map(String.init) ?? "")
        return components.url
    }
    nonisolated static func bitmap(_ image: CGImage) -> GlassArtworkBitmap? {
        // Sample a tiny explicitly RGBA buffer; never process full poster pixels
        // in a scroll callback or on the UI actor.
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard drawn else { return nil }
        let color = dominant(bytes)
        // The tiny backdrop is blurred once before caching, off the UI actor.
        // Scrolling then composites a bitmap instead of filtering a full screen.
        let source = CIImage(cgImage: image)
        let output = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 6.0])
        let context = CIContext(options: [.cacheIntermediates: false])
        let blurred = context.createCGImage(output, from: source.extent) ?? image
        return GlassArtworkBitmap(image: blurred, red: color.0, green: color.1, blue: color.2)
    }
    nonisolated static func dominant(_ bytes: [UInt8]) -> (Double, Double, Double) {
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for offset in stride(from: 0, to: bytes.count - bytes.count % 4, by: 4) {
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            guard bytes[offset + 3] > 200, max(r, max(g, b)) > 24, min(r, min(g, b)) < 240 else { continue }
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let old = bins[key] ?? (count: 0, r: 0, g: 0, b: 0)
            bins[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        guard let best = bins.sorted(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }).first?.value else { return (0.12, 0.14, 0.18) }
        return (Double(best.r) / Double(best.count * 255), Double(best.g) / Double(best.count * 255), Double(best.b) / Double(best.count * 255))
    }
}

struct DiaryScreenBackground: View {
    var path: String? = nil
    var name = ""
    var forceGlass = false
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var bitmap: GlassArtworkBitmap?
    private var candidate: MediaTitle? { store.workspace.activeTitles.first { $0.status == "watching" && ($0.backdrop != nil || $0.poster != nil) } ?? store.workspace.activeTitles.first }
    // An explicitly named title without artwork must not borrow another show's
    // background. Library fallback is reserved for the general app surfaces.
    private var artwork: String? { path ?? (name.isEmpty ? candidate?.backdrop ?? candidate?.poster : nil) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if (theme == .glass || forceGlass) && !reduceTransparency, let bitmap {
                    Color(red: bitmap.red, green: bitmap.green, blue: bitmap.blue).opacity(0.5)
                    Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .opacity(0.44)
                    LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            .task(id: BackgroundKey(path: artwork, glass: theme == .glass || forceGlass, reduced: reduceTransparency)) {
                bitmap = nil
                guard (theme == .glass || forceGlass), !reduceTransparency, let artwork else { return }
                let result: GlassArtworkBitmap?
                if let local = localArtwork(artwork) {
                    result = await GlassArtworkCache.shared.local(GlassArtworkBitmap(image: local, red: 0, green: 0, blue: 0), key: artwork)
                } else { result = await GlassArtworkCache.shared.image(artwork) }
                guard !Task.isCancelled else { return }
                bitmap = result
            }
    }
    private struct BackgroundKey: Equatable { let path: String?; let glass: Bool; let reduced: Bool }
    private func localArtwork(_ path: String) -> CGImage? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), GlassArtworkCache.publicArtworkURL(path) != nil {
            return DemoArtwork.image("/demo/frieren-hero-v2.jpg")?.cgImage
        }
        #endif
        return DemoArtwork.image(path)?.cgImage
    }
}

extension View {
    func diaryScreenBackground(path: String? = nil, name: String = "") -> some View { background { DiaryScreenBackground(path: path, name: name) } }
}
