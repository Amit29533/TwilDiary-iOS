import SwiftUI
import UIKit
import TwilDiaryCore

// MARK: Shared settings pieces

/// A titled group of rows on a dark card, as every Settings page shows them.
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { Text(title.uppercased()).font(.system(size: 13, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary).padding(.horizontal, 4) }
            VStack(spacing: 0) { content }.diarySectionBackground(radius: 20, stroke: .white.opacity(0.08))
        }
    }
}
struct SettingsDivider: View {
    var body: some View { Divider().overlay(.white.opacity(0.06)).padding(.leading, 16) }
}
/// Title and subtitle on the left, anything on the right.
struct SettingsLine<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }.padding(.horizontal, 16).frame(minHeight: 64).contentShape(Rectangle())
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
                SettingsGroup(title: "General") {
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
                SettingsGroup(title: "Titles") {
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

struct SyncBackupView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("confirmDeletions") private var confirmDeletions = true
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
                SettingsGroup(title: "Sync") {
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
                SettingsGroup(title: "Backup") {
                    NavigationLink(value: AppDestination.backups) {
                        SettingsLine(title: "Server backups", subtitle: lastServerBackup.map { "Last: " + $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "Copies of your diary kept on your server") {
                            DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("sync-backup-server")
                }
                SettingsGroup(title: "Extra backup") {
                    SettingsLine(title: "Back up to Files", subtitle: "A daily copy in Files → On My iPhone → TwilDiary") {
                        Toggle("", isOn: $filesBackup).labelsHidden().tint(theme.accent)
                    }.accessibilityIdentifier("sync-backup-files")
                    SettingsDivider()
                    SettingsLine(title: "Google Drive", subtitle: "A private copy in your own Drive") {
                        Text("Needs setup").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).frame(height: 32).background(.white.opacity(0.07), in: Capsule())
                    }
                }
                if let localNotice { Text(localNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Sync & backup")
            .task {
                refresh = UIApplication.shared.backgroundRefreshStatus
                if !store.isPreview, let list: BackupList = try? await store.read("/api/backups") { lastServerBackup = list.backups.compactMap { DiaryDate.parse($0.createdAt) }.max() }
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
            let data = try await Task.detached(priority: .utility) { try DiaryExport(workspace: snapshot).encoded() }.value
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
