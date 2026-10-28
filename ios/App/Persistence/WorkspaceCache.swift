import Foundation
import CryptoKit
import Security
import TwilDiaryCore

struct CachedWorkspace: Codable, Sendable {
    let schema: Int
    let scope: String
    let savedAt: Date
    let workspace: Workspace
}

@MainActor protocol WorkspaceCaching {
    /// Memory-only lookup. A cold disk read must use the asynchronous path.
    func residentSnapshot(scope: String) -> CachedWorkspace?
    func load(scope: String) -> CachedWorkspace?
    func loadAsynchronously(scope: String) async throws -> CachedWorkspace?
    func save(_ workspace: Workspace, scope: String, at date: Date) throws
    func saveAsynchronously(_ workspace: Workspace, scope: String, at date: Date) async throws
    func removeAll() throws
}

extension WorkspaceCaching {
    func residentSnapshot(scope: String) -> CachedWorkspace? { nil }
    func loadAsynchronously(scope: String) async throws -> CachedWorkspace? { load(scope: scope) }
    func saveAsynchronously(_ workspace: Workspace, scope: String, at date: Date) async throws {
        try save(workspace, scope: scope, at: date)
    }
}

@MainActor final class MemoryWorkspaceCache: WorkspaceCaching {
    private var snapshot: CachedWorkspace?
    func load(scope: String) -> CachedWorkspace? { snapshot?.scope == scope ? snapshot : nil }
    func residentSnapshot(scope: String) -> CachedWorkspace? { load(scope: scope) }
    func save(_ workspace: Workspace, scope: String, at date: Date) throws {
        snapshot = CachedWorkspace(schema: 1, scope: scope, savedAt: date, workspace: try workspace.validatingIdentities())
    }
    func removeAll() throws { snapshot = nil }
}

/// Encrypted owner-scoped snapshots. This is read caching, never an offline write queue.
@MainActor final class ProtectedWorkspaceCache: WorkspaceCaching {
    private let directory: URL
    private let testKey: SymmetricKey?
    private let maximumBytes: Int
    private let beforePrepare: (@Sendable () throws -> Void)?
    private let beforeLoad: (@Sendable () throws -> Void)?
    private var writeGeneration = UUID()
    /// The device-only key is read from the Keychain once per process; every refresh
    /// previously paid a synchronous Keychain lookup on the main actor.
    private var residentKey: SymmetricKey?
    init(directory: URL? = nil, key: SymmetricKey? = nil, maximumBytes: Int = 50 * 1_024 * 1_024,
         beforePrepare: (@Sendable () throws -> Void)? = nil,
         beforeLoad: (@Sendable () throws -> Void)? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("PrivateDiary", isDirectory: true)
        testKey = key
        self.maximumBytes = max(0, maximumBytes)
        self.beforePrepare = beforePrepare
        self.beforeLoad = beforeLoad
    }
    func load(scope: String) -> CachedWorkspace? {
        try? WorkspaceCacheCodec.read(file(scope), scope: scope, key: key(create: false), maximumBytes: maximumBytes)
    }
    func loadAsynchronously(scope: String) async throws -> CachedWorkspace? {
        let ticket = writeGeneration, url = file(scope), maximum = maximumBytes, prepare = beforeLoad
        // Keychain stays on its existing owner; file I/O, authentication and
        // decoding execute off the UI actor, in the same bounded sealed format.
        guard let currentKey = try? key(create: false) else { return nil }
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try prepare?()
            try Task.checkCancellation()
            do { return try WorkspaceCacheCodec.read(url, scope: scope, key: currentKey, maximumBytes: maximum) }
            catch is CancellationError { throw CancellationError() }
            catch { return nil as CachedWorkspace? }
        }
        let value = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        guard ticket == writeGeneration else { throw CancellationError() }
        return value
    }
    func save(_ workspace: Workspace, scope: String, at date: Date) throws {
        writeGeneration = UUID()
        let encrypted = try WorkspaceCacheCodec.prepare(workspace, scope: scope, at: date, key: key(create: true), maximumBytes: maximumBytes)
        try commit(encrypted, scope: scope)
    }
    func saveAsynchronously(_ workspace: Workspace, scope: String, at date: Date) async throws {
        let ticket = UUID(); writeGeneration = ticket
        let currentKey = try key(create: true), maximum = maximumBytes, prepare = beforePrepare
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try prepare?()
            try Task.checkCancellation()
            return try WorkspaceCacheCodec.prepare(workspace, scope: scope, at: date, key: currentKey, maximumBytes: maximum)
        }
        let encrypted = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        // The commit and invalidation stay on one actor. A preparation finishing
        // after sign-out or a newer save can never recreate/replace that file.
        guard ticket == writeGeneration else { throw CancellationError() }
        try commit(encrypted, scope: scope)
    }
    private func commit(_ encrypted: Data, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(values)
        try encrypted.write(to: file(scope), options: [.atomic, .completeFileProtection])
    }
    func removeAll() throws {
        writeGeneration = UUID()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func file(_ scope: String) -> URL {
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".sealed")
    }
    private func key(create: Bool) throws -> SymmetricKey {
        if let testKey { return testKey }
        if let residentKey { return residentKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.amit29533.TwilDiary.cache-key",
                                    kSecAttrAccount as String: "device-only"]
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            let key = SymmetricKey(data: data); residentKey = key; return key
        }
        guard status == errSecItemNotFound, create else { throw APIError.message("The protected offline diary is unavailable.") }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw APIError.message("Could not protect the offline diary.") }
        residentKey = key
        return key
    }
}

private enum WorkspaceCacheCodec {
    static func read(_ url: URL, scope: String, key: SymmetricKey, maximumBytes: Int) throws -> CachedWorkspace? {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= maximumBytes else { return nil }
        let encrypted = try Data(contentsOf: url)
        guard encrypted.count <= maximumBytes else { return nil }
        try Task.checkCancellation()
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: Data(scope.utf8))
        let value = try JSONDecoder().decode(CachedWorkspace.self, from: plaintext)
        guard value.schema == 1, value.scope == scope else { return nil }
        _ = try value.workspace.validatingIdentities()
        try Task.checkCancellation()
        return value
    }
    static func prepare(_ workspace: Workspace, scope: String, at date: Date, key: SymmetricKey, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let snapshot = CachedWorkspace(schema: 1, scope: scope, savedAt: date, workspace: try workspace.validatingIdentities())
        let plaintext = try JSONEncoder().encode(snapshot)
        try Task.checkCancellation()
        guard plaintext.count <= maximumBytes else { throw APIError.message("The diary is too large for the protected offline cache.") }
        guard let encrypted = try AES.GCM.seal(plaintext, using: key, authenticating: Data(scope.utf8)).combined else {
            throw APIError.message("Could not protect the offline diary.")
        }
        try Task.checkCancellation()
        // Include nonce/tag, as the reader bounds the entire sealed file.
        guard encrypted.count <= maximumBytes else { throw APIError.message("The diary is too large for the protected offline cache.") }
        return encrypted
    }
}

extension AccessCredential {
    /// A cache partition only. Claims never authorize requests; the server validates Access.
    var cacheScope: String {
        let parts = token.split(separator: ".")
        var principal = token
        if parts.count == 3 {
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let issuer = claims["iss"] as? String, let subject = claims["sub"] as? String, !issuer.isEmpty, !subject.isEmpty {
                principal = issuer + "\n" + subject
            }
        }
        return SHA256.hash(data: Data((AppConfiguration.backend.absoluteString + "\n" + principal).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
