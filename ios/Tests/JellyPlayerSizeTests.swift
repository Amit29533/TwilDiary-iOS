import XCTest
@testable import TwilDiary

/// The player view's own size. SwiftUI copies a view as it draws it (into closures and the frames
/// of each part of its body); a view of several kilobytes ran an iPhone's 1 MB main-thread stack out
/// on opening a video. Its larger values live in a shared store, and this keeps it that way.
@MainActor final class JellyPlayerSizeTests: XCTestCase {
    func testThePlayerViewStaysSmall() {
        let size = MemoryLayout<JellyPlayerView>.size
        print("JELLY-QA-SIZE JellyPlayerView \(size) bytes")
        XCTAssertLessThan(size, 6 * 1024, "JellyPlayerView is \(size) bytes: move large values into JellyPlayerStore")
    }
}
