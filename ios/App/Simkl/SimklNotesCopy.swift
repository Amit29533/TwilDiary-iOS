import SwiftUI
import TwilDiaryCore

/// "Copy notes to Trakt": Simkl's memos (one per title) become private notes on Trakt, only for
/// titles with no note on Trakt yet, one a second. Nothing changes on Simkl. Trakt keeps 500
/// characters; a longer memo's full text stays on this iPhone with the title.
@MainActor @Observable final class SimklNotesCopy {
    static let shared = SimklNotesCopy()
    private(set) var running = false
    private(set) var progress: String?
    private(set) var result: String?

    /// What would go now, from the last read of each.
    var plan: NoteCopyPlan {
        NoteCopyPlan.make(from: TrackerPreviewStore.shared.libraries[.simkl]?.notes ?? [], to: TraktDirectStore.shared.library?.notes ?? [])
    }
    /// Notes read from Simkl so far; nil before Simkl has been read.
    var onSimkl: Int? { TrackerPreviewStore.shared.libraries[.simkl]?.notes.count }

    func run(store: DiaryStore) async {
        guard !running else { return }
        let trakt = TraktDirectStore.shared, others = TrackerPreviewStore.shared
        guard store.traktSignedInOnPhone, !trakt.localOnly else { result = "Sign in to Trakt first, in Connections."; return }
        running = true; result = nil
        defer { running = false; progress = nil }

        // Both read afresh, so a note added on either side since is counted.
        progress = "Reading your Simkl notes…"
        var waited = 0
        while others.running != nil, waited < 200 { try? await Task.sleep(for: .milliseconds(300)); waited += 1 }
        await others.check(.simkl, store: store)
        if let failure = others.errors[.simkl] { result = failure; return }
        guard others.libraries[.simkl] != nil else { result = "Simkl couldn’t be read just now. Try again in a moment."; return }
        progress = "Reading your Trakt notes…"
        waited = 0
        while trakt.running, waited < 200 { try? await Task.sleep(for: .milliseconds(300)); waited += 1 }
        await trakt.check(store: store)
        if let failure = trakt.error { result = "Trakt couldn’t be read: " + failure; return }

        let plan = self.plan
        guard !plan.send.isEmpty else { result = Self.summary(plan, sent: 0, notSent: [], overLimit: 0, limit: nil); return }
        // Trakt's notes allowance (the free plan has one): what doesn't fit isn't tried.
        var room = plan.send.count, limit: Int?
        if let cap = (try? await trakt.accountLimits(store: store))?.first(where: { $0.group == "notes" && $0.name == "item_count" }) {
            limit = cap.value
            room = min(room, max(0, cap.value - (trakt.library?.notes.count ?? 0)))
        }
        let sending = Array(plan.send.prefix(room))
        var sent = 0, notSent: [String] = [], overLimit = plan.send.count - sending.count
        for (index, note) in sending.enumerated() {
            guard let title = note.title else { continue }
            progress = "Copying \(index + 1) of \(sending.count)…"
            do {
                // Sends now, or keeps it waiting on the phone when Trakt can't be reached (it goes later).
                try await trakt.setNote(note.text, for: title, store: store)
                sent += 1
                if note.text.count > 500, let diaryTitle = store.diaryToMatch.activeTitles.first(where: { PhoneExtras.key($0) == title.diaryKey }) {
                    PhoneExtras.shared.update(diaryTitle, ["notes": note.text])
                }
            } catch let error as TraktWriteError where error.status == 420 {
                overLimit += sending.count - index
                break
            } catch {
                notSent.append(title.name + ": " + error.localizedDescription)
            }
        }
        result = Self.summary(plan, sent: sent, notSent: notSent, overLimit: overLimit, limit: limit)
    }

    static func summary(_ plan: NoteCopyPlan, sent: Int, notSent: [String], overLimit: Int, limit: Int?) -> String {
        func notes(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "note" : "notes")" }
        var lines: [String] = []
        if sent > 0 { lines.append("Copied \(notes(sent)) to Trakt.") }
        else if plan.send.isEmpty && plan.alreadyThere == 0 && plan.keptThere.isEmpty { lines.append("No notes found on Simkl.") }
        else if plan.send.isEmpty { lines.append("Nothing to copy: Trakt has a note for every title.") }
        if plan.alreadyThere > 0 { lines.append("\(notes(plan.alreadyThere).capitalizedFirst) \(plan.alreadyThere == 1 ? "was" : "were") on Trakt already.") }
        if !plan.keptThere.isEmpty {
            let names = plan.keptThere.prefix(3).joined(separator: ", ") + (plan.keptThere.count > 3 ? " and \(plan.keptThere.count - 3) more" : "")
            lines.append("Left as they are, with a different note on Trakt: \(names).")
        }
        if sent > 0, plan.cut > 0 { lines.append("Trakt keeps 500 characters, so \(notes(plan.cut)) \(plan.cut == 1 ? "was" : "were") shortened there; the full text stays on this iPhone.") }
        if overLimit > 0 {
            lines.append("\(notes(overLimit).capitalizedFirst) didn’t fit in Trakt’s notes allowance" + (limit.map { " (\($0.formatted()))" } ?? "") + ". Trakt VIP raises it.")
        }
        if !notSent.isEmpty { lines.append("Not copied: " + notSent.prefix(3).joined(separator: "; ") + (notSent.count > 3 ? " and \(notSent.count - 3) more." : ".")) }
        return lines.joined(separator: " ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
