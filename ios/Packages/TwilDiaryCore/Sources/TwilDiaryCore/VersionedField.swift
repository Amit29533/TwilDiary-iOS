/// Keeps a local field draft separate from unrelated changes to its parent record.
/// Rebasing over a conflicting field value always requires an explicit user choice.
public struct VersionedField<Value: Equatable & Sendable>: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let value: Value
        public let version: Int?
        public init(value: Value, version: Int?) { self.value = value; self.version = version }
    }
    public var draft: Value
    public private(set) var version: Int?
    public private(set) var conflict: Snapshot?
    private var base: Value
    private var confirmed: Snapshot?
    public init(value: Value, version: Int?) {
        draft = value; base = value; self.version = version
    }
    public var isDirty: Bool { draft != base }
    public var awaitingRefresh: Bool { confirmed != nil }
    public var submission: Snapshot? {
        guard conflict == nil, confirmed == nil else { return nil }
        return Snapshot(value: draft, version: version)
    }
    public mutating func observe(_ saved: Snapshot) {
        if let confirmed {
            // A confirmed write can precede a failed workspace refresh. An old
            // snapshot must not replace the acknowledged value or permit a replay.
            let newer = saved.version.flatMap { next in confirmed.version.map { next > $0 } } ?? false
            guard newer || saved.value == confirmed.value else { return }
            self.confirmed = nil
        }
        let newest = [version, conflict?.version].compactMap { $0 }.max()
        if let previous = newest, let next = saved.version, next < previous { return }
        if saved.value == base {
            version = saved.version; conflict = nil
        } else if draft == base || draft == saved.value {
            base = saved.value; draft = saved.value; version = saved.version; conflict = nil
        } else {
            conflict = saved
        }
    }
    public mutating func acknowledge(_ submitted: Snapshot, latest: Snapshot) {
        base = submitted.value; version = submitted.version; conflict = nil
        confirmed = submitted
        observe(latest)
    }
    public mutating func useSaved() {
        guard let saved = conflict else { return }
        base = saved.value; draft = saved.value; version = saved.version; conflict = nil
    }
    public mutating func keepDraft() {
        guard let saved = conflict else { return }
        base = saved.value; version = saved.version; conflict = nil
    }
}
