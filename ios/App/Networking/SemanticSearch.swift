import SwiftUI
import UIKit
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
    /// The keys requests use: your own, else the ones built into this copy of the app (several,
    /// separated by commas, taken in turn like your own).
    static var keys: [String] {
        let own = ownKeys
        if !own.isEmpty { return own }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TwilDiaryGeminiKey") as? String, !value.hasPrefix("$(") else { return [] }
        return builtInKeys(value)
    }
    static func builtInKeys(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { seen.insert($0).inserted }
    }
    /// Any key at all (Gemini, Groq or Requesty): AI search and CineMind can answer.
    static var key: String? { keys.first ?? groqRequestKeys.first ?? requestyRequestKeys.first }

    /// The AI services, each with its own keys.
    enum Service: String, CaseIterable, Identifiable, Sendable {
        case gemini, groq, requesty
        var id: String { rawValue }
        var name: String { switch self { case .gemini: "Gemini"; case .groq: "Groq"; case .requesty: "Requesty" } }
        var keysPage: URL {
            let address = switch self { case .gemini: "https://aistudio.google.com/apikey"; case .groq: "https://console.groq.com/keys"; case .requesty: "https://app.requesty.ai/api-keys" }
            return URL(string: address)!
        }
        var keysPageName: String { switch self { case .gemini: "Google AI Studio"; case .groq: "GroqCloud"; case .requesty: "Requesty" } }
        /// Where an OpenAI-style service's keys live in the Keychain, and its turn counter.
        var account: String { rawValue + ".apiKeys" }
        var rotation: String { rawValue + ".nextKey" }
    }
    static func ownKeys(_ service: Service) -> [String] {
        switch service { case .gemini: ownKeys; case .groq: groqKeys; case .requesty: requestyKeys }
    }
    @discardableResult static func addKey(_ value: String, to service: Service) -> Bool {
        forgetRests(forKey: value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard service != .gemini else { return addKey(value) }
        let kept = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return false }
        var list = ownKeys(service)
        if !list.contains(kept) { list.append(kept) }
        return saveList(list, account: service.account)
    }
    @discardableResult static func removeKey(_ value: String, from service: Service) -> Bool {
        service == .gemini ? removeKey(value) : saveList(ownKeys(service).filter { $0 != value }, account: service.account)
    }
    private static func list(_ account: String) -> [String] {
        ((try? KeychainProviderSecretStore().readSecret(for: account)) ?? nil)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    // MARK: Requesty

    /// Requesty: one key for many models through its gateway. Its free models need no card
    /// (a shared daily allowance), and a paid account can name any model or routing policy.
    /// Asked after Gemini and Groq.
    static var requestyKeys: [String] { list(Service.requesty.account) }
    /// The Requesty keys requests use: your own, else the ones built into this copy of the app.
    static var requestyRequestKeys: [String] {
        let own = requestyKeys
        if !own.isEmpty { return own }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TwilDiaryRequestyKey") as? String, !value.hasPrefix("$(") else { return [] }
        return builtInKeys(value)
    }
    /// Your choice of model or policy ("policy/…"), tried before the free ones.
    static var requestyModel: String? {
        get { UserDefaults.standard.string(forKey: "requesty.model").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "requesty.model") }
    }
    /// Requesty's free models, larger (more film knowledge) first.
    static let requestyFreeModels = ["google/gemma-4-31b-it", "nvidia/nemotron-3-super-120b-a12b", "nvidia/nemotron-3-ultra-550b-a55b"]

    // MARK: Groq

    /// Groq: free keys for fast open models, asked when every Gemini key and model has failed
    /// (or first, when there's no Gemini key). Its replies are turned into Gemini's shape, so
    /// search and CineMind read them the same way.
    /// Tried in turn; a model Groq has retired is skipped.
    static let groqModels = ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "openai/gpt-oss-20b"]
    static var groqKeys: [String] { list(Service.groq.account) }
    /// The Groq keys requests use: your own, else the ones built into this copy of the app.
    static var groqRequestKeys: [String] {
        let own = groqKeys
        if !own.isEmpty { return own }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TwilDiaryGroqKey") as? String, !value.hasPrefix("$(") else { return [] }
        return builtInKeys(value)
    }
    @discardableResult private static func saveList(_ list: [String], account: String) -> Bool {
        guard !list.isEmpty else { return KeychainProviderSecretStore().writeSecret(nil, for: account) }
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return KeychainProviderSecretStore().writeSecret(String(decoding: data, as: UTF8.self), for: account)
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

    // MARK: Routing

    /// One way to ask: a service, one of its keys, one of its models.
    struct Route: Hashable, Sendable {
        let service: Service
        let key: String
        let model: String
        /// Kept on the phone without the key itself (its last 8 characters tell keys apart).
        var id: String { service.rawValue + "|" + String(key.suffix(8)) + "|" + model }
    }
    /// Why a route failed, which decides how long it rests.
    enum Failure: Error {
        case limited(TimeInterval?, daily: Bool, String?)
        case refused(String?)
        case busy(String?)
        case slow
        case modelGone(String?)
    }

    /// Every route, best first: Gemini's lighter model on each key, then Gemini's model on each
    /// key, then Groq's and Requesty's models on theirs. Each service's keys start with the next
    /// one in turn, so they share the load.
    static func routes(advancing: Bool = false) -> [Route] {
        func turn(_ list: [String], _ counter: String) -> [String] {
            guard !list.isEmpty else { return [] }
            let start = UserDefaults.standard.integer(forKey: counter) % list.count
            if advancing { UserDefaults.standard.set((start + 1) % list.count, forKey: counter) }
            return Array(list[start...] + list[..<start])
        }
        let gemini = turn(keys, rotationKey), groq = turn(groqRequestKeys, Service.groq.rotation), requesty = turn(requestyRequestKeys, Service.requesty.rotation)
        var geminiModels = [fallbackModel]
        if model != fallbackModel { geminiModels.append(model) }
        let requestyModels = (requestyModel.map { [$0] } ?? []) + requestyFreeModels
        return geminiModels.flatMap { name in gemini.map { Route(service: .gemini, key: $0, model: name) } }
            + groqModels.flatMap { name in groq.map { Route(service: .groq, key: $0, model: name) } }
            + requestyModels.flatMap { name in requesty.map { Route(service: .requesty, key: $0, model: name) } }
    }

    // The routes resting after a failure, and until when (kept between launches).
    private static let restingKey = "ai.resting"
    private static var resting: [String: Date] {
        get {
            let saved = UserDefaults.standard.dictionary(forKey: restingKey) as? [String: Double] ?? [:]
            return saved.compactMapValues { stamp in stamp > Date.now.timeIntervalSince1970 ? Date(timeIntervalSince1970: stamp) : nil }
        }
        set { UserDefaults.standard.set(newValue.mapValues(\.timeIntervalSince1970), forKey: restingKey) }
    }
    private static var restReasons: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: restingKey + ".why") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: restingKey + ".why") }
    }
    private static func rest(_ route: Route, _ failure: Failure) {
        let seconds: TimeInterval, why: String
        switch failure {
        case .limited(let after, let daily, _):
            seconds = daily ? untilQuotaDay() : max(10, min(after ?? 60, 3_600)); why = daily ? "daily limit" : "limit"
        case .refused: seconds = 6 * 3_600; why = "key refused"
        case .busy, .slow: seconds = 20; why = "busy"
        case .modelGone: seconds = 7 * 86_400; why = "model retired"
        }
        resting[route.id] = Date.now.addingTimeInterval(seconds)
        restReasons[route.id] = why
    }
    /// Free daily limits start again at midnight Pacific time.
    private static func untilQuotaDay() -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let next = calendar.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? Date.now.addingTimeInterval(3_600)
        return next.timeIntervalSinceNow
    }
    /// A key you add starts fresh.
    static func forgetRests(forKey key: String) {
        let tail = "|" + String(key.suffix(8)) + "|"
        resting = resting.filter { !$0.key.contains(tail) }
    }

    /// A service as the APIs page shows it: how many of its routes can answer now, and when the
    /// first resting one is back (with why).
    struct Health: Sendable { let ready: Int; let total: Int; let back: Date?; let why: String? }
    static func health(_ service: Service) -> Health {
        let all = routes().filter { $0.service == service }
        let now = resting, reasons = restReasons
        let waiting = all.compactMap { route in now[route.id].map { (route, $0) } }
        let soonest = waiting.min { $0.1 < $1.1 }
        return Health(ready: all.count - waiting.count, total: all.count, back: soonest?.1, why: soonest.flatMap { reasons[$0.0.id] })
    }

    /// One answer for search and CineMind, from whichever service can give it now. Routes that
    /// are resting (a used-up limit until it resets, a busy service for a moment, a refused key
    /// for a few hours) are skipped, so the question goes straight to one that works; each route
    /// is asked at most once. With everything resting, the one back soonest is tried anyway.
    static func generate(_ body: [String: Any], key: String, retried: Bool = false) async throws -> Data {
        let all = routes(advancing: true)
        guard !all.isEmpty else { throw APIError.message("Add a Gemini, Groq or Requesty key on the APIs page.") }
        let now = resting
        var order = all.filter { now[$0.id] == nil }
        if order.isEmpty, let soonest = all.min(by: { (now[$0.id] ?? .distantPast) < (now[$1.id] ?? .distantPast) }) { order = [soonest] }
        var failures: [(Route, Failure)] = []
        for route in order {
            do {
                let data = try await attempt(route, body: body, retried: retried)
                var saved = resting; saved[route.id] = nil; resting = saved
                return data
            } catch is CancellationError { throw CancellationError() }
            catch let failure as Failure { rest(route, failure); failures.append((route, failure)) }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                rest(route, .slow); failures.append((route, .slow))
            }
        }
        throw APIError.message(summary(failures, all: all))
    }
    /// What to say when nothing answered.
    private static func summary(_ failures: [(Route, Failure)], all: [Route]) -> String {
        let back = resting.filter { id, _ in all.contains { $0.id == id } }.values.min()
        let when = back.map { " Back " + ($0.timeIntervalSinceNow < 90 ? "in a moment." : "at " + $0.formatted(date: .omitted, time: .shortened) + ".") } ?? ""
        let reasons = failures.map(\.1)
        if !reasons.isEmpty, reasons.allSatisfy({ if case .limited = $0 { true } else { false } }) {
            return "Every AI key has used its free limit for now." + when
        }
        if !reasons.isEmpty, reasons.allSatisfy({ if case .refused = $0 { true } else { false } }) {
            let detail = reasons.compactMap { if case .refused(let text) = $0 { text } else { nil } }.first
            return "Your AI keys weren’t accepted" + (detail.map { ": " + $0 } ?? ".")
        }
        if failures.isEmpty { return "Every AI service is resting after a problem." + when }
        if reasons.allSatisfy({ if case .slow = $0 { true } else { false } }) { return "The AI took too long to answer. Try again." }
        return "The AI services are busy right now." + when
    }
    private static func attempt(_ route: Route, body: [String: Any], retried: Bool) async throws -> Data {
        switch route.service {
        case .gemini: return try await request(body, key: route.key, model: route.model, retried: retried)
        case .groq: return try await chat(body, route: route, url: "https://api.groq.com/openai/v1/chat/completions", jsonMode: true)
        case .requesty: return try await chat(body, route: route, url: "https://router.requesty.ai/v1/chat/completions", jsonMode: false)
        }
    }
    /// "Wait 33s" from a 429: Retry-After, or Gemini's RetryInfo; and whether it's a daily limit.
    nonisolated static func retryHint(_ data: Data, _ response: URLResponse?) -> (after: TimeInterval?, daily: Bool, message: String?) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let message = error?["message"] as? String
        var after = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        var daily = false
        for detail in (error?["details"] as? [[String: Any]]) ?? [] {
            if let delay = detail["retryDelay"] as? String, let seconds = TimeInterval(delay.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) { after = seconds }
            for violation in (detail["violations"] as? [[String: Any]]) ?? [] {
                if ((violation["quotaId"] as? String) ?? "").lowercased().contains("perday") { daily = true }
            }
        }
        let text = (message ?? "").lowercased()
        if text.contains("per day") || text.contains("perday") || text.contains("(rpd)") || text.contains("(tpd)") || text.contains("daily") { daily = true }
        return (after, daily, message)
    }

    /// Google's lighter quick model, asked first: quick, and a much higher free limit.
    static let fallbackModel = "gemini-flash-lite-latest"
    private static func request(_ body: [String: Any], key: String, model name: String, retried: Bool) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent")!, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let hint = retryHint(data, response), detail = hint.message
            if status == 429 { throw Failure.limited(hint.after, daily: hint.daily, detail) }
            if status == 401 || status == 403 || (status == 400 && (detail ?? "").lowercased().contains("key")) { throw Failure.refused(detail) }
            if status == 404 {
                // A retired model: Google's answer names the one to use ("…use models/gemini-3.8-flash…").
                if !retried, name == model, let next = successor(in: detail ?? ""), next != model {
                    UserDefaults.standard.set(next, forKey: "gemini.model")
                    return try await Self.request(body, key: key, model: next, retried: true)
                }
                throw Failure.modelGone(detail)
            }
            throw Failure.busy(detail ?? "HTTP \(status)")
        }
        return data
    }
    /// One question to an OpenAI-style service (Groq, Requesty) on one key and model; its reply
    /// comes back in Gemini's shape. `jsonMode`: the service holds the reply to JSON (otherwise
    /// the prompt asks for it and the reply is cleaned up).
    private static func chat(_ body: [String: Any], route: Route, url: String, jsonMode: Bool) async throws -> Data {
        let (messages, schema, temperature) = groqMessages(body)
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + route.key, forHTTPHeaderField: "Authorization")
        if route.service == .requesty { request.setValue("TwilDiary", forHTTPHeaderField: "X-Title") }
        var payload: [String: Any] = ["model": route.model, "messages": messages, "temperature": temperature]
        if schema != nil, jsonMode { payload["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(status),
           let text = ((root?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
            return geminiShaped(groqText(text, schema: schema))
        }
        let error = root?["error"] as? [String: Any]
        let message = error?["message"] as? String, code = (error?["code"] as? String) ?? ""
        switch status {
        case 401, 403: throw Failure.refused(message)
        case 429:
            let hint = retryHint(data, response)
            throw Failure.limited(hint.after, daily: hint.daily, message)
        case 404: throw Failure.modelGone(message)
        case 400 where code.contains("model") || (message ?? "").lowercased().contains("model"): throw Failure.modelGone(message)
        default: throw Failure.busy(message ?? "HTTP \(status)")
        }
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
    nonisolated static func groqText(_ raw: String, schema: [String: Any]?) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if schema != nil, let open = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let close = text.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close {
            text = String(text[open...close])
        }
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
    /// The last few descriptions' matches, for this app session: opening a title and coming back
    /// (or the list rebuilding the section) shows the same matches instead of asking again.
    @MainActor private static var answered: [String: [SemanticSearch.Match]] = [:]
    @MainActor private static var answeredOrder: [String] = []
    @MainActor private static func remember(_ matches: [SemanticSearch.Match], for text: String) {
        answered[text] = matches
        answeredOrder.removeAll { $0 == text }; answeredOrder.append(text)
        while answeredOrder.count > 8 { answered[answeredOrder.removeFirst()] = nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // AI looks one way everywhere (owner's request): CineMind's mark and its glow colours.
            HStack(spacing: 8) {
                CineMindMark(size: 20)
                Text("FROM YOUR DESCRIPTION").font(.system(size: 13, weight: .bold)).tracking(1.2).foregroundStyle(CineGlow.linear)
            }.padding(.top, 6)
            if !hasKey {
                Button { addingKey = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search by description with Gemini").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Text("Add your free Gemini API key to find titles from a plot, theme or scene.").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .cardSurface(16)
                        .cineGlow(RoundedRectangle(cornerRadius: 16), active: false)
                }.buttonStyle(.springPress).accessibilityIdentifier("semantic-add-key")
            } else if loading && matches.isEmpty {
                CineThinking(label: "Finding titles that match").padding(.vertical, 8)
            } else if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if description.isEmpty {
                Text("Describe it, then press Search.").font(.system(size: 14)).foregroundStyle(.secondary)
            } else if matches.isEmpty && !loading {
                Text("Nothing matched that description. Try adding a detail.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in row(match).cineReveal(order: index) }
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
                    HStack(spacing: 8) {
                        Text(detail(match.item)).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        // TMDB's score (or the diary's, for a title in your library), as on search's posters.
                        if let score = match.item.rating ?? store.libraryIdentity(match.item).flatMap({ store.title($0)?.communityScore }), score > 0 {
                            HStack(spacing: 4) { Image(systemName: "star.fill").font(.system(size: 11)); Text(String(format: "%.1f", score)) }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(themed: "#e7ca90"))
                                .accessibilityElement(children: .ignore).accessibilityLabel("Rated \(String(format: "%.1f", score))")
                        }
                    }
                    // Why it matched, in the assistant's voice: its sparkle in its colours.
                    Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(CineGlow.linear)) \(match.why)").foregroundStyle(HomeStyle.soft)
                        .font(.system(size: 14)).lineLimit(3).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(10).cardSurface(16)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline)).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityIdentifier("semantic-" + match.item.key)
    }
    private func detail(_ item: CatalogItem) -> String {
        [item.route.kind == .tv ? "Show" : "Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// One request per description you send (never while typing).
    private func run(_ text: String) async {
        guard hasKey, !store.isPreview, !text.isEmpty else { return }
        // Already answered (back from a title, or the section rebuilt): show those, no new request.
        if let known = Self.answered[text] { matches = known; failure = nil; loading = false; return }
        loading = true; failure = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let found = try await SemanticSearch.search(text, store: store)
            guard !Task.isCancelled else { return }
            Self.remember(found, for: text)
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
                HStack(spacing: 12) {
                    CineMindMark(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name).font(.system(size: 20, weight: .bold))
                        Text("Powers AI search and CineMind").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Text(service == .gemini ? "Get a free key at Google AI Studio and paste it here. Keys from other Google accounts share the load." : "Get a free key at GroqCloud and paste it here. Groq answers when Gemini can’t.")
                    .font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open " + service.keysPageName) { openURL(service.keysPage) }
                    .font(.system(size: 15, weight: .semibold))
                SecureField(service.name + " API key", text: $value).font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).cardSurface(12).cineGlow(RoundedRectangle(cornerRadius: 12), active: !value.isEmpty)
                    .accessibilityIdentifier("gemini-key-field")
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Color(uiColor: .systemRed)) }
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
        }.presentationDetents([.medium, .large])
    }
}
