import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Tapping Force Match (or Make … match) starts a continued processing task first. Before the
/// fix, the app registered only the "<bundle id>.match.*" pattern and then submitted a concrete
/// "<bundle id>.match.<uuid>", which BGTaskScheduler rejects with an assertion failure
/// (`_handleSubmissionWithoutRegistrationForTaskRequest`) that ends the app at once.
@MainActor final class MatchInBackgroundTests: XCTestCase {
    func testStartingMatchesRegistersEachBeforeSubmitting() async throws {
        let matches = MatchInBackground.shared
        for run in 1...2 {
            matches.begin("Force Match · MDBList \(run)", provider: .mdblist)
            for step in 0..<4 {
                try await Task.sleep(for: .milliseconds(250))
                matches.count(step, of: 4)
                matches.update("Changing \(step + 1) of 4")
            }
            XCTAssertFalse(matches.expired)
            matches.end("Done", success: true)
        }
    }
}
