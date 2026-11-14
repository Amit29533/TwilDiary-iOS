import SwiftUI
import TwilDiaryCore

/// What a sync service allows this account and how much of it is used, read from the service
/// itself: its daily request allowance and its plan's caps (lists, watchlist, favourites…).
struct ServiceLimits: Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let label: String
        /// nil when the service doesn't say (the row shows the cap alone).
        let used: Int?
        let limit: Int?
    }
    var plan: String?
    var rows: [Row] = []
    var daily: ProviderQuota.Daily?
}

@MainActor enum ServiceLimitsReader {
    static func read(_ tracker: MainTracker, store: DiaryStore) async throws -> ServiceLimits {
        switch tracker {
        case .trakt: return try await trakt(store)
        case .mdblist: return try await mdblist(store)
        case .wetrakr: return try await wetrakr(store)
        }
    }

    /// Trakt's caps from /users/settings; what's used from the phone's copy of your Trakt library
    /// (watchlist, favourites, notes) and your lists (one read of /users/me/lists).
    private static func trakt(_ store: DiaryStore) async throws -> ServiceLimits {
        let direct = TraktDirectStore.shared
        let caps = try await direct.accountLimits(store: store)
        let library = direct.library
        var lists: Int?
        if let reply = try? await direct.client(store: store).get("/users/me/lists"),
           let array = (try? JSONSerialization.jsonObject(with: reply.data)) as? [Any] { lists = array.count }
        var value = ServiceLimits(plan: caps.first?.vip == true ? "Trakt VIP" : "Free plan")
        value.rows = caps.map { cap in
            let used: Int? = switch (cap.group, cap.name) {
            case ("list", "count"): lists
            case ("watchlist", "item_count"): library?.watchlist.count
            case ("favorites", "item_count"): library?.favorites.count
            case ("notes", "item_count"): library?.notes.count
            default: nil
            }
            return ServiceLimits.Row(id: cap.id, label: cap.label, used: used, limit: cap.value)
        }
        return value
    }

    /// MDBList's /user: the plan and, when MDBList includes them, today's requests and the allowance.
    private static func mdblist(_ store: DiaryStore) async throws -> ServiceLimits {
        let config = await store.freshProviderConfig(.mdblist)
        let data = try await store.directClient.read(config, path: "/user")
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let places = [root, root["user"] as? [String: Any], root["limits"] as? [String: Any]].compactMap { $0 }
        func number(_ key: String) -> Int? {
            for place in places {
                if let value = place[key] as? NSNumber { return value.intValue }
                if let text = place[key] as? String, let value = Int(text) { return value }
            }
            return nil
        }
        var value = ServiceLimits()
        if let patron = places.lazy.compactMap({ $0["patron_status"] as? String }).first {
            value.plan = ["", "none", "free"].contains(patron.lowercased()) ? "Free plan" : "Supporter"
        } else { value.plan = "Free plan" }
        if let limit = number("api_requests"), limit > 0, let used = number("api_requests_count") {
            value.daily = ProviderQuota.Daily(used: used, limit: limit, resetsAt: nil, readAt: .now)
        }
        return value
    }

    /// WeTrakr's /account/plan-usage (each quota with what's used) and its X-Quota-* headers.
    private static func wetrakr(_ store: DiaryStore) async throws -> ServiceLimits {
        let config = await store.freshProviderConfig(.wetrakr)
        let data = try await store.directClient.read(config, path: "/account/plan-usage")
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var value = ServiceLimits()
        if let tier = (root["tier"] as? String) ?? (root["plan"] as? String) {
            value.plan = tier.lowercased() == "free" ? "Free plan" : tier.uppercased().count <= 4 ? tier.uppercased() : tier.capitalized
        }
        for case let feature as [String: Any] in (root["features"] as? [Any]) ?? [] {
            guard let key = feature["key"] as? String else { continue }
            let used = (feature["used"] as? NSNumber)?.intValue, limit = (feature["limit"] as? NSNumber)?.intValue
            guard used != nil || limit != nil else { continue }
            value.rows.append(ServiceLimits.Row(id: key, label: label(key), used: used, limit: limit))
        }
        value.daily = ProviderQuota.daily(host: "api.wetrakr.com")
        return value
    }
    private static func label(_ key: String) -> String {
        switch key {
        case "lists": "Custom lists"
        case "list_items": "Items per list"
        case "watchlist", "watchlist_items": "Watchlist"
        case "favorites", "favorite_items": "Favorites"
        case "collection", "collection_items": "Collection"
        case "notes": "Notes"
        default:
            key.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased() + key.replacingOccurrences(of: "_", with: " ").dropFirst()
        }
    }
}

/// Settings → a sync service → Account limits (owner's request: the same page for every service,
/// with real numbers): today's requests against the daily allowance, then each cap of the plan.
struct ServiceLimitsView: View {
    let tracker: MainTracker
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var limits: ServiceLimits?
    @State private var failure: String?
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) {
                if let limits {
                    dailyCard(limits.daily)
                    if !limits.rows.isEmpty {
                        SettingsGroup(label: limits.plan ?? "Account limits", info: planNote) {
                            ForEach(Array(limits.rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { SettingsDivider() }
                                LimitRow(row: row, accent: theme.accent)
                            }
                        }
                    } else if let plan = limits.plan {
                        SettingsFootnote(text: plan)
                    }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else { DiaryLoadingPlaceholder(height: 220, label: "Reading \(tracker.name)") }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("\(tracker.name) limits").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { await load() }
            .refreshable { await load() }
    }
    private func load() async {
        failure = nil
        do { limits = try await ServiceLimitsReader.read(tracker, store: store) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    @ViewBuilder private func dailyCard(_ daily: ProviderQuota.Daily?) -> some View {
        SettingsGroup(label: "Daily requests", info: dailyNote) {
            VStack(alignment: .leading, spacing: 10) {
                if let daily {
                    Text("\(daily.used.formatted()) of \(daily.limit.formatted()) used today")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).monospacedDigit()
                    LimitBar(fraction: Double(daily.used) / Double(max(1, daily.limit)), accent: theme.accent)
                    if let reset = daily.resetsAt, reset > .now {
                        Text("Resets in " + Self.untilText(reset)).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                    }
                } else {
                    Text(noDailyText).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("limits-daily")
    }
    private var noDailyText: String {
        switch tracker {
        case .trakt: "Trakt has no daily request cap."
        case .mdblist: "MDBList didn't report today's count."
        case .wetrakr: "Shows after the next WeTrakr read."
        }
    }
    private var dailyNote: String {
        switch tracker {
        case .trakt: "Trakt allows 1,000 reads every 5 minutes and one change a second; TwilDiary waits when Trakt asks it to."
        case .mdblist: "Free accounts get 1,000 requests a day. Supporter tiers raise it to 10,000, 25,000, 100,000 or 250,000."
        case .wetrakr: "WeTrakr is still testing daily quotas: going over keeps working for now."
        }
    }
    private var planNote: String {
        switch tracker {
        case .trakt: "Trakt sets these per account; VIP raises them. Lists, watchlist, favourites and notes show what you use."
        case .mdblist: "MDBList's plan."
        case .wetrakr: "From WeTrakr's plan usage. VIP raises the caps."
        }
    }
    static func untilText(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 3600 { return "\(seconds / 3600) hr" }
        return "\(max(1, seconds / 60)) min"
    }
}

/// One cap: "137 / 1,000 (14%)" with a bar, or "Limit: 1,000" when the service doesn't say what's used.
private struct LimitRow: View {
    let row: ServiceLimits.Row
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.label).font(.system(size: 15, weight: row.used == nil ? .regular : .semibold))
                    .foregroundStyle(row.used == nil ? HomeStyle.secondary : HomeStyle.primary)
                Spacer(minLength: 8)
                Text(valueText).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(row.used == nil ? HomeStyle.secondary : LimitBar.tint(fraction, accent: accent))
            }
            if row.used != nil, row.limit != nil { LimitBar(fraction: fraction, accent: accent) }
        }.padding(.horizontal, 15).padding(.vertical, 13)
            .accessibilityElement(children: .combine)
    }
    private var fraction: Double {
        guard let used = row.used, let limit = row.limit, limit > 0 else { return 0 }
        return Double(used) / Double(limit)
    }
    private var valueText: String {
        switch (row.used, row.limit) {
        case let (used?, limit?) where limit > 0: "\(used.formatted()) / \(limit.formatted())  (\(Int((fraction * 100).rounded()))%)"
        case let (nil, limit?): "Limit: \(limit.formatted())"
        case let (used?, nil): "\(used.formatted()) used"
        default: ""
        }
    }
}

/// A slim bar: the accent normally, amber from 75 % and red from 90 %.
private struct LimitBar: View {
    let fraction: Double
    let accent: Color
    static func tint(_ fraction: Double, accent: Color) -> Color {
        fraction >= 0.9 ? Color(themed: "#ff6b6b") : fraction >= 0.75 ? Color(themed: "#f5c26b") : accent
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Self.tint(fraction, accent: accent)).frame(width: max(6, geometry.size.width * min(1, max(0, fraction))))
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}
