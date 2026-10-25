import XCTest
import CoreGraphics
@testable import TwilDiary

final class GlassArtworkTests: XCTestCase {
    func testOnlyPublicTMDBArtworkCanBeFetchedAndUsesABoundedThumbnailSize() {
        XCTAssertEqual(GlassArtworkCache.publicArtworkURL("https://image.tmdb.org/t/p/original/example.jpg")?.absoluteString, "https://image.tmdb.org/t/p/w342/example.jpg")
        for path in ["http://image.tmdb.org/t/p/w500/example.jpg", "https://example.test/t/p/w500/example.jpg", "https://user:secret@image.tmdb.org/t/p/w500/example.jpg", "https://image.tmdb.org:8443/t/p/w500/example.jpg", "https://image.tmdb.org/t/p/w500/example.jpg?token=secret", "https://image.tmdb.org/t/p/w500/../../example.jpg", "https://image.tmdb.org/t/p/w500/example.svg"] {
            XCTAssertNil(GlassArtworkCache.publicArtworkURL(path))
        }
    }
    func testDominantSamplingUsesTheMostFrequentColorAndIgnoresLetterboxAndTransparency() {
        let green: [UInt8] = [32, 160, 80, 255], red: [UInt8] = [210, 20, 50, 255]
        var bytes: [UInt8] = []
        for _ in 0..<8 { bytes.append(contentsOf: green) }
        for _ in 0..<3 { bytes.append(contentsOf: red) }
        for _ in 0..<20 { bytes.append(contentsOf: [0, 0, 0, 255]) }
        for _ in 0..<20 { bytes.append(contentsOf: [255, 255, 255, 0]) }
        let value = GlassArtworkCache.dominant(bytes)
        XCTAssertEqual(value.0, 32.0 / 255, accuracy: 0.001)
        XCTAssertEqual(value.1, 160.0 / 255, accuracy: 0.001)
        XCTAssertEqual(value.2, 80.0 / 255, accuracy: 0.001)
    }
    func testEmptyAndPartialSamplesHaveADeterministicReadableFallback() {
        let empty = GlassArtworkCache.dominant([]), partial = GlassArtworkCache.dominant([255, 0, 0])
        XCTAssertEqual(empty.0, 0.12); XCTAssertEqual(empty.1, 0.14); XCTAssertEqual(empty.2, 0.18)
        XCTAssertEqual(partial.0, empty.0); XCTAssertEqual(partial.1, empty.1); XCTAssertEqual(partial.2, empty.2)
    }
    func testDominantSamplingTieBreakIsIndependentOfPixelOrder() {
        let a: [UInt8] = [32, 80, 160, 255], b: [UInt8] = [180, 64, 32, 255]
        let first = GlassArtworkCache.dominant(a + b), second = GlassArtworkCache.dominant(b + a)
        XCTAssertEqual(first.0, second.0); XCTAssertEqual(first.1, second.1); XCTAssertEqual(first.2, second.2)
    }
    func testCachedBackdropIsPreblurredWithoutChangingItsExtent() async throws {
        let result = await Task.detached { () -> GlassArtworkBitmap? in
            guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
            guard let image = context.makeImage() else { return nil }
            return GlassArtworkCache.bitmap(image)
        }.value
        let bitmap = try XCTUnwrap(result)
        XCTAssertEqual(bitmap.image.width, 32); XCTAssertEqual(bitmap.image.height, 32)
        let middle = try XCTUnwrap(bitmap.image.cropping(to: CGRect(x: 15, y: 16, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(middle, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        XCTAssertTrue(rendered)
        XCTAssertGreaterThan(bytes[0], 30); XCTAssertGreaterThan(bytes[2], 30)
        XCTAssertGreaterThan(bytes[3], 240, "Clamping must keep the backdrop edges opaque")
    }

}
