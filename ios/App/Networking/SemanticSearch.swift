import SwiftUI
import TwilDiaryCore

/// Search by description ("a movie about the friendship between a boy and his dog"): Google's
/// Gemini reads the description and names the titles that fit, with a line on why; each one is
/// then found on TMDB, so only real titles are shown (and open their pages). Your key is kept in
/// this iPhone's Keychain; one built into the app (TWILDIARY_GEMINI_KEY, never in git) is the
/// fallback. Only the description is sent to Google.
@MainActor enum SemanticSearch {
    private static let account = "gemini.apiKey"
    /// Settings can pick another Gemini model; this one is quick and cheap.
    /// Google's current quick model; when Google retires one and names its successor, the app
    /// moves to that one by itself (and remembers it).
    static var model: String { UserDefaults.standard.string(forKey: "gemini.model") ?? "gemini-3.8-flash" }

    /// Several keys can be added (each Google account's free key has its own limit): every
    /// request starts with the next one in turn, and one that's used up or refused passes the
    /// request on to the next. Kept in the Keychain as a list; an older single key joins it.
    private static let listAccount = "gemini.apiKeys", rotationKey = "gemini.nextKey"
    /// Your own keys, in the order added.
    static var ownKeys: [String] {
        let store = KeychainProviderSecretStore()
        var list = ((try? store.readSecret(for: listAccount)) ?? nil)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        if let single = (try? store.readSecret(for: account)) ?? nil {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !list.contains(trimmed) { list.insert(trimmed, at: 0) }
        }
        return list
    }
    /// The keys requests use: your own, else the one built into this copy of the app.
    static var keys: [String] {
        let own = ownKeys
        if !own.isEmpty { return own }
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryGeminiKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("$(") else { return [] }
        return [value]
    }
    /// Any key at all (Gemini or Groq): AI search and CineMind can answer.
    static var key: String? { keys.first ?? groqKeys.first }
    static var hasOwnKey: Bool { !ownKeys.isEmpty }

    /// The AI services, each with its own keys.
    enum Service: String, CaseIterable, Identifiable, Sendable {
        case gemini, groq
        var id: String { rawValue }
        var name: String { self == .gemini ? "Gemini" : "Groq" }
        var keysPage: URL { URL(string: self == .gemini ? "https://aistudio.google.com/apikey" : "https://console.groq.com/keys")! }
        var keysPageName: String { self == .gemini ? "Google AI Studio" : "GroqCloud" }
    }
    static func ownKeys(_ service: Service) -> [String] { service == .gemini ? ownKeys : groqKeys }
    @discardableResult static func addKey(_ value: String, to service: Service) -> Bool {
        service == .gemini ? addKey(value) : addGroqKey(value)
    }
    @discardableResult static func removeKey(_ value: String, from service: Service) -> Bool {
        service == .gemini ? removeKey(value) : saveList(groqKeys.filter { $0 != value }, account: groqAccount)
    }

    // MARK: Groq

    /// Groq: free keys for fast open models, asked when every Gemini key and model has failed
    /// (or first, when there's no Gemini key). Its replies are turned into Gemini's shape, so
    /// search and CineMind read them the same way.
    private static let groqAccount = "groq.apiKeys", groqRotation = "groq.nextKey"
    /// Tried in turn; a model Groq has retired is skipped.
    static let groqModels = ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "openai/gpt-oss-20b"]
    static var groqKeys: [String] {
        ((try? KeychainProviderSecretStore().readSecret(for: groqAccount)) ?? nil)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }
    @discardableResult private static func saveList(_ list: [String], account: String) -> Bool {
        guard !list.isEmpty else { return KeychainProviderSecretStore().writeSecret(nil, for: account) }
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return KeychainProviderSecretStore().writeSecret(String(decoding: data, as: UTF8.self), for: account)
    }
    @discardableResult static func addGroqKey(_ value: String) -> Bool {
        let kept = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return false }
        var list = groqKeys
        if !list.contains(kept) { list.append(kept) }
        return saveList(list, account: groqAccount)
    }
    @discardableResult private static func saveKeys(_ list: [String]) -> Bool {
        let store = KeychainProviderSecretStore()
        _ = store.writeSecret(nil, for: account)
        guard !list.isEmpty else { return store.writeSecret(nil, for: listAccount) }
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return store.writeSecret(String(decoding: data, as: UTF8.self), for: listAccount)
    }
    /// Adds a key (a key already there isn't added twice).
    @discardableResult static func addKey(_ value: String) -> Bool {
        let kept = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return false }
        var list = ownKeys
        if !list.contains(kept) { list.append(kept) }
        return saveKeys(list)
    }
    @discardableResult static func removeKey(_ value: String) -> Bool { saveKeys(ownKeys.filter { $0 != value }) }
    /// nil removes every key; a value replaces them with that one.
    @discardableResult static func setKey(_ value: String?) -> Bool {
        let kept = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saveKeys(kept.isEmpty ? [] : [kept])
    }
    /// "••••AbC4": a key as the list shows it.
    static func masked(_ key: String) -> String { "••••" + String(key.suffix(4)) }

    struct Suggestion: Decodable, Sendable, Equatable {
        let title: String
        let year: Int?
        let type: String
        let why: String
    }
    /// A match found on TMDB, with Gemini's reason.
    struct Match: Identifiable, Sendable {
        let item: CatalogItem
        let why: String
        var id: String { item.key }
    }

    /// Gemini's picks for the description, best first, each checked on TMDB.
    static func search(_ description: String, store: DiaryStore) async throws -> [Match] {
        guard let key else { throw APIError.message("Add a Gemini or Groq key (Profile → APIs) to search by description.") }
        let suggestions = try await suggest(description, key: key)
        guard let token = TMDBDirect.token(store) else { throw APIError.message("Finding the titles needs TMDB, which isn’t set up.") }
        var matches: [Match] = [], seen = Set<String>()
        for suggestion in suggestions {
            guard !Task.isCancelled else { break }
            guard let item = await find(suggestion, token: token), seen.insert(item.key).inserted else { continue }
            matches.append(Match(item: item, why: suggestion.why))
        }
        return matches
    }

    /// The title on TMDB: by name and year first, then by name alone.
    static func find(_ suggestion: Suggestion, token: String) async -> CatalogItem? {
        let tv = suggestion.type.lowercased() != "movie"
        let path = tv ? "search/tv" : "search/movie"
        var queries: [[String: String]] = []
        if let year = suggestion.year { queries.append(["query": suggestion.title, tv ? "first_air_date_year" : "year": String(year)]) }
        queries.append(["query": suggestion.title])
        for query in queries {
            guard let found = try? await TMDBDirect.object(path, query: query, token: token),
                  let first = (found["results"] as? [[String: Any]])?.first,
                  let item = TMDBDirect.catalogItem(first, kind: tv ? .tv : .movie) else { continue }
            return item
        }
        return nil
    }

    /// Asks Gemini for up to ten titles, as JSON (the reply is held to a schema).
    static func suggest(_ description: String, key: String) async throws -> [Suggestion] {
        try decode(try await generate(body(description), key: key))
    }

    /// One Gemini answer (search and CineMind alike), asked as few times as possible: once per
    /// try, never repeated on the same key and model. The lighter model goes first (it's quicker
    /// and its free limit is much higher); if it fails, the same question goes to your next key,
    /// and only when every key has failed on it does it move to the next model. Each request
    /// starts with the next key in turn, so the keys share the load.
    static func generate(_ body: [String: Any], key: String, retried: Bool = false) async throws -> Data {
        let gemini = keys, groq = groqKeys
        guard !gemini.isEmpty || !groq.isEmpty else { throw APIError.message("Add a Gemini or Groq key on the APIs page.") }
        var geminiFailure: Error?
        if !gemini.isEmpty {
            do { return try await geminiAnswer(body, keys: gemini, retried: retried) }
            catch is CancellationError { throw CancellationError() }
            catch { geminiFailure = error }
        }
        guard !groq.isEmpty else { throw geminiFailure ?? APIError.message("Gemini didn’t answer.") }
        do { return try await groqAnswer(body, keys: groq) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard let geminiFailure else { throw error }
            throw APIError.message("Gemini: " + geminiFailure.localizedDescription + "\nGroq: " + error.localizedDescription)
        }
    }
    private static func geminiAnswer(_ body: [String: Any], keys list: [String], retried: Bool) async throws -> Data {
        let start = UserDefaults.standard.integer(forKey: rotationKey) % list.count
        UserDefaults.standard.set((start + 1) % list.count, forKey: rotationKey)
        var models = [fallbackModel]
        if model != fallbackModel { models.append(model) }
        var limited = 0, refused: [String] = [], busy = 0, slow = 0, other: String?
        for name in models {
            for step in 0..<list.count {
                let index = (start + step) % list.count
                do { return try await request(body, key: list[index], model: name, retried: retried) }
                catch GeminiKey.limited { limited += 1 }
                catch GeminiKey.refused(let detail) {
                    if !refused.contains(masked(list[index])) { refused.append(masked(list[index])) }
                    other = other ?? detail
                }
                catch GeminiBusy.status(let status, let detail) { busy += 1; if status != 503 { other = detail ?? "HTTP \(status)" } }
                catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) { slow += 1 }
            }
        }
        let tries = models.count * list.count
        if limited == tries {
            throw APIError.message(list.count > 1 ? "All \(list.count) Gemini keys have used their free limit for now. Try again in a minute." : "Gemini’s free limit is used up for now. Try again in a minute.")
        }
        if refused.count == list.count, limited == 0 {
            throw APIError.message(list.count > 1 ? "Gemini didn’t accept your keys" + (other.map { ": " + $0 } ?? ".") : "Gemini didn’t accept the key" + (other.map { ": " + $0 } ?? "."))
        }
        if slow > 0, busy == 0 { throw APIError.message("Gemini took too long to answer. Try again.") }
        throw APIError.message("Gemini is busy right now. Try again in a moment.")
    }
    /// A key's own problem: used up for now, or refused. The next key is tried.
    private enum GeminiKey: Error { case limited, refused(String?) }
    /// Google's lighter quick model, asked first: quick, and a much higher free limit.
    static let fallbackModel = "gemini-flash-lite-latest"
    private enum GeminiBusy: Error { case status(Int, String?) }
    private static func request(_ body: [String: Any], key: String, model name: String, retried: Bool) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent")!, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            if status == 400 || status == 401 || status == 403 { throw GeminiKey.refused(detail) }
            if status == 429 { throw GeminiKey.limited }
            // A retired model: Google's answer names the one to use ("…use models/gemini-3.8-flash…").
            if status == 404, !retried, name == model, let next = successor(in: detail ?? ""), next != model {
                UserDefaults.standard.set(next, forKey: "gemini.model")
                return try await Self.request(body, key: key, model: next, retried: true)
            }
            // Anything else (busy, a model this key can't use): the next key or model is tried.
            throw GeminiBusy.status(status, detail)
        }
        return data
    }
    /// The same question to Groq: each model in turn, each key in turn on it (starting with the
    /// next key), once each. Groq's OpenAI-style reply comes back in Gemini's shape.
    private static func groqAnswer(_ body: [String: Any], keys list: [String]) async throws -> Data {
        let start = UserDefaults.standard.integer(forKey: groqRotation) % list.count
        UserDefaults.standard.set((start + 1) % list.count, forKey: groqRotation)
        let (messages, schema, temperature) = groqMessages(body)
        var limited = 0, refused = 0, busy = 0, slow = 0, detail: String?
        for model in groqModels {
            var modelGone = false
            for step in 0..<list.count where !modelGone {
                let key = list[(start + step) % list.count]
                var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!, timeoutInterval: 45)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                var payload: [String: Any] = ["model": model, "messages": messages, "temperature": temperature]
                if schema != nil { payload["response_format"] = ["type": "json_object"] }
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let data: Data, response: URLResponse
                do { (data, response) = try await URLSession.shared.data(for: request) }
                catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) { slow += 1; continue }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (200..<300).contains(status),
                   let text = ((root?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
                    return geminiShaped(groqText(text, schema: schema))
                }
                let error = root?["error"] as? [String: Any]
                let message = error?["message"] as? String, code = (error?["code"] as? String) ?? ""
                detail = message ?? detail
                switch status {
                case 401, 403: refused += 1
                case 429: limited += 1
                case 404: modelGone = true
                case 400 where code.contains("model") || (message ?? "").lowercased().contains("model"): modelGone = true
                default: busy += 1
                }
            }
        }
        if limited > 0, refused == 0, busy == 0, slow == 0 {
            throw APIError.message(list.count > 1 ? "All \(list.count) Groq keys have reached their limit for now." : "Groq’s free limit is used up for now.")
        }
        if refused > 0, limited == 0, busy == 0 { throw APIError.message("Groq didn’t accept the key" + (detail.map { ": " + $0 } ?? ".")) }
        if slow > 0, busy == 0 { throw APIError.message("Groq took too long to answer.") }
        throw APIError.message("Groq couldn’t answer" + (detail.map { ": " + $0 } ?? "."))
    }
    /// Gemini's request as Groq's chat messages: the system text (with the reply's JSON shape
    /// spelled out, as Groq's JSON mode has no schema), then the conversation.
    nonisolated static func groqMessages(_ body: [String: Any]) -> (messages: [[String: String]], schema: [String: Any]?, temperature: Double) {
        func text(_ parts: Any?) -> String {
            ((parts as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        var system = text((body["systemInstruction"] as? [String: Any])?["parts"])
        let config = body["generationConfig"] as? [String: Any]
        let schema = config?["responseSchema"] as? [String: Any]
        if let schema, let shape = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            let wrapped = (schema["type"] as? String) == "ARRAY"
            system += "\n\nReply with JSON only, no other text. " + (wrapped ? "Reply with an object {\"items\": [...]} whose items list follows this schema: " : "The object follows this schema: ")
                + String(decoding: shape, as: UTF8.self) + " (OBJECT, ARRAY, STRING and INTEGER are JSON types; every required field must be present.)"
        }
        var messages: [[String: String]] = system.isEmpty ? [] : [["role": "system", "content": system]]
        for turn in (body["contents"] as? [[String: Any]]) ?? [] {
            let role = (turn["role"] as? String) == "model" ? "assistant" : "user"
            messages.append(["role": role, "content": text(turn["parts"])])
        }
        return (messages, schema, (config?["temperature"] as? Double) ?? 0.6)
    }
    /// Groq's reply text, unwrapped from {"items": [...]} when the answer is a list.
    nonisolated static func groqText(_ text: String, schema: [String: Any]?) -> String {
        guard (schema?["type"] as? String) == "ARRAY", let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return text }
        let list = object["items"] ?? object.values.first { $0 is [Any] }
        guard let list, let unwrapped = try? JSONSerialization.data(withJSONObject: list) else { return text }
        return String(decoding: unwrapped, as: UTF8.self)
    }
    /// A text answer in Gemini's reply shape.
    nonisolated static func geminiShaped(_ text: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])) ?? Data()
    }
    /// The text of Gemini's first answer.
    nonisolated static func answerText(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = (((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) else {
            throw APIError.message("Gemini sent no answer. Try asking another way.")
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    static func body(_ description: String) -> [String: Any] {
        let instruction = """
        You are a film and TV expert helping someone find something to watch. They describe a movie, \
        show or anime: its plot, characters, theme, mood, or a half-remembered scene. Reply with up to \
        10 real, existing titles that best match the description, best match first. Use each title's \
        original English name as TMDB lists it, and its first release year. type is "movie" or "tv" \
        (anime series are "tv"). why is one short sentence (at most 15 words) saying how it matches. \
        Never invent a title; fewer good matches beat more weak ones.
        """
        let schema: [String: Any] = [
            "type": "ARRAY",
            "items": [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"],
                    "year": ["type": "INTEGER"],
                    "type": ["type": "STRING", "enum": ["movie", "tv"]],
                    "why": ["type": "STRING"],
                ],
                "required": ["title", "type", "why"],
            ] as [String: Any],
        ]
        return [
            "systemInstruction": ["parts": [["text": instruction]]],
            "contents": [["role": "user", "parts": [["text": description]]]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.3] as [String: Any],
        ]
    }

    /// The model a "no longer available" answer points to (the last "models/…flash" it names).
    nonisolated static func successor(in message: String) -> String? {
        let pattern = #"models/(gemini-[A-Za-z0-9.\-]*flash[A-Za-z0-9.\-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        guard let last = regex.matches(in: message, range: range).last, let name = Range(last.range(at: 1), in: message) else { return nil }
        return String(message[name])
    }
    /// The suggestions in Gemini's reply (the JSON text of its first answer).
    nonisolated static func decode(_ data: Data) throws -> [Suggestion] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = (((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) else {
            throw APIError.message("Gemini sent no answer. Try describing it another way.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard let json = text.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([Suggestion].self, from: json)
    }
}

/// Search with the AI pill on: Gemini's matches above the usual results, each with why it fits.
struct SemanticSearchSection: View {
    /// The description you sent (Search pressed); empty until then.
    let query: String
    /// What's in the field now: sent at once when AI is turned on with text already there.
    var typed = ""
    @Environment(DiaryStore.self) private var store
    @State private var matches: [SemanticSearch.Match] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var addingKey = false
    @State private var hasKey = SemanticSearch.key != nil
    /// Sent when AI was turned on with text already typed.
    @State private var asked = ""
    private var description: String { query.isEmpty ? asked : query }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold))
                Text("FROM YOUR DESCRIPTION").font(.system(size: 13, weight: .bold)).tracking(1.2)
            }.foregroundStyle(HomeStyle.chipText).padding(.top, 6)
            if !hasKey {
                Button { addingKey = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search by description with Gemini").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Text("Add your free Gemini API key to find titles from a plot, theme or scene.").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                }.buttonStyle(.springPress).accessibilityIdentifier("semantic-add-key")
            } else if loading && matches.isEmpty {
                DiaryLoadingPlaceholder(height: 120, label: "Finding titles that match")
            } else if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if description.isEmpty {
                Text("Describe it, then press Search.").font(.system(size: 14)).foregroundStyle(.secondary)
            } else if matches.isEmpty && !loading {
                Text("Nothing matched that description. Try adding a detail.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ForEach(matches) { match in row(match) }
        }
        .onAppear { if query.isEmpty, asked.isEmpty { asked = typed } }
        .task(id: description + (hasKey ? "|key" : "")) { await run(description) }
        .sheet(isPresented: $addingKey, onDismiss: { hasKey = SemanticSearch.key != nil }) { GeminiKeySheet() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("semantic-results")
    }

    private func row(_ match: SemanticSearch.Match) -> some View {
        NavigationLink(value: match.item.route) {
            HStack(alignment: .top, spacing: 14) {
                Artwork(path: match.item.artwork, title: match.item.name, initialsOnly: false).frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(match.item.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).truncationMode(.tail)
                    Text(detail(match.item)).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    Text(match.why).font(.system(size: 14)).foregroundStyle(HomeStyle.soft).lineLimit(3).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(10).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline)).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityIdentifier("semantic-" + match.item.key)
    }
    private func detail(_ item: CatalogItem) -> String {
        [item.route.kind == .tv ? "Show" : "Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// One request per description you send (never while typing).
    private func run(_ text: String) async {
        guard hasKey, !store.isPreview, !text.isEmpty else { return }
        loading = true; failure = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let found = try await SemanticSearch.search(text, store: store)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { matches = found }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription; matches = [] }
        }
    }
}

/// Your Gemini API key: pasted once, kept in the Keychain.
struct GeminiKeySheet: View {
    var service: SemanticSearch.Service = .gemini
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var value = ""
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(service == .gemini ? "Get a free key at Google AI Studio and paste it here. Keys from other Google accounts share the load." : "Get a free key at GroqCloud and paste it here. Groq answers when Gemini can’t.")
                    .font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open " + service.keysPageName) { openURL(service.keysPage) }
                    .font(.system(size: 15, weight: .semibold))
                SecureField(service.name + " API key", text: $value).font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("gemini-key-field")
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Color(webHex: "#ff8a80")) }
                Spacer()
            }.padding(20)
                .navigationTitle(SemanticSearch.ownKeys(service).isEmpty ? service.name + " API key" : "Add a " + service.name + " key").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if SemanticSearch.addKey(value, to: service) { dismiss() } else { problem = "The key couldn’t be saved on this iPhone." }
                        }.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }.presentationDetents([.medium])
    }
}
