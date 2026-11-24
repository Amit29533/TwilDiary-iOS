import SwiftUI

/// Settings → Text size (owner's request): the app's text follows iPhone's Text Size, or a size of
/// your own on a slider (80% to 140%). Only text changes; posters, rows and buttons keep their size.
/// The new size reaches every page shortly after the slider stops (each tab is redrawn once, and
/// stays where it was).
struct TextSizeView: View {
    @AppStorage(TextScale.followsKey) private var followsSystem = true
    @AppStorage(TextScale.customKey) private var custom = 1.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The slider's value while you move it; saved (and applied to the app) once it rests.
    @State private var draft: Double

    init() {
        _draft = State(initialValue: UserDefaults.standard.object(forKey: TextScale.customKey) as? Double ?? 1)
    }

    var body: some View {
        let shown = followsSystem ? Double(TextScale.scale(dynamicTypeSize)) : draft
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: Gap.section) {
                SettingsIntro(eyebrow: "Text size", text: "How big the app’s text is. Posters, rows and buttons keep their size.")
                SettingsGroup(label: "Size") {
                    Toggle(isOn: $followsSystem) {
                        SettingsRowTitle("Match iPhone", "Settings → Display & Brightness → Text Size")
                    }.settingsRowFrame().accessibilityIdentifier("text-size-follow")
                    if !followsSystem {
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Your size").font(.app(size: 16)).foregroundStyle(HomeStyle.primary)
                                Spacer()
                                Text(Self.percent(draft)).font(.app(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                            }
                            HStack(spacing: 12) {
                                Text("A").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary).accessibilityHidden(true)
                                Slider(value: $draft, in: TextScale.customRange, step: 0.05) { Text("Text size") }
                                    .accessibilityValue(Self.percent(draft)).accessibilityIdentifier("text-size-slider")
                                Text("A").font(.system(size: 24, weight: .semibold)).foregroundStyle(HomeStyle.secondary).accessibilityHidden(true)
                            }
                            Button("Back to 100%") { draft = 1 }.font(.app(size: 15, weight: .semibold))
                                .disabled(draft == 1).accessibilityIdentifier("text-size-reset")
                        }.padding(.horizontal, 16).padding(.vertical, 14)
                    }
                }
                SettingsGroup(label: "Preview") { preview(scale: shown) }
                SettingsFootnote(text: followsSystem
                                 ? "Now \(Self.percent(shown)), from iPhone’s Text Size."
                                 : "Every page takes the new size a moment after you stop moving the slider.")
            }.padding(.horizontal, Gap.gutter).padding(.top, 8).padding(.bottom, 100)
        }
        .diaryScreenBackground().diaryPageNavigation("Text size")
        // Saved once the slider rests, so the app is redrawn once, not on every step.
        .task(id: draft) {
            guard !followsSystem, draft != custom else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            custom = draft
        }
    }

    /// A heading, a line of body text and a caption at the chosen size (drawn directly at that
    /// size, so it changes while the slider moves).
    private func preview(scale: Double) -> some View {
        let size = CGFloat(scale)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Continue watching").font(.system(size: 22 * size, weight: .bold)).foregroundStyle(HomeStyle.primary)
            Text("Vivant · S1 E2 · 9 left (8h 36m)").font(.system(size: 15 * size)).foregroundStyle(HomeStyle.primary)
            Text("Added to Planned today").font(.system(size: 12 * size)).foregroundStyle(HomeStyle.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    nonisolated static func percent(_ scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
}
