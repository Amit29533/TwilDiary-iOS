import SwiftUI

/// Appearance: the themes as cards, two to a row (the five originals and Premiere). Each card previews the theme's accent.
struct AppearanceView: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(NativeAppearance.key) private var nativeAppearance = NativeAppearance.automatic
    @AppStorage(Haptics.key) private var haptics = true
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(eyebrow: "Make it yours", text: "A different mood. The same diary.")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(DiaryTheme.allCases) { item in
                        Button { if item != theme { Haptics.play(.selection) }; theme = item } label: { ThemeCard(item: item, selected: item == theme) }
                            .buttonStyle(.springPress)
                            .accessibilityLabel(item.name + ": " + item.detail)
                            .accessibilityIdentifier("theme-" + item.rawValue)
                            .accessibilityAddTraits(item == theme ? .isSelected : [])
                    }
                }
                if theme == .native {
                    // Native's light or dark: follow the iPhone, or always one (as Apple's apps offer).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("APPEARANCE").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).padding(.leading, 16)
                        NativeSegmentedControl(segments: NativeAppearance.allCases.map { NativeSegment(value: $0, title: $0.title, id: "native-appearance-" + $0.rawValue) },
                                               selection: $nativeAppearance)
                        SettingsFootnote(text: nativeAppearance == .automatic ? "Follows your iPhone’s light or dark setting." : "Always \(nativeAppearance.rawValue), whatever your iPhone is set to.")
                    }.transition(.opacity.combined(with: .move(edge: .top)))
                }
                // Haptics: the little taps when you mark, add, switch tabs and trace the rating chart.
                SettingsGroup(label: "Feel") {
                    HStack(spacing: ThemeStore.current.native ? 12 : 14) {
                        SettingsTile(symbol: "iphone.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Haptics").font(.system(size: ThemeStore.current.native ? 17 : 15, weight: ThemeStore.current.native ? .regular : .semibold))
                                .foregroundStyle(HomeStyle.primary).lineLimit(1)
                            Text(haptics ? "Little taps as you mark, add, switch and scrub" : "Off · no taps anywhere in the app")
                                .font(.system(size: ThemeStore.current.native ? 13 : 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Toggle("", isOn: $haptics).labelsHidden().tint(ThemeStore.current.native ? Color(uiColor: .systemGreen) : theme.accent)
                    }.padding(.horizontal, 15).frame(minHeight: 64)
                        .accessibilityElement(children: .combine).accessibilityIdentifier("settings-haptics")
                        // Turning them on answers with one, so you feel what you chose.
                        .onChange(of: haptics) { _, on in if on { Haptics.play(.success) } }
                }
                SettingsFootnote(text: "Changes instantly · saved on this iPhone")
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Appearance")
    }
}

private struct ThemeCard: View {
    let item: DiaryTheme
    let selected: Bool
    /// Each theme's own ground, whichever theme is on screen; Native's is half light, half dark (it follows the iPhone).
    @ViewBuilder private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if item == .native {
            HStack(spacing: 0) { Color(white: 0.95); Color(white: 0.08) }.clipShape(shape)
                .overlay(shape.strokeBorder(HomeStyle.outline(0.08)))
        } else {
            shape.fill(Color(webHex: "#08080c"))
        }
    }
    var body: some View {
        // Design (board 2): a 104 pt #08080c preview (radius 14) with the accent tile and bars, a 22 pt
        // selection ring, then the name (15 pt bold, 8 pt dot) and the line under it (12 pt).
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 9).fill(item.accent).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(item == .native ? Color.gray.opacity(0.5) : Color(webHex: "#3a3a46")).frame(width: 71, height: 5)
                            Capsule().fill(item.accent).frame(width: 45, height: 5)
                        }.padding(.top, 6)
                    }
                    Capsule().fill(HomeStyle.cardBorder).frame(height: 5).padding(.top, 10)
                }.padding(.horizontal, 12).padding(.top, 34).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                    .background { preview }
                ZStack {
                    if selected {
                        Circle().fill(item.accent)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ThemeStore.current.accentInk)
                    } else { Circle().strokeBorder(Color(themed: "#3a3a46"), lineWidth: 1.5) }
                }.frame(width: 22, height: 22).padding(8)
            }
            HStack(spacing: 7) {
                Circle().fill(item.accent).frame(width: 8, height: 8)
                Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
            }.padding(.top, 10)
            Text(item.detail).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 2)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(22)
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? item.accent : HomeStyle.cardBorder, lineWidth: selected ? 1.5 : HomeStyle.hairline))
            .accessibilityElement(children: .ignore)
    }
}
