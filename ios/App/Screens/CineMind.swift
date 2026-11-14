import SwiftUI
import TwilDiaryCore

extension View {
    /// CineMind as a sheet, from a title's ••• menu (a saved title or a preview), pulled up to full screen.
    func cineMind(isPresented: Binding<Bool>, title: MediaTitle?) -> some View {
        sheet(isPresented: isPresented) {
            if let title {
                CineMindView(title: title).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)

            }
        }
    }
}

/// An answer's Markdown, laid out as paragraphs and bullet lists (Gemini's "* " and "- " lines,
/// and "1." lists), with bold and italics inside each line.
struct AnswerText: View {
    let text: String
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { index, block in
                Group {
                switch block {
                case .paragraph(let line):
                    Text(CineMindView.markdown(line)).font(.system(size: 16)).lineSpacing(4).foregroundStyle(HomeStyle.soft)
                        .tint(HomeStyle.chipText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .heading(let line):
                    Text(CineMindView.markdown(line)).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).padding(.top, 4)
                case .bullet(let marker, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let marker { Text(marker).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent).monospacedDigit().frame(minWidth: 14, alignment: .trailing) }
                        else { Circle().fill(accent.opacity(0.9)).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] }.frame(width: 14) }
                        Text(CineMindView.markdown(line)).font(.system(size: 16)).lineSpacing(4).foregroundStyle(HomeStyle.soft)
                            .tint(HomeStyle.chipText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                }.cineReveal(order: index)
            }
        }
    }
    enum Block { case paragraph(String), heading(String), bullet(String?, String) }
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") { flush(); blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))); continue }
            if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("• ") { flush(); blocks.append(.bullet(nil, String(line.dropFirst(2)))); continue }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); blocks.append(.bullet(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}

/// Copy, with a moment's tick once copied.
private struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.snappy(duration: 0.15)) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(.snappy(duration: 0.15)) { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .semibold)).contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32).background(Color.primary.opacity(0.06), in: Circle())
        }.buttonStyle(.plain).foregroundStyle(copied ? Color(themed: "#7fe0b5") : HomeStyle.secondary).accessibilityLabel(copied ? "Copied" : "Copy answer")
            .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }
}

/// CineMind thinking: its mark and three dots that rise in turn.
private struct ThinkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            CineMindMark(size: 24, breathing: true)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = reduceMotion ? 0 : sin((time * 5) - Double(index) * 0.8)
                        Circle().fill(CineGlow.colours[index * 2 % CineGlow.colours.count]).frame(width: 7, height: 7)
                            .offset(y: -3 * max(0, phase)).opacity(0.45 + 0.55 * max(0, phase))
                    }
                }
            }.padding(.horizontal, 14).frame(height: 34).background(ThemeStore.current.native ? HomeStyle.round : HomeStyle.card, in: Capsule())
        }.accessibilityElement(children: .ignore).accessibilityLabel("Thinking")
    }
}

/// The star on CineMind's glow: a square of the assistant's colours (orange, pink, violet, blue).
struct CineMindMark: View {
    let size: CGFloat
    /// While CineMind thinks: the star breathes and the colours turn.
    var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "sparkle").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            .symbolEffect(.breathe, options: .repeating, isActive: breathing && !reduceMotion)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .background(AngularGradient(colors: CineGlow.colours + [CineGlow.colours[0]], center: .center, angle: .degrees(-40)),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

extension View {
    /// Arrives as the assistant's words do: rising a little, from soft focus to sharp, each part a
    /// beat after the one before (`order`). Simply appears under Reduce Motion.
    func cineReveal(order: Int) -> some View { modifier(CineReveal(order: order)) }
}

private struct CineReveal: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content.blur(radius: shown || reduceMotion ? 0 : 8).opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown, !reduceMotion else { return }
                withAnimation(.smooth(duration: 0.55).delay(min(Double(order), 12) * 0.07)) { shown = true }
            }
    }
}

/// While CineMind thinks, the assistant's colours glow around the whole sheet and breathe, as a
/// phone's assistant lights the screen's edge while it listens.
private struct CineEdgeGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Color.clear
            .cineGlow(RoundedRectangle(cornerRadius: 36, style: .continuous), active: true, lineWidth: 2.4)
            .phaseAnimator(reduceMotion ? [1.0] : [0.5, 1.0]) { view, strength in view.opacity(strength) } animation: { _ in .smooth(duration: 1.2) }
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// CineMind's look, after the voice assistants of today's phones (owner's request: "some Siri AI
/// theme"): one ring of warm-to-cool colours that glows around what the assistant owns (its
/// questions, the field while you type or it thinks) and slowly turns. The same in every theme.
enum CineGlow {
    static let colours = [Color(webHex: "#ff9f43"), Color(webHex: "#ff4fa3"), Color(webHex: "#a35cff"), Color(webHex: "#4f8bff"), Color(webHex: "#3fd9f2")]
    static var linear: LinearGradient { LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing) }
}

extension View {
    /// A ring of the glow's colours on `shape`'s edge: thin when calm, brighter with a soft halo when
    /// `active` (typing, thinking), turning slowly while it shows (still under Reduce Motion).
    func cineGlow<S: InsettableShape>(_ shape: S, active: Bool, lineWidth: CGFloat = 1.2) -> some View {
        modifier(CineGlowRing(shape: shape, active: active, lineWidth: lineWidth))
    }
}

private struct CineGlowRing<S: InsettableShape>: ViewModifier {
    let shape: S
    let active: Bool
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = 0.0
    func body(content: Content) -> some View {
        content
            .background {
                // The halo: the ring blurred outward, only while active.
                ring(width: lineWidth * 5).blur(radius: 9).opacity(active ? 0.55 : 0)
            }
            .overlay { ring(width: active ? lineWidth * 1.6 : lineWidth).opacity(active ? 1 : 0.65) }
            .animation(.smooth(duration: 0.35), value: active)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = 360 }
            }
    }
    private func ring(width: CGFloat) -> some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * 1.6
            AngularGradient(colors: CineGlow.colours + [CineGlow.colours[0]], center: .center, angle: .zero)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(spin))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .mask(shape.strokeBorder(lineWidth: width))
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct CineMindView: View {
    let title: MediaTitle
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var spoilerSafe = true
    @State private var addingKey = false
    @State private var hasKey = SemanticSearch.key != nil || CineMindView.uiTestKey
    #if DEBUG
    /// UI tests: show the suggestions as if a key were set (nothing is sent).
    static var uiTestKey: Bool { ProcessInfo.processInfo.arguments.contains("--ui-cinemind-key") }
    #else
    static let uiTestKey = false
    #endif
    @State private var work: Task<Void, Never>?
    @FocusState private var typing: Bool

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let fromYou: Bool
        let text: String
        var titles: [SemanticSearch.Match] = []
        var followups: [String] = []
        var failed = false
        static func == (left: Message, right: Message) -> Bool { left.id == right.id && left.text == right.text && left.titles.map(\.id) == right.titles.map(\.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if !hasKey { keyCard }
                        ForEach(messages) { message in bubble(message).id(message.id) }
                        if thinking { ThinkingRow().id("thinking").transition(.opacity) }
                    }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                .onChange(of: messages.count) { _, _ in withAnimation(.smooth) { proxy.scrollTo(messages.last?.id, anchor: .top) } }
                .onChange(of: thinking) { _, now in if now { withAnimation(.smooth) { proxy.scrollTo("thinking", anchor: .bottom) } } }
            }
            // One header in both sheet heights, and the input at the bottom, as the system's own
            // glass bars: the answers scroll softly under them instead of showing through.
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if messages.isEmpty, hasKey, !thinking { suggestions }
                    if let followups = messages.last(where: { !$0.fromYou })?.followups, !followups.isEmpty, !thinking { followupChips(followups) }
                    inputBar
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .overlay { if thinking { CineEdgeGlow().transition(.opacity) } }
            .animation(.smooth(duration: 0.45), value: thinking)
            .sensoryFeedback(.impact(weight: .light), trigger: messages.count)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $addingKey, onDismiss: { hasKey = SemanticSearch.key != nil }) { GeminiKeySheet() }
        }
    }

    // MARK: Pieces

    static var page: Color { Color(themed: "#0d0c13") }
    private static var accent: Color { Color(themed: "#8b6cf6") }

    private var header: some View {
        HStack(spacing: 12) {
            CineMindMark(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("CineMind").font(.system(size: 16, weight: .bold)).foregroundStyle(HomeStyle.primary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if progress != nil || !title.isSeries {
                Button { withAnimation(.snappy(duration: 0.2)) { spoilerSafe.toggle() } } label: {
                    Image(systemName: spoilerSafe ? "eye.slash.fill" : "eye").contentTransition(.symbolEffect(.replace)).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(spoilerSafe ? .white : HomeStyle.secondary).contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .background(spoilerSafe ? Self.accent.opacity(0.85) : Color.primary.opacity(0.06), in: Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Spoiler-safe").accessibilityValue(spoilerSafe ? "On" : "Off")
                    .accessibilityIdentifier("cinemind-spoiler-safe")
            }
            Button { work?.cancel(); withAnimation(.smooth) { messages = []; thinking = false } } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    .frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: Circle())
            }.buttonStyle(.plain).disabled(messages.isEmpty).opacity(messages.isEmpty ? 0.45 : 1)
                .accessibilityLabel("New chat").accessibilityIdentifier("cinemind-new")
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }
    /// Questions to start with, stacked above the input as glass pills (like Siri's).
    private var suggestions: some View {
        let items: [(icon: String, text: String)] = [
            ("sparkles.tv", "Recommend similar titles"),
            ("person.2.fill", "Who is the main cast?"),
            ("text.alignleft", title.isSeries ? "What is this show about?" : "What is this movie about?"),
        ]
        // Smaller pills (owner's request), each on glass with the assistant's ring and a coloured symbol.
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.text) { item in
                Button { ask(item.text) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.icon).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CineGlow.linear).frame(width: 17)
                        Text(item.text).font(.system(size: 14.5, weight: .medium)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    }.padding(.leading, 12).padding(.trailing, 14).frame(height: 38)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .cineGlow(Capsule(), active: false, lineWidth: 0.9)
                }.buttonStyle(.springPress).accessibilityIdentifier("cinemind-suggestion")
                    .cineReveal(order: items.firstIndex { $0.text == item.text } ?? 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    private var subtitle: String {
        if spoilerSafe, let progress { return title.name + " · spoiler-safe to " + progress.short }
        return title.name + (spoilerSafe ? " · spoiler-safe" : "")
    }
    private var keyCard: some View {
        Button { addingKey = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "key.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Self.accent)
                    .frame(width: 44, height: 44).background(Self.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add your Gemini key").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Text("Free from Google AI Studio").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
            }.padding(14).background(ThemeStore.current.native ? HomeStyle.round : HomeStyle.card, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
        }.buttonStyle(.springPress).padding(.top, 8).accessibilityIdentifier("cinemind-add-key")
    }
    @ViewBuilder private func bubble(_ message: Message) -> some View {
        if message.fromYou {
            HStack {
                Spacer(minLength: 56)
                Text(message.text).font(.system(size: 16, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 10)
                    .background(LinearGradient(colors: [Color(themed: "#7b5cf2"), Color(themed: "#5b3fd6")], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
            }
        } else if message.failed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Color(themed: "#ffb4a8"))
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text).font(.system(size: 14)).foregroundStyle(Color(themed: "#ffd2cb")).fixedSize(horizontal: false, vertical: true)
                    if message.id == messages.last?.id, let question = messages.last(where: { $0.fromYou })?.text {
                        Button { messages.removeLast(); ask(question, again: true) } label: {
                            Label("Try again", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        }.buttonStyle(.plain).foregroundStyle(HomeStyle.chipText)
                    }
                }
                Spacer(minLength: 0)
            }.padding(14).background(Color(themed: "#2a1517"), in: RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(alignment: .leading, spacing: 16) {
                AnswerText(text: message.text, accent: Self.accent)
                if !message.titles.isEmpty { suggestions(message.titles) }
                answerActions(message)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func answerActions(_ message: Message) -> some View {
        HStack(spacing: 8) {
            CopyButton(text: message.text)
            if message.id == messages.last?.id, let question = messages.last(where: { $0.fromYou })?.text {
                Button { messages.removeLast(); ask(question, again: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }.buttonStyle(.plain).foregroundStyle(HomeStyle.secondary).accessibilityLabel("Ask again")
            }
        }
    }
    /// The titles it names, as posters in a row.
    private func suggestions(_ matches: [SemanticSearch.Match]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(matches) { match in
                    Button { dismiss(); router.openCatalog(match.item.route) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Artwork(path: match.item.artwork, title: match.item.name, initialsOnly: false)
                                .frame(width: 112, height: 168).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
                            Text(match.item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading).frame(width: 112, alignment: .leading)
                            if let tag = match.why.split(separator: "|").first.map({ String($0).trimmingCharacters(in: .whitespaces) }), !tag.isEmpty {
                                Text(tag).font(.system(size: 11, weight: .medium)).foregroundStyle(HomeStyle.secondary).lineLimit(1).frame(width: 112, alignment: .leading)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.springPress).accessibilityLabel(match.item.name)
                }
            }.padding(.horizontal, 18)
        }.scrollIndicators(.hidden).padding(.horizontal, -18).scrollClipDisabled()
    }
    private func followupChips(_ followups: [String]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(followups.prefix(4), id: \.self) { item in
                    Button { ask(item) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(CineGlow.linear)
                            Text(item).font(.system(size: 14, weight: .medium)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        }.padding(.horizontal, 12).frame(height: 32)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .cineGlow(Capsule(), active: false, lineWidth: 0.8)
                    }.buttonStyle(.springPress)
                }
            }.padding(.horizontal, 16)
        }.scrollIndicators(.hidden).padding(.top, 4).padding(.bottom, 2)
    }
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if typing {
                Button { typing = false } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        .frame(width: 48, height: 48).glassEffect(.regular.interactive(), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Hide keyboard").accessibilityIdentifier("cinemind-hide-keyboard")
                    .transition(.scale.combined(with: .opacity))
            }
            inputField
        }
        .animation(.snappy(duration: 0.2), value: typing)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
    }
    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(messages.isEmpty ? "Ask about \(title.name)" : "Ask a follow-up", text: $draft, axis: .vertical)
                .font(.system(size: 16)).lineLimit(1...5).focused($typing).submitLabel(.send).onSubmit { send() }
                .padding(.leading, 16).padding(.vertical, 12)
                .accessibilityIdentifier("cinemind-field")
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(canSend ? .white : HomeStyle.secondary)
                    .frame(width: 36, height: 36)
                    .background(canSend ? AnyShapeStyle(AngularGradient(colors: CineGlow.colours + [CineGlow.colours[0]], center: .center, angle: .degrees(-60))) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
                    .animation(.snappy(duration: 0.15), value: canSend)
            }.buttonStyle(.plain).disabled(!canSend).padding(.trailing, 6).padding(.bottom, 6)
                .accessibilityLabel("Send").accessibilityIdentifier("cinemind-send")
        }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .cineGlow(RoundedRectangle(cornerRadius: 24, style: .continuous), active: typing || thinking)
    }
    private var canSend: Bool { hasKey && !thinking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Asking

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasKey, !thinking else { return }
        draft = ""
        ask(text)
    }
    private func ask(_ question: String, again: Bool = false) {
        guard hasKey, !thinking else { return }
        if !again { messages.append(Message(fromYou: true, text: question)) }
        thinking = true
        let history = messages
        let system = instruction
        work = Task {
            defer { thinking = false }
            do {
                guard let key = SemanticSearch.key else { return }
                let data = try await SemanticSearch.generate(Self.body(system: system, history: history), key: key)
                let reply = try Self.decode(try SemanticSearch.answerText(data))
                guard !Task.isCancelled else { return }
                var message = Message(fromYou: false, text: reply.answer, followups: reply.followups)
                messages.append(message)
                // The titles it names, found on TMDB (only real ones are shown).
                if !reply.titles.isEmpty, let token = TMDBDirect.token(store) {
                    var matches: [SemanticSearch.Match] = []
                    for suggestion in reply.titles.prefix(6) {
                        if let item = await SemanticSearch.find(suggestion, token: token) { matches.append(.init(item: item, why: suggestion.why)) }
                    }
                    guard !Task.isCancelled, let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
                    message.titles = matches
                    messages[index] = message
                }
            } catch {
                guard !Task.isCancelled else { return }
                messages.append(Message(fromYou: false, text: error.localizedDescription, failed: true))
            }
        }
    }

    /// Where you are in it: the last episode you watched, of how many.
    struct Progress { let short: String; let long: String; let rule: String }
    private var progress: Progress? {
        guard title.isSeries else { return nil }
        let episodes = store.workspace.episodes.filter { $0.titleId == title.id && $0.season > 0 }
        let watched = store.watchedEpisodeIDs(title.id)
        guard let last = episodes.filter({ watched.contains($0.id) }).max(by: { ($0.season, $0.number) < ($1.season, $1.number) }) else { return nil }
        let total = episodes.count
        let seasons = Set(episodes.map(\.season)).count
        let short = seasons > 1 ? "S\(last.season) E\(last.number)" : "Ep \(last.number)"
        let long = seasons > 1 ? "Season \(last.season), Episode \(last.number)" : "Episode \(last.number)" + (total > 0 ? " of \(total)" : "")
        return Progress(short: short, long: long, rule: "season \(last.season), episode \(last.number)")
    }
    private var instruction: String {
        var facts = ["Title: \(title.name)", "Kind: \(title.isSeries ? "TV series" : "movie") (\(title.categoryName))"]
        if let year = title.year { facts.append("Year: \(year)") }
        if !title.genres.isEmpty { facts.append("Genres: " + title.genres.joined(separator: ", ")) }
        if !title.overview.isEmpty { facts.append("Synopsis: " + title.overview) }
        facts.append("The user's status: \(title.status)" + (title.score.map { ", rated \(Int($0))/10" } ?? ""))
        if let progress { facts.append("The user has watched up to \(progress.rule).") }
        var rules = """
        You are CineMind, a friendly film and TV expert inside the TwilDiary app. Answer questions about the title below \
        (plot, characters, cast, where to start, similar titles, whether it's worth it). Be concise: a few short paragraphs \
        or a short list, in Markdown (bold for names). When you recommend titles, list them in "titles" (real titles only, \
        their original English name and first year; type "movie" or "tv"; tags: two or three short genre words). Offer two \
        or three short follow-up questions the user might tap next in "followups".
        """
        if spoilerSafe {
            rules += progress.map { " SPOILER-SAFE: the user has only seen up to \($0.rule). Never reveal anything that happens after that (deaths, twists, endings, later seasons). If a question needs a spoiler, say so and offer a spoiler-free answer." }
                ?? " SPOILER-SAFE: never reveal twists, deaths or the ending; say so if a question needs a spoiler."
        }
        return rules + "\n\n" + facts.joined(separator: "\n")
    }

    // MARK: Gemini

    struct Reply: Decodable { let answer: String; let titles: [SemanticSearch.Suggestion]; let followups: [String] }
    static func body(system: String, history: [Message]) -> [String: Any] {
        let turns = history.filter { !$0.failed }.map { message -> [String: Any] in
            ["role": message.fromYou ? "user" : "model", "parts": [["text": message.text]]]
        }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "answer": ["type": "STRING"],
                "titles": ["type": "ARRAY", "items": [
                    "type": "OBJECT",
                    "properties": ["title": ["type": "STRING"], "year": ["type": "INTEGER"], "type": ["type": "STRING", "enum": ["movie", "tv"]],
                                   "why": ["type": "STRING", "description": "two or three short genre tags separated by |"]],
                    "required": ["title", "type", "why"],
                ] as [String: Any]],
                "followups": ["type": "ARRAY", "items": ["type": "STRING"]],
            ] as [String: Any],
            "required": ["answer", "titles", "followups"],
        ]
        return [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": turns,
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.6] as [String: Any],
        ]
    }
    nonisolated static func decode(_ text: String) throws -> Reply {
        guard let data = text.data(using: .utf8) else { throw APIError.message("CineMind sent nothing back.") }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
    /// Gemini's Markdown (bold, italics, lists) as text; plain text when it isn't valid.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
