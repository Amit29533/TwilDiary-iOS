import Foundation

enum BackendEndpoint {
    static let production = URL(string: "https://twildiary-v2.amit29533.workers.dev")!

    static func isPrivateAPI(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == production.host && url.port == nil &&
        url.user == nil && url.password == nil && url.path.hasPrefix("/api/")
    }
}
