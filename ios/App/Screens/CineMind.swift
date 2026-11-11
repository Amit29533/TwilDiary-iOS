import SwiftUI
import TwilDiaryCore

/// CineMind: ask Gemini about the movie or show on screen. It knows the title (story, genres,
/// year) and where you are in it; spoiler-safe (on unless you turn it off) keeps every answer to
/// what you've already watched. Suggested titles are found on TMDB and open their pages.
struct CineMindButton: View {
    let title: MediaTitle
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                CineMindMark(size: 34)
                Text("CineMind").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                Spacer(minLength: 0)
                Text("Ask").font(.system(size: 12, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                    .padding(.horizontal, 10).frame(height: 24).background(HomeStyle.chip, in: Capsule())
            }.padding(.horizontal, 12).frame(height: 54)
                .background(LinearGradient(colors: [Color(webHex: "#2a2148"), Color(webHex: "#1a1530")], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(webHex: "#4a3b80").opacity(0.6), lineWidth: 1))
        }.buttonStyle(.springPress).accessibilityLabel("Ask CineMind about " + title.name).accessibilityIdentifier("cinemind-open")
            .sheet(isPresented: $open) {
                CineMindView(title: title).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                    .presentationBackground(Color(webHex: "#0d0c13"))
            }
    }
}

/// The star in a violet square.
struct CineMindMark: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "sparkle").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(webHex: "#a98bff"), Color(webHex: "#6c4cf0")], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct CineMindView: View {
    let title: MediaTitle
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var spoilerSafe = true
    @State private var addingKey = false
    @State private var hasKey = SemanticSearch.key != nil
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
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let progress { spoilerCard(progress) }
                            if !hasKey { keyCard }
                            else if messages.isEmpty { welcome }
                            ForEach(messages) { message in bubble(message).id(message.id) }
                            if thinking {
                                HStack(spacing: 8) { ProgressView().tint(HomeStyle.chipText); Text("Thinking…").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary) }
                                    .id("thinking")
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _, _ in withAnimation(.smooth) { proxy.scrollTo(messages.last?.id, anchor: .top) } }
                    .onChange(of: thinking) { _, now in if now { withAnimation(.smooth) { proxy.scrollTo("thinking", anchor: .bottom) } } }
                }
                if let followups = messages.last(where: { !$0.fromYou })?.followups, !followups.isEmpty, !thinking { followupChips(followups) }
                inputBar
            }
            .background(Color(webHex: "#0d0c13"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        HStack(spacing: 6) { CineMindMark(size: 20); Text("CineMind").font(.system(size: 16, weight: .bold)) }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { work?.cancel(); messages = []; thinking = false }
                        .disabled(messages.isEmpty).accessibilityIdentifier("cinemind-new")
                }
            }.navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CatalogRoute.self) { CatalogDetailView(route: $0) }
            .sheet(isPresented: $addingKey, onDismiss: { hasKey = SemanticSearch.key != nil }) { GeminiKeySheet() }
        }
    }

    // MARK: Pieces

    private var subtitle: String {
        if let progress, spoilerSafe { return "Spoiler-safe, up to " + progress.short }
        return title.name
    }
    private func spoilerCard(_ progress: Progress) -> some View {
        Toggle(isOn: $spoilerSafe) {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spoiler-safe").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Text("Up to " + progress.long).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                }
            }
        }.tint(Color(webHex: "#8b6cf6")).padding(12)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
            .accessibilityIdentifier("cinemind-spoiler-safe")
    }
    private var keyCard: some View {
        Button { addingKey = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your Gemini key").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                Text("CineMind uses Google’s Gemini. Get a free key at Google AI Studio and paste it once.")
                    .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.leading)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.springPress).accessibilityIdentifier("cinemind-add-key")
    }
    private var welcome: some View {
        VStack(spacing: 14) {
            CineMindMark(size: 64).padding(.top, 12)
            Text("Ask CineMind").font(.system(size: 24, weight: .bold)).foregroundStyle(HomeStyle.primary)
            Text("Plots, cast, where to start, what to watch next. Ask anything about \(title.name).")
                .font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.center).padding(.horizontal, 12)
            VStack(spacing: 10) {
                ForEach(starters, id: \.text) { starter in
                    Button { ask(starter.text) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: starter.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText).frame(width: 22)
                            Text(starter.text).font(.system(size: 15, weight: .medium)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        }.padding(.horizontal, 14).frame(height: 50)
                            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                    }.buttonStyle(.springPress)
                }
            }.padding(.top, 8)
        }.frame(maxWidth: .infinity)
    }
    private var starters: [(icon: String, text: String)] {
        if title.isSeries {
            return [("clock.arrow.circlepath", "Recap the story so far"), ("person.2", "Who is in the cast?"),
                    ("list.bullet.rectangle", "What should I watch instead?"), ("questionmark.circle", "Is it worth finishing?")]
        }
        return [("text.alignleft", "What is it about, without spoilers?"), ("person.2", "Who is in the cast?"),
                ("list.bullet.rectangle", "What should I watch next?"), ("questionmark.circle", "Is it worth watching?")]
    }
    @ViewBuilder private func bubble(_ message: Message) -> some View {
        if message.fromYou {
            HStack {
                Spacer(minLength: 48)
                Text(message.text).font(.system(size: 15)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(LinearGradient(colors: [Color(webHex: "#7b5cf2"), Color(webHex: "#5b3fd6")], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) { CineMindMark(size: 18); Text("CineMind").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary) }
                Text(Self.markdown(message.text)).font(.system(size: 15)).foregroundStyle(message.failed ? Color(webHex: "#ff8a80") : HomeStyle.soft)
                    .tint(HomeStyle.chipText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(message.titles) { match in titleCard(match) }
                HStack(spacing: 18) {
                    Button { UIPasteboard.general.string = message.text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy answer")
                    if message.id == messages.last?.id, let question = messages.last(where: { $0.fromYou })?.text {
                        Button { messages.removeLast(); ask(question, again: true) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Ask again")
                    }
                }.font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).buttonStyle(.plain)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func titleCard(_ match: SemanticSearch.Match) -> some View {
        NavigationLink(value: match.item.route) {
            HStack(spacing: 12) {
                Artwork(path: match.item.artwork, title: match.item.name, initialsOnly: false).frame(width: 46, height: 68).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(match.item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).truncationMode(.tail)
                    InlineFlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(Array(match.why.split(separator: "|").map(String.init).prefix(3)), id: \.self) { tag in
                            Text(tag).font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                .padding(.horizontal, 8).frame(height: 20).background(HomeStyle.chip, in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
            }.padding(10).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline)).contentShape(Rectangle())
        }.buttonStyle(.springPress)
    }
    private func followupChips(_ followups: [String]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(followups.prefix(4), id: \.self) { item in
                    Button { ask(item) } label: {
                        Text(item).font(.system(size: 13, weight: .medium)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            .padding(.horizontal, 14).frame(height: 34).background(HomeStyle.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }.scrollIndicators(.hidden).padding(.vertical, 6)
    }
    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(messages.isEmpty ? "Ask about \(title.name)" : "Ask a follow-up", text: $draft, axis: .vertical)
                .font(.system(size: 15)).lineLimit(1...4).focused($typing).submitLabel(.send).onSubmit { send() }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                .accessibilityIdentifier("cinemind-field")
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(Color(webHex: "#7b5cf2").opacity(canSend ? 1 : 0.4), in: Circle())
            }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send").accessibilityIdentifier("cinemind-send")
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
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
