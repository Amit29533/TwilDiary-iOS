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

/// A queued edit a service refused for good (or that kept failing): taken off the queue so the
/// rest go on, and kept here with the reason, as Cinopsys shows its dead letters.
struct OutboxDeadLetter: LocalizedError { let reason: String; var errorDescription: String? { reason } }
@MainActor enum DeadLetters {
    private static func key(_ provider: SyncProviderKind) -> String { "deadLetters." + provider.rawValue }
    static func add(_ provider: SyncProviderKind, title: String, reason: String) {
        var list = UserDefaults.standard.stringArray(forKey: key(provider)) ?? []
        list.insert(Date.now.formatted(date: .abbreviated, time: .shortened) + " · " + title + ": " + reason, at: 0)
        UserDefaults.standard.set(Array(list.prefix(50)), forKey: key(provider))
    }
    static func list(_ provider: SyncProviderKind) -> [String] { UserDefaults.standard.stringArray(forKey: key(provider)) ?? [] }
    static func clear(_ provider: SyncProviderKind) { UserDefaults.standard.removeObject(forKey: key(provider)) }
}

/// Cinopsys's seed ledger: what "Make … match the diary" sent that the service then didn't keep
/// (it answered, but the next read still lacks it: an anime episode it numbers its own way, a
/// title it files elsewhere). Those aren't sent again on every match, nor listed as differences;
/// they're shown apart, and "Try them again" sends them once more.
@MainActor enum MatchLedger {
    private static func key(_ tracker: MainTracker) -> String { "matchLedger." + tracker.rawValue }
    static func tokens(_ tracker: MainTracker) -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key(tracker)) ?? []) }
    static func add(_ tracker: MainTracker, _ tokens: Set<String>) {
        guard !tokens.isEmpty else { return }
        UserDefaults.standard.set(Array(Self.tokens(tracker).union(tokens)).sorted(), forKey: key(tracker))
    }
    static func clear(_ tracker: MainTracker) { UserDefaults.standard.removeObject(forKey: key(tracker)) }
}
