import XCTest
@testable import TwilDiary

/// Your server refuses a change that doesn't name its origin. A delete has no body and went
/// without one: Delete backup answered HTTP 403 (owner's recording, 2026-11-15).
final class PhoneServerWriteTests: XCTestCase {
    func testEveryChangeNamesItsOriginAndReadsDont() {
        for method in ["DELETE", "POST", "PUT", "PATCH", "delete"] { XCTAssertTrue(PhoneServerSync.isWrite(method), method) }
        for method in ["GET", "HEAD", "OPTIONS"] { XCTAssertFalse(PhoneServerSync.isWrite(method), method) }
    }
}
