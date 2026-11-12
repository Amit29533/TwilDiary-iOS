import SwiftUI
import UIKit
import TwilDiaryCore

// MARK: Shared settings pieces

// SettingsGroup and SettingsDivider live in Design/SettingsDesign.swift (the design's cards).
/// Title and subtitle on the left, anything on the right.
struct SettingsLine<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            trailing
        }.padding(.horizontal, 15).frame(minHeight: 64).contentShape(Rectangle())
    }
}

/// Where tags, Queue, full notes and the other extras Trakt can't keep live besides this iPhone:
/// Google Drive, your server, or both at once (owner's choice). The phone always has its own copy.
struct ExtrasStorageGroup: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(ExtrasStorage.driveKey) private var drive = true
    @AppStorage(ExtrasStorage.serverKey) private var server = false
    @AppStorage(GoogleDrive.connectedKey) private var driveConnected = false
    private var sync: PhoneServerSync { PhoneServerSync.shared }
    var body: some View {
        SettingsGroup(label: "Where extras live") {
            SettingsLine(title: "On this iPhone", subtitle: "Tags, Queue, full notes, statuses Trakt can't keep, file folders, favourite people, Trash") {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
            }
            SettingsDivider()
            SettingsLine(title: "Google Drive", subtitle: driveConnected ? "Kept in step through TwilDiary's Drive folder" : "Connect Google Drive below to keep them there") {
                Toggle("", isOn: $drive).labelsHidden().tint(theme.accent)
            }.accessibilityIdentifier("extras-drive")
            SettingsDivider()
            SettingsLine(title: "Your server", subtitle: serverSubtitle) {
                if sync.running { ProgressView().controlSize(.small).accessibilityLabel("Syncing with your server") }
                else { Toggle("", isOn: $server).labelsHidden().tint(theme.accent) }
            }.accessibilityIdentifier("extras-server")
        }
        .onChange(of: drive) { _, on in if on { Task { await PhoneDriveSync.pullIfDue(store: store, force: true) } } }
        .onChange(of: server) { _, on in
            if on { Task { await sync.pullIfDue(store: store, force: true) } } else { sync.forget() }
        }
        .task { sync.store = store }
    }
    private var serverSubtitle: String {
        guard server else { return "Your TwilDiary server on Cloudflare, reached with your Trakt sign-in" }
        if let problem = sync.problem { return problem }
        if let at = sync.lastSynced { return "In step · " + at.formatted(.relative(presentation: .named)) }
        return "Getting in step…"
    }
}

// MARK: Language & region

struct LanguageRegionView: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("streamingRegion") private var region = Locale.current.region?.identifier ?? "US"
    @AppStorage("use24HourTime") private var use24Hour = false
    @AppStorage("animeEnglishTitles") private var animeEnglish = false
    @AppStorage("ignoreTitleArticles") private var ignoreArticles = false
    @Environment(\.openURL) private var openURL
    static let regions = ["AU", "BR", "CA", "DE", "ES", "FR", "GB", "IN", "IT", "JP", "KR", "MX", "NL", "SE", "US"]
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(label: "General") {
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                        row("character.bubble", "Language") {
                            HStack(spacing: 6) { Text(languageName).foregroundStyle(.secondary); DiaryIcon(name: "arrow-up-right", size: 14).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain).accessibilityHint("Opens TwilDiary in the Settings app, where iOS sets its language")
                    SettingsDivider()
                    Menu {
                        Picker("Region", selection: $region) { ForEach(Self.regions, id: \.self) { Text(Self.regionName($0)).tag($0) } }
                    } label: {
                        row("globe", "Region", subtitle: "For streaming services") {
                            HStack(spacing: 6) { Text(Self.regionName(region)).foregroundStyle(.secondary); DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-region")
                    SettingsDivider()
                    row("clock", "24-hour time", subtitle: "Instead of AM/PM") { Toggle("", isOn: $use24Hour).labelsHidden().tint(theme.accent) }
                }
                SettingsGroup(label: "Titles") {
                    SettingsLine(title: "Anime titles in English", subtitle: "Instead of romaji") { Toggle("", isOn: $animeEnglish).labelsHidden().tint(theme.accent) }
                    SettingsDivider()
                    SettingsLine(title: "Ignore \u{201C}A\u{201D}, \u{201C}An\u{201D}, \u{201C}The\u{201D}", subtitle: "When sorting titles") { Toggle("", isOn: $ignoreArticles).labelsHidden().tint(theme.accent) }
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Language & region")
    }
    private var languageName: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
    static func regionName(_ code: String) -> String { Locale.current.localizedString(forRegionCode: code) ?? code }
    private func row<Trailing: View>(_ icon: String, _ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent).frame(width: 38, height: 38).background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }.padding(.horizontal, 16).frame(minHeight: 64).contentShape(Rectangle())
    }
}

/// The 24-hour time choice for dates shown by SwiftUI text (the system clock setting otherwise).
extension Locale {
    static func diary(use24Hour: Bool) -> Locale {
        guard use24Hour else { return .autoupdatingCurrent }
        var components = Locale.Components(locale: .current)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }
}

// MARK: Sync & backup

/// Settings → Notifications: everything TwilDiary can tell you about, in one place.
struct NotificationsSettingsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(EpisodeNotifications.enabledKey) private var episodeAlerts = false
    @State private var releaseAlerts = ReleaseAlerts.enabled
    @State private var notice: String?
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(label: "Alerts") {
                    SettingsLine(title: "New episodes", subtitle: "New episodes of shows you watch") {
                        Toggle("", isOn: Binding(get: { episodeAlerts }, set: { on in
                            if on { Task { if await !EpisodeNotifications.enable(store: store) { notice = "Allow notifications for TwilDiary in the Settings app." } } }
                            else { EpisodeNotifications.disable() }
                        })).labelsHidden().tint(theme.accent)
                    }.accessibilityIdentifier("sync-episode-alerts")
                    SettingsDivider()
                    SettingsLine(title: "Releases", subtitle: "Releases, new seasons and returns") {
                        Toggle("", isOn: Binding(get: { releaseAlerts }, set: { on in
                            releaseAlerts = on
                            Task { if await !ReleaseAlerts.setEnabled(on, store: store) { releaseAlerts = false; notice = "Allow notifications for TwilDiary in the Settings app." } }
                        })).labelsHidden().tint(theme.accent)
                    }.accessibilityIdentifier("sync-release-alerts")
                }
                SettingsFootnote(text: "A check-in also tells you when its watch is logged, while alerts are allowed.")
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Notifications")
    }
}

struct SyncBackupView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("confirmDeletions") private var confirmDeletions = true
    @AppStorage(ServiceRemovals.key) private var applyRemovals = true
    @AppStorage(EpisodeNotifications.enabledKey) private var episodeAlerts = false
    @State private var releaseAlerts = ReleaseAlerts.enabled
    @State private var importing = false
    @AppStorage(LocalBackups.enabledKey) private var filesBackup = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var refresh = UIBackgroundRefreshStatus.available
    @State private var lastServerBackup: Date?
    @State private var localNotice: String?
    private struct Summary: Decodable { let createdAt: String }
    private struct BackupList: Decodable { let backups: [Summary] }
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup(label: "Sync") {
                    SettingsLine(title: "Background sync", subtitle: refresh == .available ? "Syncs now and then while the app is closed" : "Otherwise it syncs when you open the app") {
                        Text(refresh == .available ? "On" : "Off").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                        Text("Open Settings").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16)
                    }.buttonStyle(.plain).accessibilityHint("Background App Refresh is turned on in the Settings app")
                    SettingsDivider()
                    SettingsLine(title: "Confirm deletions", subtitle: "Ask before removing titles") { Toggle("", isOn: $confirmDeletions).labelsHidden().tint(theme.accent) }
                }
                if !store.phoneOnly {
                SettingsGroup(label: "Backup") {
                    NavigationLink(value: AppDestination.backups) {
                        SettingsLine(title: "Server backups", subtitle: lastServerBackup.map { "Last: " + $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "Copies of your diary kept on your server") {
                            DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("sync-backup-server")
                    SettingsDivider()
                    ServerBackups.SchedulePicker().padding(.horizontal, 16).frame(minHeight: 60)
                }
                }
                if store.phoneOnly, !store.onThisPhone { ExtrasStorageGroup() }
                SettingsGroup(label: store.phoneOnly ? "Backup" : "Extra backup") {
                    SettingsLine(title: "Back up to Files", subtitle: "A daily copy in the Files app") {
                        Toggle("", isOn: $filesBackup).labelsHidden().tint(theme.accent)
                    }.accessibilityIdentifier("sync-backup-files")
                    SettingsDivider()
                    GoogleDriveRow()
                    SettingsDivider()
                    Button { importing = true } label: {
                        SettingsLine(title: "Import from another app", subtitle: "Letterboxd, IMDb, TV Time") {
                            DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("sync-import")
                }
                if let localNotice { Text(localNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Sync & backup")
            .sheet(isPresented: $importing) { ImportHistoryView() }
            .task {
                refresh = UIApplication.shared.backgroundRefreshStatus
                if !store.isPreview, !store.phoneOnly, let list: BackupList = try? await store.read("/api/backups") {
                    lastServerBackup = list.backups.compactMap { DiaryDate.parse($0.createdAt) }.max()
                    ServerBackups.noteLatest(lastServerBackup)
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh = UIApplication.shared.backgroundRefreshStatus } }
            .onChange(of: filesBackup) { _, on in
                guard on else { return }
                Task { localNotice = await LocalBackups.write(store: store, force: true) }
            }
    }
}

/// Daily JSON copies of the diary in the app's Documents folder (Files → On My iPhone → TwilDiary),
/// the newest seven kept.
@MainActor enum LocalBackups {
    static let enabledKey = "filesBackup"
    private static let lastKey = "filesBackup.last"
    @discardableResult static func write(store: DiaryStore, force: Bool = false) async -> String? {
        guard UserDefaults.standard.bool(forKey: enabledKey) || force, !store.workspace.titles.isEmpty else { return nil }
        let day = DiaryDate.day(store.now)
        guard force || UserDefaults.standard.string(forKey: lastKey) != day else { return nil }
        let snapshot = store.workspace
        do {
            var data = try await Task.detached(priority: .utility) { try DiaryExport(workspace: snapshot).encoded() }.value
            // No server: the phone's extras ride along (Import diary puts them back).
            if store.phoneOnly, let phone = ServerBackups.phoneExtras(),
               var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root["phone"] = phone
                data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            }
            let folder = URL.documentsDirectory.appending(path: "Backups", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: "TwilDiary-\(day).json"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("TwilDiary-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in files.dropFirst(7) { try? FileManager.default.removeItem(at: old) }
            UserDefaults.standard.set(day, forKey: lastKey)
            return "Saved today’s copy to Files."
        } catch { return "Couldn’t save a copy: " + error.localizedDescription }
    }
}
