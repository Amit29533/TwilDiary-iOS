import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI
import TwilDiaryCore

/// Backups in your own Google Drive, as Cinopsys keeps them: one file in the app's hidden Drive
/// folder (`drive.appdata` lets TwilDiary see only its own folder, never your other files).
/// Signing in is Google's page in Apple's sheet with PKCE and TwilDiary's iOS client ID (no
/// secret); the refresh token is kept in the Keychain. Works with no TwilDiary server.
@MainActor enum GoogleDrive {
    static let fileName = "twildiary_backup_v1.json.zlib"
    private static let scope = "https://www.googleapis.com/auth/drive.appdata"
    private static let refreshAccount = "google.drive.refresh"
    static let connectedKey = "googleDrive.connected", lastKey = "googleDrive.last", attemptKey = "googleDrive.attempt"
    private static var access: (token: String, until: Date)?

    static var clientID: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryGoogleClientID") as? String)?.trimmingCharacters(in: .whitespaces),
              value.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return value
    }
    /// Google's iOS clients return to the reversed client ID.
    static var callbackScheme: String? {
        clientID.map { "com.googleusercontent.apps." + $0.replacingOccurrences(of: ".apps.googleusercontent.com", with: "") }
    }
    static var redirect: String? { callbackScheme.map { $0 + ":/oauthredirect" } }
    static var connected: Bool { UserDefaults.standard.bool(forKey: connectedKey) }
    /// After the app is deleted and installed again its settings are gone, but the Keychain keeps
    /// the Google sign-in: Drive counts as connected again, so the phone's extras and backups
    /// come back without connecting it by hand.
    static func reconnectAfterReinstall() {
        guard !connected, clientID != nil,
              let refresh = try? KeychainProviderSecretStore().readSecret(for: refreshAccount), !refresh.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: connectedKey)
    }
    static var last: Date? {
        let stamp = UserDefaults.standard.double(forKey: lastKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    // MARK: Sign-in

    static func signIn(using session: WebAuthenticationSession) async throws -> Bool {
        guard let clientID, let scheme = callbackScheme, let redirect else { throw APIError.message("TwilDiary’s Google app isn’t set up in this build.") }
        let verifier = base64URL(Data((0..<64).map { _ in UInt8.random(in: .min ... .max) }))
        let state = base64URL(Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }))
        var page = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        page.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        let callback: URL
        do { callback = try await session.authenticate(using: page.url!, callbackURLScheme: scheme) }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { return false }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw APIError.message("This Google sign-in doesn’t match the one TwilDiary started. Try again.") }
        if let error = value("error") { throw APIError.message(error == "access_denied" ? "Google access was declined." : "Google refused the sign-in (\(error)).") }
        guard let code = value("code") else { throw APIError.message("Google didn’t return a sign-in code.") }
        let reply = try await token(["client_id": clientID, "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect])
        guard let refresh = reply.refresh else { throw APIError.message("Google didn’t allow TwilDiary to stay signed in. Try again.") }
        guard KeychainProviderSecretStore().writeSecret(refresh, for: refreshAccount) else { throw APIError.message("The Google sign-in couldn’t be saved securely.") }
        access = (reply.access, reply.until)
        UserDefaults.standard.set(true, forKey: connectedKey)
        return true
    }
    /// Signs out (and Google forgets TwilDiary's access); `deleteBackup` removes the Drive copy first.
    static func signOut(deleteBackup: Bool) async {
        if deleteBackup {
            for name in [fileName, PhoneExtras.driveName] {
                if let file = try? await latest(name) { _ = try? await call("DELETE", "https://www.googleapis.com/drive/v3/files/" + file.id) }
            }
        }
        if let refresh = try? KeychainProviderSecretStore().readSecret(for: refreshAccount) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ProviderDeviceSignIn.form([("token", refresh)])
            _ = try? await URLSession.shared.data(for: request)
        }
        _ = KeychainProviderSecretStore().writeSecret(nil, for: refreshAccount)
        access = nil
        UserDefaults.standard.set(false, forKey: connectedKey)
        UserDefaults.standard.removeObject(forKey: lastKey)
    }
    private static func token(_ fields: [String: String]) async throws -> (access: String, refresh: String?, until: Date) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ProviderDeviceSignIn.form(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = object?["access_token"] as? String else {
            if object?["error"] as? String == "invalid_grant" {
                UserDefaults.standard.set(false, forKey: connectedKey)
                _ = KeychainProviderSecretStore().writeSecret(nil, for: refreshAccount)
                throw APIError.message("Google needs you to connect Drive again (Sync & backup).")
            }
            throw APIError.message("Google didn’t answer the sign-in (\((object?["error"] as? String) ?? "no reply")).")
        }
        let seconds = (object?["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        return (access, object?["refresh_token"] as? String, Date.now.addingTimeInterval(seconds - 120))
    }
    private static func accessToken() async throws -> String {
        if let access, access.until > .now { return access.token }
        guard let clientID, let refresh = try KeychainProviderSecretStore().readSecret(for: refreshAccount) else {
            throw APIError.message("Connect Google Drive first, in Sync & backup.")
        }
        let reply = try await token(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        access = (reply.access, reply.until)
        return reply.access
    }

    // MARK: Drive

    private static func call(_ method: String, _ url: String, body: Data? = nil, type: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 60)
        request.httpMethod = method
        request.httpBody = body
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || (method == "DELETE" && status == 404) else {
            throw APIError.message("Google Drive answered HTTP \(status).")
        }
        return data
    }
    struct File: Sendable { let id: String; let modified: Date?; let size: Int? }
    /// TwilDiary's backup in the app folder, if there is one.
    static func latest(_ name: String = fileName) async throws -> File? {
        var list = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        list.queryItems = [URLQueryItem(name: "spaces", value: "appDataFolder"), URLQueryItem(name: "q", value: "name = '\(name)'"),
                           URLQueryItem(name: "fields", value: "files(id,modifiedTime,size)"), URLQueryItem(name: "orderBy", value: "modifiedTime desc")]
        let data = try await call("GET", list.url!.absoluteString)
        guard let first = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["files"] as? [[String: Any]])?.first,
              let id = first["id"] as? String else { return nil }
        return File(id: id, modified: (first["modifiedTime"] as? String).flatMap { try? Date($0, strategy: .iso8601) }, size: (first["size"] as? String).flatMap(Int.init))
    }
    /// Saves the diary (the same snapshot as a server backup), replacing the previous Drive copy.
    @discardableResult static func backUp(store: DiaryStore, automatic: Bool = false) async throws -> Int {
        let body = try await ServerBackups.snapshot(store: store, label: "Google Drive backup")
        let json = try JSONSerialization.data(withJSONObject: body)
        let packed = try (json as NSData).compressed(using: .zlib) as Data
        let file = try await latest()
        // An automatic backup never replaces one more than twice its size: after a reinstall (or a
        // read that came back short) the diary on the phone may not be all there yet.
        if automatic, let size = file?.size, packed.count * 2 < size { return 0 }
        try await put(packed, name: fileName, file: file)
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastKey)
        return packed.count
    }
    /// Saves a file in the app folder, replacing the copy there (`file`, when already looked up).
    static func put(_ data: Data, name: String, file: File? = nil) async throws {
        var existing = file
        if existing == nil { existing = try await latest(name) }
        if let existing {
            _ = try await call("PATCH", "https://www.googleapis.com/upload/drive/v3/files/\(existing.id)?uploadType=media", body: data, type: "application/octet-stream")
        } else {
            let boundary = "twildiary-" + UUID().uuidString
            var multipart = Data()
            func add(_ text: String) { multipart.append(Data(text.utf8)) }
            add("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
            multipart.append(try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]]))
            add("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n")
            multipart.append(data)
            add("\r\n--\(boundary)--\r\n")
            _ = try await call("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart", body: multipart, type: "multipart/related; boundary=\(boundary)")
        }
    }
    /// A file's contents.
    static func get(_ file: File) async throws -> Data {
        try await call("GET", "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")
    }
    /// Puts the Drive backup back, merging (where your diary lives; nothing newer is lost).
    static func restore(store: DiaryStore) async throws -> String {
        guard let file = try await latest() else { throw APIError.message("There’s no TwilDiary backup in your Google Drive yet.") }
        let packed = try await call("GET", "https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")
        let json = try (packed as NSData).decompressed(using: .zlib) as Data
        struct Snapshot: Decodable { let diary: DiaryExport; let phone: PhoneExtras.Backup? }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: json)
        return try await ServerBackups.restore(snapshot.diary, phone: snapshot.phone, store: store)
    }
    /// An automatic Drive backup when one is due (the same schedule as server backups).
    static func runIfDue(store: DiaryStore, now: Date = .now) async {
        guard connected, !store.isPreview, !store.needsSignIn, store.hasLoadedWorkspace, !store.workspace.titles.isEmpty,
              ServerBackups.schedule.isDue(last: last, now: now) else { return }
        guard now.timeIntervalSince1970 - UserDefaults.standard.double(forKey: attemptKey) > 6 * 3_600 else { return }
        // No server: only once the phone's extras have come back from Drive this time, so the
        // backup carries them.
        guard !store.phoneOnly || PhoneDriveSync.synced else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: attemptKey)
        _ = try? await backUp(store: store, automatic: true)
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Sync & backup → Google Drive: connect, back up now, restore, disconnect.
struct GoogleDriveRow: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage(GoogleDrive.connectedKey) private var connected = false
    @State private var working: String?
    @State private var notice: String?
    @State private var confirmRestore = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsLine(title: "Google Drive", subtitle: subtitle) {
                if let working { ProgressView().controlSize(.small).accessibilityLabel(working) }
                else if !connected {
                    Button("Connect") {
                        run("Connecting…") {
                            if try await GoogleDrive.signIn(using: webAuthenticationSession) {
                                // What an earlier install saved on Drive comes back first, then the backup.
                                await PhoneDriveSync.pullIfDue(store: store, force: true)
                                notice = try await backUpMessage()
                            }
                        }
                    }
                        .buttonStyle(SettingsPillButtonStyle()).accessibilityIdentifier("drive-connect")
                } else {
                    Menu {
                        Button("Back up now", systemImage: "icloud.and.arrow.up") { run("Backing up…") { notice = try await backUpMessage() } }
                        if store.phoneOnly {
                            Button("Sync tags, notes and files", systemImage: "arrow.triangle.2.circlepath") {
                                run("Syncing…") {
                                    if try await PhoneDriveSync.run() { store.applyDiarySource() }
                                    notice = "Tags, Queue, notes, file folders, favourite people and Trash are in step with Drive."
                                }
                            }
                        }
                        Button("Restore from Drive", systemImage: "arrow.counterclockwise") { confirmRestore = true }
                        Divider()
                        Button("Disconnect", systemImage: "xmark.circle") { run("Disconnecting…") { await GoogleDrive.signOut(deleteBackup: false); notice = "Google Drive disconnected. Your backup stays in Drive." } }
                        Button("Disconnect and delete the backup", systemImage: "trash", role: .destructive) {
                            run("Deleting…") { await GoogleDrive.signOut(deleteBackup: true); notice = "Google Drive disconnected and the backup deleted." }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Google Drive actions").accessibilityIdentifier("drive-actions")
                }
            }.accessibilityIdentifier("sync-backup-drive")
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true) }
        }
        .alert("Restore from Google Drive?", isPresented: $confirmRestore) {
            Button("Restore") { run("Restoring…") { notice = try await GoogleDrive.restore(store: store) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The backup is merged into your diary; anything newer stays.") }
    }
    private var subtitle: String {
        guard connected else { return store.phoneOnly ? "Backups, and sync for tags, notes, files and Trash" : "A private copy in your own Drive" }
        guard let last = GoogleDrive.last else { return "Connected. Backs up on your schedule" }
        return "Last: " + last.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
    private func backUpMessage() async throws -> String {
        let size = try await GoogleDrive.backUp(store: store)
        return "Backed up to your Google Drive (" + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + ")."
    }
    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        working = label; notice = nil
        Task {
            do { try await work() } catch { notice = error.localizedDescription }
            working = nil
        }
    }
}
