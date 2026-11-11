import Foundation

/// Saves the phone's copies (a service library, the TMDB catalog) away from the main thread: the
/// value is encoded and written in the background, a moment later, and a newer save of the same
/// file replaces one still waiting, so a run of edits writes once. Nothing on screen waits for it.
@MainActor enum BackgroundFiles {
    private static var tickets: [URL: Int] = [:]

    static func save<Value: Encodable & Sendable>(_ value: Value, to url: URL, protected: Bool = false, excludeFolderFromBackup: Bool = false) {
        let ticket = (tickets[url] ?? 0) + 1
        tickets[url] = ticket
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard await current(url, ticket) else { return }
            do {
                let folder = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: protected ? [.atomic, .completeFileProtection] : [.atomic])
                if excludeFolderFromBackup {
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    var target = folder; try target.setResourceValues(values)
                }
            } catch {
                // The copy on screen stays; the next save writes it again.
            }
        }
    }
    /// Drops a save still waiting (sign-out deletes the file; it mustn't come back).
    static func cancel(_ url: URL) { tickets[url] = (tickets[url] ?? 0) + 1 }
    /// Cancels every waiting save under a folder.
    static func cancel(folder: URL) {
        for url in tickets.keys where url.path.hasPrefix(folder.path) { cancel(url) }
    }
    private static func current(_ url: URL, _ ticket: Int) -> Bool { tickets[url] == ticket }
}
