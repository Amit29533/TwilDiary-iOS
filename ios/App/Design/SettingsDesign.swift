import SwiftUI
import TwilDiaryCore

// The owner's Settings design (Settings Redesign.html): every settings page is built from these.
// Cards are #0e0e12 with a #23232b hairline and 22 pt corners; rows are 64 pt with 15 pt padding,
// a 15 pt semibold title and a 12 pt #9a9aa8 subtitle; groups have a 13 pt bold uppercase label.

/// "MAKE IT YOURS" over a one-line explanation, at the top of a page.
struct SettingsIntro: View {
    let eyebrow: String
    let text: String
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(HomeStyle.chipText)
            Text(text).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 4)
    }
}

/// A group: its label, then its rows in one card.
struct SettingsGroup<Content: View>: View {
    var label: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let label { Text(label.uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.secondary).frame(height: 24) }
            VStack(spacing: 0) { content }.modifier(SettingsCard()).toggleStyle(SettingsToggleStyle())
        }
    }
}

/// The full-width hairline between two rows of a card.
struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Color(webHex: "#1c1c23")).frame(height: HomeStyle.hairline) }
}

/// A 38 pt #2a2440 tile with a #cdbbff symbol (44 pt for an account's own row).
struct SettingsTile: View {
    let symbol: String
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(HomeStyle.chipText)
            .frame(width: size, height: size).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

/// One row: optional leading tile, title, subtitle and whatever sits on the right.
struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }.padding(.horizontal, 15).padding(.vertical, 10).frame(minHeight: 64).contentShape(Rectangle())
    }
}
extension SettingsRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.leading = EmptyView(); self.trailing = trailing()
    }
}

/// The design's chevron for rows that open a page.
struct SettingsChevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#6a6a78")) }
}

/// "Synced", "None", "Connected": 12 pt bold on a 24 pt pill; green when good.
struct SettingsStatusPill: View {
    let text: String
    var good = true
    var body: some View {
        Text(text).font(.system(size: 12, weight: .bold)).lineLimit(1)
            .foregroundStyle(good ? Color(webHex: "#7fe0b5") : HomeStyle.dateChipText)
            .padding(.horizontal, 10).frame(height: 24)
            .background(good ? Color(webHex: "#1b2b25") : HomeStyle.round, in: Capsule())
    }
}

/// "Run", "Connect", "Save": a small pill button inside a row.
struct SettingsPillButtonStyle: ButtonStyle {
    var outlined = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: outlined ? .semibold : .bold))
            .foregroundStyle(outlined ? HomeStyle.primary : HomeStyle.chipText)
            .padding(.horizontal, 14).frame(height: 34)
            .background(outlined ? HomeStyle.round : HomeStyle.chip, in: Capsule())
            .overlay(Capsule().strokeBorder(outlined ? HomeStyle.dateChipBorder : .clear, lineWidth: HomeStyle.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "Sync now", "Back up now": a 50 pt full-width pill in the accent gradient.
struct SettingsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .bold)).foregroundStyle(Color(webHex: "#1a1030"))
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(LinearGradient(colors: [Color(webHex: "#cdbbff"), Color(webHex: "#a98bff")], startPoint: .top, endPoint: .bottom), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// "Disconnect Trakt", "Sign out": a 52 pt dark pill with pink text.
struct SettingsDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .bold)).foregroundStyle(Color(webHex: "#ffb3c0"))
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(HomeStyle.round, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The design's switch: a 46 × 28 track, the accent with a dark knob when on, #3a3a46 with a light knob when off.
struct SettingsToggleStyle: ToggleStyle {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? theme.accent : Color(webHex: "#3a3a46")).frame(width: 46, height: 28)
                    Circle().fill(configuration.isOn ? Color(webHex: "#1a1030") : HomeStyle.primary).frame(width: 22, height: 22).padding(3)
                }.animation(.snappy(duration: 0.2), value: configuration.isOn)
            }.buttonStyle(.plain)
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// A 12 pt #9a9aa8 note under a card.
struct SettingsFootnote: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
}

/// The Episodes page's season card (owner's design "Season — line in the middle"): the season
/// pill, "N of T watched" over a 6 pt bar over the time left, and the percentage. The same card on
/// a saved title and a preview (where it reads 0 of T and the season's full running time).
struct SeasonProgressCard: View {
    @Binding var season: Int
    let seasons: [Int]
    let watched: Int
    let total: Int
    let remainingMinutes: Int?
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private var percent: Int { total > 0 ? Int((Double(min(watched, total)) / Double(total) * 100).rounded()) : 0 }
    private var remaining: String {
        if total > 0 && watched >= total { return "Finished" }
        guard let minutes = remainingMinutes, minutes > 0 else { return "" }
        return DiaryDate.duration(minutes) + " left"
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Menu {
                Picker("Season", selection: $season) { ForEach(seasons, id: \.self) { Text($0 == 0 ? "Specials" : "Season \($0)").tag($0) } }
            } label: {
                HStack(spacing: 8) {
                    Text(season == 0 ? "Specials" : "Season \(season)").font(.system(size: 17, weight: .semibold)).tracking(-0.17).foregroundStyle(.white).lineLimit(1)
                    if seasons.count > 1 { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(webHex: "#A78BDB")) }
                }.padding(.leading, 16).padding(.trailing, 14).frame(minHeight: 44)
                    .background(Color(webHex: "#1E1E22"), in: Capsule()).fixedSize()
            }.disabled(seasons.count < 2).accessibilityLabel("Choose season").accessibilityValue(season == 0 ? "Specials" : "Season \(season)")
                .accessibilityIdentifier("episodes-page-season")
            VStack(spacing: 5) {
                Text("\(watched) of \(total) watched").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(webHex: "#C4C4CC")).lineLimit(1).monospacedDigit()
                Capsule().fill(Color(webHex: "#26262B")).frame(height: 6)
                    .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * CGFloat(percent) / 100) } }
                    .accessibilityHidden(true)
                Text(remaining).font(.system(size: 13)).foregroundStyle(Color(webHex: "#9A9AA3")).lineLimit(1).monospacedDigit()
            }.frame(maxWidth: .infinity)
            Text("\(percent)%").font(.system(size: 28, weight: .bold)).tracking(-0.56).monospacedDigit().foregroundStyle(theme.accent)
                .frame(minWidth: 58, alignment: .trailing)
        }.padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 20)
            .background(Color(webHex: "#0F0F11"), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.07), lineWidth: 1))
            .accessibilityElement(children: .contain)
    }
}
