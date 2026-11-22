import Foundation

public extension OptimisticMutation {
    /// Only confirmed server receipts may advance the expected version of dependent edits.
    func rebased(titleVersion: Int?, eventID: String? = nil, replacing localID: String? = nil, eventVersion: Int? = nil) -> Self {
        switch self {
        case .patchTitle(let id, let version, let status, let score, let clear, let favorite, let queued, let notes, let tags):
            return .patchTitle(titleId: id, expectedVersion: titleVersion ?? version, status: status, score: score, clearScore: clear, favorite: favorite, queued: queued, notes: notes, tags: tags)
        case .trashTitle(let id, let version, let date):
            return .trashTitle(titleId: id, expectedVersion: titleVersion ?? version, deletedAt: date)
        case .restoreTitle(let id, let version):
            return .restoreTitle(titleId: id, expectedVersion: titleVersion ?? version)
        case .revokeWatch(let id, let title, let version, let date):
            return .revokeWatch(eventId: id == localID ? eventID ?? id : id, titleId: title, expectedVersion: id == localID ? eventVersion ?? version : version, revokedAt: date)
        case .restoreWatch(let id, let title, let version):
            return .restoreWatch(eventId: id == localID ? eventID ?? id : id, titleId: title, expectedVersion: id == localID ? eventVersion ?? version : version)
        case .markWatch: return self
        }
    }

    /// Recognizes a retry whose first response was lost without overwriting unrelated remote edits.
    func isSatisfied(in workspace: Workspace) -> Bool {
        guard let title = workspace.titles.first(where: { $0.id == titleId }) else { return false }
        switch self {
        case .patchTitle(_, _, let status, let score, let clear, let favorite, let queued, let notes, let tags):
            return (status == nil || title.status == status) &&
                (score == nil || title.score == score) && (!clear || title.score == nil) &&
                (favorite == nil || title.favorite == favorite) && (queued == nil || title.queued == queued) &&
                (notes == nil || title.notes == notes) && (tags == nil || (title.tags ?? []) == tags)
        case .trashTitle: return title.deletedAt != nil
        case .restoreTitle: return title.deletedAt == nil
        case .revokeWatch(let id, _, _, _): return workspace.events.contains { $0.id == id && $0.revokedAt != nil }
        case .restoreWatch(let id, _, _): return workspace.events.contains { $0.id == id && $0.revokedAt == nil }
        case .markWatch(let operation, _, _, _, _, _): return workspace.events.contains { $0.operationId == operation }
        }
    }
}

public extension SyncOutboxQueue {
    /// Replace the queue atomically after persisting it in the app; never drop a pending edit first.
    func confirming(_ entry: SyncOutboxEntry, titleVersion: Int, event: WatchEvent?) -> Self {
        var copy = self
        copy.acknowledge(entryID: entry.id, provider: .cloudflare)
        let localID: String? = switch entry.mutation {
        case .markWatch(let op, _, _, _, _, _): "local-\(op)"
        case .revokeWatch(let id, _, _, _), .restoreWatch(let id, _, _): id
        default: nil
        }
        // Rebase only the next title-version-bearing edit. Later edits depend on its receipt.
        var advancedTitle = false
        let updated = copy.entries.map { pending -> SyncOutboxEntry in
            guard pending.id != entry.id, pending.pendingProviders.contains(.cloudflare), pending.mutation.titleId == entry.mutation.titleId else { return pending }
            var value = pending
            let version: Int?
            switch value.mutation {
            case .patchTitle, .trashTitle, .restoreTitle:
                version = advancedTitle ? nil : titleVersion
                advancedTitle = true
            default: version = nil
            }
            value.mutation = value.mutation.rebased(titleVersion: version, eventID: event?.id, replacing: localID, eventVersion: event?.version)
            return value
        }
        return Self(entries: updated)
    }
}
