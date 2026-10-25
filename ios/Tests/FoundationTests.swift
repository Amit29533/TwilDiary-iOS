import XCTest
@testable import TwilDiary

final class FoundationTests: XCTestCase {
    func testT36GeneratedAppMetadataDeclaresOnlySystemProvidedEncryption() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
    }
    func testCredentialDestinationIsRestrictedToThePrivateHTTPSAPI() throws {
        XCTAssertTrue(BackendEndpoint.isPrivateAPI(try XCTUnwrap(URL(string: "https://twildiary-v2.amit29533.workers.dev/api/session"))))
        for value in [
            "http://twildiary-v2.amit29533.workers.dev/api/session",
            "https://example.test/api/session",
            "https://twildiary-v2.amit29533.workers.dev/preview/home",
            "https://twildiary-v2.amit29533.workers.dev:8443/api/session",
            "https://user:password@twildiary-v2.amit29533.workers.dev/api/session"
        ] {
            XCTAssertFalse(BackendEndpoint.isPrivateAPI(try XCTUnwrap(URL(string: value))))
        }
    }
}
