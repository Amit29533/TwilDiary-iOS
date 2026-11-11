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
    static var model: String { UserDefaults.standard.string(forKey: "gemini.model") ?? "gemini-2.5-flash" }

    static var key: String? {
        if let saved = (try? KeychainProviderSecretStore().readSecret(for: account)) ?? nil,
           !saved.trimmingCharacters(in: .whitespaces).isEmpty { return saved }
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryGeminiKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
    static var hasOwnKey: Bool { ((try? KeychainProviderSecretStore().readSecret(for: account)) ?? nil) != nil }
    @discardableResult static func setKey(_ value: String?) -> Bool {
        let kept = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeychainProviderSecretStore().writeSecret(kept?.isEmpty == false ? kept : nil, for: account)
    }

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
        guard let key else { throw APIError.message("Add your Gemini API key to search by description.") }
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
    private static func find(_ suggestion: Suggestion, token: String) async -> CatalogItem? {
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
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(description))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            if status == 400 || status == 401 || status == 403 { throw APIError.message("Gemini didn’t accept the key" + (detail.map { ": " + $0 } ?? ".")) }
            if status == 429 { throw APIError.message("Gemini’s free limit is used up for now. Try again in a minute.") }
            throw APIError.message("Gemini answered HTTP \(status)" + (detail.map { ": " + $0 } ?? "."))
        }
        return try decode(data)
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
    let query: String
    @Environment(DiaryStore.self) private var store
    @State private var matches: [SemanticSearch.Match] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var addingKey = false
    @State private var hasKey = SemanticSearch.key != nil
    @State private var searched = false

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
            } else if matches.isEmpty && !loading {
                Text("Nothing matched that description. Try adding a detail.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ForEach(matches) { match in row(match) }
        }
        .task(id: query + (hasKey ? "|key" : "")) { await run() }
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

    private func run() async {
        guard hasKey, !store.isPreview else { return }
        // Turning AI on searches what's already typed at once; after that, wait until typing
        // settles (a new letter cancels this and starts again).
        if searched { try? await Task.sleep(for: .milliseconds(900)) }
        guard !Task.isCancelled else { return }
        searched = true
        loading = true; failure = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let found = try await SemanticSearch.search(query, store: store)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { matches = found }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription; matches = [] }
        }
    }
}

/// Your Gemini API key: pasted once, kept in the Keychain.
struct GeminiKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var value = ""
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Get a free key at Google AI Studio, then paste it here. It stays in this iPhone’s Keychain; only your search descriptions are sent to Google.")
                    .font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Google AI Studio") { if let url = URL(string: "https://aistudio.google.com/apikey") { openURL(url) } }
                    .font(.system(size: 15, weight: .semibold))
                SecureField("Gemini API key", text: $value).font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("gemini-key-field")
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Color(webHex: "#ff8a80")) }
                if SemanticSearch.hasOwnKey {
                    Button("Remove saved key", role: .destructive) { SemanticSearch.setKey(nil); dismiss() }.font(.system(size: 14))
                }
                Spacer()
            }.padding(20)
                .navigationTitle("Gemini API key").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if SemanticSearch.setKey(value) { dismiss() } else { problem = "The key couldn’t be saved on this iPhone." }
                        }.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }.presentationDetents([.medium])
    }
}
