import XCTest

/// The app works without your server (owner's rule: the server is only for sign-in, backups and
/// extras, and only if you choose it). Every server call in the app is reviewed here as one of:
/// - optional: your server's own features, used only when you connect it;
/// - server diary: the old diary-on-your-server path, never reached with no server (phone mode
///   takes the phone or Trakt/MDBList/WeTrakr branch before it);
/// - phone first: TMDB, Trakt or AniList on the phone, the server only a fallback when you have one.
/// A new server call fails this test until it's reviewed, so a screen can't quietly depend on
/// the server again.
final class NoServerContractTests: XCTestCase {
    static let optional = ["/api/session", "/api/backups", "/api/phone-extras", "/api/usage", "/api/settings/apis", "/api/providers",
                           "/api/diary-record", "/api/trakt/connect", "/api/trakt/status", "/api/trakt/disconnect", "/api/trakt/token",
                           "/api/jellyfin/library", "/api/files/jellyfin"]
    static let serverDiary = ["/api/workspace", "/api/titles", "/api/watch-events", "/api/glance", "/api/progress/status", "/api/trash",
                              "/api/library/ratings", "/api/trakt/sync", "/api/favourites"]
    static let phoneFirst = ["/api/metadata", "/api/catalog", "/api/canvas", "/api/discovery", "/api/people", "/api/person", "/api/search",
                             "/api/stats", "/api/trakt/community"]

    func testEveryServerCallIsReviewed() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("The app's sources aren't on this machine.") }
        let pattern = try NSRegularExpression(pattern: #""(/api/[A-Za-z0-9_/-]*)"#)
        let reviewed = Self.optional + Self.serverDiary + Self.phoneFirst
        var unreviewed: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let found = Range(match.range(at: 1), in: line) else { continue }
                    let path = String(line[found])
                    if path == "/api/" || reviewed.contains(where: { path.hasPrefix($0) }) { continue }
                    unreviewed.append("\(file.lastPathComponent):\(index + 1) \(path)")
                }
            }
        }
        XCTAssertEqual(unreviewed, [], "Server calls not reviewed for working without a server. Give each a phone path, or list it above.")
    }
}
