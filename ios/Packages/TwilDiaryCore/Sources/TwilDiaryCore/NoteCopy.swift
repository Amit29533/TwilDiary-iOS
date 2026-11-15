import Foundation

/// Notes kept on one service copied to another (Simkl's memos to Trakt's notes). A title's note
/// goes only where the other service has none, so nothing written there is ever replaced.
public struct NoteCopyPlan: Equatable, Sendable {
    /// The notes to send, in the order they were read.
    public var send: [TraktNote] = []
    /// Titles whose note is there already (the same text, or its first `limit` characters).
    public var alreadyThere = 0
    /// Titles with a different note there, left as they are (their names).
    public var keptThere: [String] = []
    /// Notes longer than the other service keeps (their full text stays on the phone).
    public var cut = 0
    public init() {}

    /// `limit`: the characters a note keeps on the other service (Trakt: 500).
    public static func make(from source: [TraktNote], to target: [TraktNote], limit: Int = 500) -> NoteCopyPlan {
        var there: [String: String] = [:]
        for note in target {
            if let key = note.title?.diaryKey { there[key] = note.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var plan = NoteCopyPlan(), seen = Set<String>()
        for note in source {
            guard let title = note.title, let key = title.diaryKey, seen.insert(key).inserted else { continue }
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let existing = there[key], !existing.isEmpty {
                if existing == text || existing == String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) { plan.alreadyThere += 1 }
                else { plan.keptThere.append(title.name) }
                continue
            }
            plan.send.append(TraktNote(id: note.id, title: title, text: text, updatedAt: note.updatedAt))
            if text.count > limit { plan.cut += 1 }
        }
        return plan
    }
}
