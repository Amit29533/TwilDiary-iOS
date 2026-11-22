import Foundation
import Observation
import TwilDiaryCore

/// Cloudflare account usage against the Workers Free plan, one entry per UTC day.
struct CloudflareUsage: Decodable, Sendable {
    struct Day: Decodable, Identifiable, Sendable {
        let date: String
        let requests: Int
        let errors: Int
        let rowsRead: Int
        let rowsWritten: Int
        let storageBytes: Int?
        var id: String { date }
        /// Midnight UTC of the day, for chart axes.
        var start: Date { (try? Date.ISO8601FormatStyle().parse(date + "T00:00:00Z")) ?? .distantPast }
    }
    struct Limits: Decodable, Sendable { let requests: Int; let rowsRead: Int; let rowsWritten: Int; let storageBytes: Int }
    let configured: Bool
    let range: Int
    let days: [Day]
    let limits: Limits
    let resetsAt: String
    let fetchedAt: String
    let unavailable: [String]
    /// The UTC day key the server uses, such as 2026-10-29.
    static func day(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle().year().month().day()) }
    var today: Day? { days.last }
    /// The latest known size; storage is reported once a day, so today may not have one yet.
    var storageBytes: Int? { days.last { $0.storageBytes != nil }?.storageBytes }
    var resetDate: Date? { DiaryDate.parse(resetsAt) }
}

@MainActor @Observable final class CloudflareUsageLoader {
    private let store: DiaryStore
    private var generation = UUID()
    private(set) var usage: CloudflareUsage?
    private(set) var loading = false
    private(set) var error: String?
    init(store: DiaryStore) { self.store = store }
    func load(range: Int) async {
        let request = UUID(); generation = request
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let next: CloudflareUsage
            #if DEBUG
            if store.isPreview { next = PreviewCatalog.cloudflareUsage(range: range) } else { next = try await store.read("/api/usage?days=\(range)") }
            #else
            next = try await store.read("/api/usage?days=\(range)")
            #endif
            guard generation == request, !Task.isCancelled else { return }
            usage = next
        } catch is CancellationError { }
        catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
