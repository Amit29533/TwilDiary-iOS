import Foundation
import TwilDiaryCore

/// What "Make … match the diary" last sent each service and what it answered, kept on the
/// phone (no keys or tokens: those travel in headers, which aren't kept) so you can copy it
/// and see exactly why something didn't land.
@MainActor enum SyncReport {
    private static func key(_ provider: SyncProviderKind) -> String { "syncReport." + provider.rawValue }
    /// The newest writes, newest first (bodies and replies shortened).
    static func record(_ provider: SyncProviderKind, path: String, body: Data, reply: Data) {
        func short(_ data: Data, _ limit: Int) -> String {
            let text = String(decoding: data, as: UTF8.self)
            return text.count > limit ? String(text.prefix(limit)) + "… (\(text.count) characters)" : text
        }
        let entry = "\(Date.now.formatted(.iso8601)) POST \(path)\nSent: \(short(body, 6_000))\nReply: \(short(reply, 6_000))"
        var entries = UserDefaults.standard.stringArray(forKey: key(provider)) ?? []
        entries.insert(entry, at: 0)
        UserDefaults.standard.set(Array(entries.prefix(6)), forKey: key(provider))
    }
    static func text(_ provider: SyncProviderKind) -> String? {
        let entries = UserDefaults.standard.stringArray(forKey: key(provider)) ?? []
        return entries.isEmpty ? nil : entries.joined(separator: "\n\n———\n\n")
    }
}
