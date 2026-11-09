import SwiftUI

/// Appearance: five themes as cards, two to a row. Each card previews the theme's accent.
struct AppearanceView: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MAKE IT YOURS").font(.system(size: 12, weight: .heavy)).tracking(1.2).foregroundStyle(theme.accent)
                    Text("A different mood. The same diary.").font(.system(size: 15)).foregroundStyle(theme.muted)
                }.padding(.horizontal, 4)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(DiaryTheme.allCases) { item in
                        Button { theme = item } label: { ThemeCard(item: item, selected: item == theme) }
                            .buttonStyle(.springPress)
                            .accessibilityLabel(item.name + ": " + item.detail)
                            .accessibilityIdentifier("theme-" + item.rawValue)
                            .accessibilityAddTraits(item == theme ? .isSelected : [])
                    }
                }
                Text("Changes instantly · saved on this iPhone").font(.system(size: 12)).foregroundStyle(theme.muted).padding(.horizontal, 4)
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }.diaryScreenBackground().diaryPageNavigation("Appearance")
    }
}

private struct ThemeCard: View {
    let item: DiaryTheme
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7).fill(item.accent).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(.white.opacity(0.22)).frame(width: 56, height: 6)
                            Capsule().fill(item.accent).frame(width: 40, height: 5)
                        }
                    }
                    Capsule().fill(.white.opacity(0.1)).frame(height: 6)
                }.padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .background(Color(webHex: "#16151b"), in: RoundedRectangle(cornerRadius: 14))
                ZStack {
                    if selected {
                        Circle().fill(item.accent)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(item.ink)
                    } else { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5) }
                }.frame(width: 24, height: 24).padding(8)
            }
            HStack(spacing: 7) {
                Circle().fill(item.accent).frame(width: 8, height: 8)
                Text(item.name).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            }.padding(.horizontal, 4)
            Text(item.detail).font(.system(size: 13)).foregroundStyle(item.muted).lineLimit(1).minimumScaleFactor(0.85).padding(.horizontal, 4)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(webHex: "#0f0e13"), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? item.accent : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
            .accessibilityElement(children: .ignore)
    }
}
