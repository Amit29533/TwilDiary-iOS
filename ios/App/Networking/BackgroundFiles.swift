import Foundation
import os

/// Saves the phone's copies (a service library, the TMDB catalog) away from the main thread: the
/// value is encoded and written in the background, a moment later, and a newer save of the same
/// file replaces one still waiting, so a run of edits writes once. Nothing on screen waits for it.
@MainActor enum BackgroundFiles {
    private static var writers: [URL: OSAllocatedUnfairLock<Int>] = [:]

    static func save<Value: Encodable & Sendable>(_ value: Value, to url: URL, protected: Bool = false, excludeFolderFromBackup: Bool = false) {
        let writer = writer(for: url)
        let ticket = writer.withLock { revision in
            revision += 1
            return revision
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard writer.withLock({ $0 == ticket }) else { return }
            do {
                // Written beside the file first, outside the lock; only the swap into place happens
                // under it (a save from the main thread no longer waits for a disk write here).
                let data = try JSONEncoder().encode(value)
                let staged = try stage(data, for: url, protected: protected)
                do {
                    try writer.withLock { revision in
                        guard revision == ticket else { try? FileManager.default.removeItem(at: staged); return }
                        try commit(staged, to: url, excludeFolderFromBackup: excludeFolderFromBackup)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    throw error
                }
            } catch {
                // The copy on screen stays; the next save writes it again.
            }
        }
    }
    /// Commits a deletion before reporting success and prevents older saves replacing it.
    static func saveImmediately<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try writer(for: url).withLock { revision in
            try write(data, to: url)
            revision += 1
        }
    }
    private static func writer(for url: URL) -> OSAllocatedUnfairLock<Int> {
        if let writer = writers[url] { return writer }
        let writer = OSAllocatedUnfairLock(initialState: 0)
        writers[url] = writer
        return writer
    }
    /// The new contents in a hidden file beside the target, ready to be swapped in.
    private nonisolated static func stage(_ data: Data, for url: URL, protected: Bool) throws -> URL {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appending(path: "." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        try data.write(to: staged, options: protected ? [.completeFileProtection] : [])
        return staged
    }
    /// The staged file takes the target's place in one step.
    private nonisolated static func commit(_ staged: URL, to url: URL, excludeFolderFromBackup: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: url) }
        if excludeFolderFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url.deletingLastPathComponent()
            try target.setResourceValues(values)
        }
    }
    private nonisolated static func write(_ data: Data, to url: URL, protected: Bool = false, excludeFolderFromBackup: Bool = false) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: protected ? [.atomic, .completeFileProtection] : [.atomic])
        if excludeFolderFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = folder
            try target.setResourceValues(values)
        }
    }
    /// Drops a save still waiting (sign-out deletes the file; it mustn't come back).
    static func cancel(_ url: URL) {
        if let writer = writers[url] { writer.withLock { $0 += 1 } }
    }
    /// Cancels every waiting save under a folder.
    static func cancel(folder: URL) {
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        for url in writers.keys where url.path.hasPrefix(prefix) { cancel(url) }
    }
}
