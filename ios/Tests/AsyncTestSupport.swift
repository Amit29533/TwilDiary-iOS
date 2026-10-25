import Foundation

/// Fail prerequisites locally instead of letting an unbounded polling loop consume CI.
@MainActor func waitForRegressionCondition(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(3))
    while !condition() {
        guard clock.now < deadline, !Task.isCancelled else { return false }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
    }
    return true
}
