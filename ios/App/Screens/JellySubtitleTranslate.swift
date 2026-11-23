import SwiftUI
import Translation
import NaturalLanguage

/// Live subtitle translation (player → Advanced options → Translate): each line translated on the
/// phone by Apple's Translation, with languages already downloaded (Settings → Apps → Translate →
/// Downloaded Languages); no download sheet opens over the player (it drew half the screen black).
/// Text subtitles only; picture ones (PGS, DVD) stay as they are. The language chosen is kept for
/// the next video.
@MainActor final class JellyTranslator: ObservableObject {
    static let targetKey = "jellyspace.subtitle.translateTo"

    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// The language lines are translated into ("" off), e.g. "en".
    @Published private(set) var target: String
    /// Translating now: the languages are on the phone and the session is open (false while off,
    /// while the subtitles' language isn't known, or when they're already in the language wanted).
    @Published private(set) var translating = false
    /// Translated lines by their original text.
    @Published private(set) var lines: [String: String] = [:]
    /// The subtitles' language once known ("ko").
    @Published private(set) var source: String?
    /// The languages it can translate into, yours first.
    @Published private(set) var choices: [Choice] = []
    /// Set when translating fails (the language download declined, say); the player shows it.
    @Published var problem: String?

    private var waiting: [String] = []
    private var inFlight = Set<String>()
    private var sample: [String] = []
    private var fedAt = -10.0
    private var fedCount = -1
    /// Changes with each reset, so a batch that comes back late isn't kept for the wrong language.
    private var generation = 0
    /// Failed for this video: not tried again until the language or the video changes.
    private var stopped = false
    /// The translating, and the language pair it's for ("ko>en").
    private var runner: Task<Void, Never>?
    private var pairKey: String?
    enum Why: Sendable { case notDownloaded, unsupported }

    init() { target = UserDefaults.standard.string(forKey: Self.targetKey) ?? "" }

    var wanted: Bool { !target.isEmpty }
    /// "Korean"
    var sourceName: String { source.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? "" }
    var targetName: String { target.isEmpty ? "Off" : (Locale.current.localizedString(forIdentifier: target) ?? target) }

    func setTarget(_ code: String) {
        // The same again after a failure (once the languages are downloaded, say) tries again.
        guard code != target || stopped else { return }
        target = code
        UserDefaults.standard.set(code, forKey: Self.targetKey)
        clear()
        reconfigure()
    }
    /// Another video or subtitle track: its language from the track, else found from its lines.
    func reset(language: String?) {
        clear()
        sample = []
        source = Self.code(language)
        reconfigure()
    }
    private func clear() {
        lines = [:]; waiting = []; inFlight = []; fedAt = -10; fedCount = -1
        generation += 1; stopped = false; problem = nil
    }

    /// Whether to hand over the next lines: every two seconds, and at once after a seek or when the
    /// lines change.
    func due(at time: Double, count: Int) -> Bool {
        guard wanted, !stopped, count > 0 else { return false }
        if count == fedCount, time >= fedAt, time - fedAt < 2 { return false }
        fedAt = time; fedCount = count
        return true
    }
    /// Lines to translate, the soonest first (they go ahead of any still waiting).
    func want(_ texts: [String]) {
        guard wanted, !stopped else { return }
        let fresh = texts.filter { !$0.isEmpty && lines[$0] == nil && !inFlight.contains($0) }
        guard !fresh.isEmpty else { return }
        if source == nil {
            sample += fresh.prefix(20)
            detect()
        }
        var seen = Set<String>()
        let first = fresh.filter { seen.insert($0).inserted }
        waiting = Array((first + waiting.filter { !seen.contains($0) }).prefix(300))
    }
    /// The next lines for the translation task.
    func next() -> (batch: [String], generation: Int) {
        guard translating else { return ([], generation) }
        let batch = Array(waiting.prefix(16))
        waiting.removeFirst(batch.count)
        inFlight.formUnion(batch)
        return (batch, generation)
    }
    func store(_ found: [String: String], batch: [String], generation: Int) {
        inFlight.subtract(batch)
        guard generation == self.generation, !found.isEmpty else { return }
        lines.merge(found) { _, new in new }
    }
    func failed(_ batch: [String], generation: Int, reason: String) {
        inFlight.subtract(batch)
        guard generation == self.generation else { return }
        stopped = true
        reconfigure()
        problem = "Couldn't translate the subtitles into " + targetName + (reason.isEmpty ? "" : ": " + reason)
    }
    /// The session is open: lines can go.
    func began(generation: Int) {
        if generation == self.generation, pairKey != nil { translating = true }
    }
    /// It can't start: the languages aren't downloaded, or Apple doesn't translate this pair.
    func cannot(_ why: Why, generation: Int) {
        guard generation == self.generation else { return }
        stopped = true
        reconfigure()
        switch why {
        case .notDownloaded:
            problem = "Download " + sourceName + " and " + targetName + " in Settings → Apps → Translate → Downloaded Languages, then choose " + targetName + " again"
        case .unsupported:
            problem = "Translating " + sourceName + " into " + targetName + " isn't available"
        }
    }

    /// The languages to choose from, read once.
    func loadChoices() async {
        guard choices.isEmpty else { return }
        let supported = await Self.supportedLanguages()
        let mine = Locale.preferredLanguages.map(Self.base)
        var seen = Set<String>()
        let all = supported.compactMap { language -> Choice? in
            let id = language.minimalIdentifier
            guard seen.insert(id).inserted else { return nil }
            return Choice(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        choices = all.sorted { a, b in
            let x = mine.firstIndex(of: Self.base(a.id)) ?? Int.max, y = mine.firstIndex(of: Self.base(b.id)) ?? Int.max
            return x != y ? x < y : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Apple's list of languages it can translate (LanguageAvailability isn't Sendable, so it's made
    /// and asked away from the main actor).
    nonisolated private static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }
    /// The subtitles' language from their lines, once there are enough of them to tell.
    private func detect() {
        let text = sample.joined(separator: "\n")
        guard text.count >= 60 || sample.count >= 8 else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let found = recognizer.dominantLanguage, found != .undetermined else { return }
        source = found.rawValue
        reconfigure()
    }
    /// Starts (or stops) the translating for the language pair wanted now.
    private func reconfigure() {
        var key: String?
        if wanted, !stopped, let source, Self.base(source) != Self.base(target) { key = source + ">" + target }
        guard key != pairKey else { return }
        pairKey = key
        runner?.cancel()
        runner = nil
        translating = false
        guard key != nil, let source else { return }
        let target = self.target, generation = self.generation
        runner = Task { await Self.run(source: source, target: target, generation: generation, for: self) }
    }
    /// A track's language as a short code ("kor" → "ko"); nil when it has none.
    static func code(_ language: String?) -> String? {
        guard let language, !language.isEmpty, language.lowercased() != "und" else { return nil }
        return Locale.LanguageCode(language).identifier(.alpha2) ?? language
    }
    private static func base(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier ?? code
    }

    /// The translating, until it's cancelled (a new language pair starts it again): the languages
    /// checked, then a session with the ones on the phone, off the main actor; lines come from it.
    nonisolated static func run(source: String, target: String, generation: Int, for translator: JellyTranslator) async {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: from, to: to)
        guard !Task.isCancelled else { return }
        if status == .supported {
            await translator.cannot(.notDownloaded, generation: generation)
            return
        }
        guard status == .installed else {
            await translator.cannot(.unsupported, generation: generation)
            return
        }
        let session = TranslationSession(installedSource: from, target: to)
        await translator.began(generation: generation)
        while !Task.isCancelled {
            let (batch, generation) = await translator.next()
            guard !batch.isEmpty else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            let requests = batch.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            do {
                let responses = try await session.translations(from: requests)
                var found: [String: String] = [:]
                for response in responses {
                    if let index = response.clientIdentifier.flatMap(Int.init), batch.indices.contains(index) { found[batch[index]] = response.targetText }
                }
                await translator.store(found, batch: batch, generation: generation)
            } catch {
                if Task.isCancelled {
                    await translator.store([:], batch: batch, generation: generation)
                    return
                }
                await translator.failed(batch, generation: generation, reason: FriendlyError.message(error))
                return
            }
        }
    }
}

/// A translated line over mpv's picture (mpv reads its subtitles but draws them see-through while
/// they're translated), placed and drawn as the player's own plain subtitles.
struct JellyTranslatedLine: View {
    let text: String
    var look: JellySubtitleLook
    var insets: EdgeInsets
    var lift: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let up = proxy.size.height * look.raise + (look.lift ? lift : 0)
            JellyPlainSubtitle(text: text, look: look, points: max(12, JellySubtitleLook.points(screenHeight: proxy.size.height, size: look.size)))
                .padding(.leading, max(40, insets.leading + 16)).padding(.trailing, max(40, insets.trailing + 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, max(proxy.size.height * 0.07, insets.bottom + 12) + up)
        }
    }
}
