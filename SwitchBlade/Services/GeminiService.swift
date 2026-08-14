import Foundation

// MARK: - Response shapes

struct AIVibeResult: Codable, Sendable {
    let title: String
    let vibes: [String]
}

struct AISeriesResult: Codable, Sendable {
    let title: String
    let year: Int?
}

struct AIEntryResult: Codable, Sendable {
    let title: String
    let year: Int?
    let description: String
    let genres: [String]
    let vibes: [String]
    let rating: Double?
}

/// Which Gemini model the app calls.
///
/// All three have a free tier through AI Studio; they differ in how many
/// requests a day that tier allows and how good the answers are. Even the
/// tightest of them is far above what this app uses.
enum GeminiModel: String, CaseIterable, Identifiable, Sendable {
    case flash = "gemini-2.5-flash"
    case flashLite = "gemini-2.5-flash-lite"
    case pro = "gemini-2.5-pro"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flash: return "2.5 Flash"
        case .flashLite: return "2.5 Flash-Lite"
        case .pro: return "2.5 Pro"
        }
    }

    var blurb: String {
        switch self {
        case .flash:
            return "The balanced pick, and plenty for this app. Free tier allows a few hundred requests a day."
        case .flashLite:
            return "Fastest, with the most generous free quota. Slightly weaker on obscure titles."
        case .pro:
            return "Best answers on long-tail titles, but the tightest free quota — around a hundred requests a day."
        }
    }

    /// Gemini 2.5 models reason before answering. That earns nothing on short
    /// extraction work and costs latency and quota, so it's switched off where
    /// the API permits it — Pro has no zero setting.
    var disablesThinking: Bool {
        switch self {
        case .flash, .flashLite: return true
        case .pro: return false
        }
    }

    /// Ceiling for one response. Thinking tokens count against this, so Pro —
    /// which can't switch thinking off — needs the headroom to avoid returning
    /// a truncated batch.
    var maxOutputTokens: Int {
        disablesThinking ? 8192 : 24576
    }
}

/// The only component that talks to a language model.
///
/// Scope is deliberately small. Descriptions, genres, ratings, years, and
/// posters come from TMDB and Steam; words come from dictionary feeds; the Learn
/// feed comes from Wikipedia. Gemini is used for two things only:
///
///   1. vibe tags, which no metadata API provides — batched up to 20 titles
///      per call;
///   2. entries on custom shelves, where no structured provider exists —
///      batched 15 at a time.
///
/// Every entry point claims a slot from `AIBudget` first and returns a typed
/// error instead of calling out when the budget is spent.
struct GeminiService: Sendable {
    static let shared = GeminiService()

    private let base = "https://generativelanguage.googleapis.com/v1beta/models"

    // MARK: - Vibes

    /// Returns vibe tags for many titles in one request.
    func vibes(for titles: [String], context: String) async throws -> [AIVibeResult] {
        guard !titles.isEmpty else { return [] }

        let list = titles.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let prompt = """
        For each \(context) below, give two or three short atmospheric \
        descriptors that capture its mood — the feeling of watching or playing \
        it, not its plot or genre.

        Good descriptors: "Mind-bending", "Slow-burn", "Cosy", "Bleak", \
        "Wistful", "Frenetic", "Meditative", "Dread-soaked".
        Avoid genre words like "Action" or "Comedy", and avoid value judgements \
        like "Great" or "Overrated".

        Titles:
        \(list)

        Return one object per title, in the same order, echoing each title back.
        """

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "results": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "title": ["type": "STRING"],
                            "vibes": ["type": "ARRAY", "items": ["type": "STRING"]]
                        ],
                        "required": ["title", "vibes"],
                        // Gemini honours declaration order in its output; fixing
                        // it keeps responses stable across calls.
                        "propertyOrdering": ["title", "vibes"]
                    ]
                ]
            ],
            "required": ["results"]
        ]

        let wrapper = try await generate(prompt: prompt, schema: schema, as: VibeEnvelope.self)
        return wrapper.results
    }

    // MARK: - Series expansion

    /// Resolves a loose description of a set into concrete titles.
    ///
    /// The fallback for what TMDB's collections can't express. "Old Akshay
    /// Kumar comedies" isn't a collection, it's a category, and only a model
    /// will turn it into a list — but it costs a request from a very small
    /// daily allowance, so nothing calls this without the user asking.
    func seriesTitles(for request: String, context: String) async throws -> [AISeriesResult] {
        let prompt = """
        The user wants to add a set of \(context)s to a watchlist and has \
        described it as: "\(request)".

        List the specific titles they mean, in release order, with the release \
        year of each. Where the description points at one particular version of \
        a much-remade property — "old Spider-Man", "the Nolan Batman films" — \
        list only that version's titles.

        List only titles that actually exist. If the description is too vague \
        to resolve to specific works, return an empty list rather than guessing.
        Return at most 12.
        """

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "results": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "title": ["type": "STRING"],
                            "year": ["type": "INTEGER", "nullable": true]
                        ],
                        "required": ["title"],
                        "propertyOrdering": ["title", "year"]
                    ]
                ]
            ],
            "required": ["results"]
        ]

        let wrapper = try await generate(prompt: prompt, schema: schema, as: SeriesEnvelope.self)
        return wrapper.results
    }

    // MARK: - Custom shelf entries

    /// Full enrichment for shelves with no structured provider behind them.
    func entries(for titles: [String], shelfName: String) async throws -> [AIEntryResult] {
        guard !titles.isEmpty else { return [] }

        let list = titles.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let prompt = """
        The following are entries on a personal collection shelf named "\(shelfName)".
        For each one, provide factual reference details.

        \(list)

        For each entry:
        - description: two sentences on what it is and what it is about.
        - genres: up to three genre or category labels.
        - vibes: two or three short mood descriptors.
        - rating: its typical public reception on a 0–10 scale, or null if you \
        are not confident there is a well-known score. Do not invent precision.
        - year: year of release or publication, or null if unknown.

        If you do not recognise an entry, say so plainly in the description \
        rather than inventing details.
        """

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "results": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "title": ["type": "STRING"],
                            "year": ["type": "INTEGER", "nullable": true],
                            "description": ["type": "STRING"],
                            "genres": ["type": "ARRAY", "items": ["type": "STRING"]],
                            "vibes": ["type": "ARRAY", "items": ["type": "STRING"]],
                            "rating": ["type": "NUMBER", "nullable": true]
                        ],
                        "required": ["title", "description", "genres", "vibes"],
                        "propertyOrdering": [
                            "title", "year", "description", "genres", "vibes", "rating"
                        ]
                    ]
                ]
            ],
            "required": ["results"]
        ]

        let wrapper = try await generate(prompt: prompt, schema: schema, as: EntryEnvelope.self)
        return wrapper.results
    }

    // MARK: - Model discovery

    private struct ModelList: Decodable {
        let models: [Entry]?

        struct Entry: Decodable {
            let name: String?
            let supportedGenerationMethods: [String]?
        }
    }

    /// Model ids the key can actually call, newest-looking first.
    ///
    /// Google retires and renames model ids on its own schedule, and a stale id
    /// fails with a bare 404 that looks identical to a bad key. Asking the API
    /// what it supports is the only way to be right without a redeploy.
    func availableModels() async throws -> [String] {
        let apiKey = await MainActor.run { AppSettings.shared.key(for: .gemini) }
        guard let apiKey else { throw ServiceError.missingKey("Gemini") }
        guard let url = URL(string: base) else { throw ServiceError.badURL }

        let list = try await HTTPClient.shared.get(
            url,
            as: ModelList.self,
            headers: ["x-goog-api-key": apiKey]
        )

        let usable = (list.models ?? [])
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .compactMap { $0.name?.replacingOccurrences(of: "models/", with: "") }
            // Exclude specialised variants that can't do plain text generation.
            .filter { !$0.contains("embedding") && !$0.contains("aqa") && !$0.contains("imagen") }

        NSLog("[SwitchBlade] Gemini models available to this key: %@",
              usable.joined(separator: ", "))
        return usable
    }

    /// Picks a usable model when the configured one is gone.
    ///
    /// Prefers the same tier the user chose — a Flash user shouldn't silently
    /// land on Pro and burn a tighter quota.
    private func substitute(for model: GeminiModel, from available: [String]) -> String? {
        let preference: [String]
        switch model {
        case .flashLite: preference = ["flash-lite", "flash", "pro"]
        case .flash: preference = ["flash", "flash-lite", "pro"]
        case .pro: preference = ["pro", "flash", "flash-lite"]
        }

        for token in preference {
            let matches = available.filter { id in
                guard !id.contains("preview"), !id.contains("exp") else { return false }
                guard id.contains(token) else { return false }
                // "flash-lite" also contains "flash", so a plain flash request
                // would otherwise be answered with the lite model.
                if token == "flash" && id.contains("flash-lite") { return false }
                return true
            }
            // Ids sort so later versions come last.
            if let best = matches.sorted().last { return best }
        }

        return available.first
    }

    // MARK: - Transport

    private struct VibeEnvelope: Decodable, Sendable {
        let results: [AIVibeResult]
    }

    private struct SeriesEnvelope: Decodable, Sendable {
        let results: [AISeriesResult]
    }

    private struct EntryEnvelope: Decodable, Sendable {
        let results: [AIEntryResult]
    }

    /// Single funnel for model calls: budget claim, schema-constrained request,
    /// decode, usage accounting.
    private func generate<T: Decodable & Sendable>(
        prompt: String,
        schema: [String: Any],
        as type: T.Type,
        isRetry: Bool = false,
        isMinimal: Bool = false
    ) async throws -> T {
        let (apiKey, model, limit) = await MainActor.run {
            (
                AppSettings.shared.key(for: .gemini),
                AppSettings.shared.geminiModel,
                AIBudget.shared.dailyCallLimit
            )
        }

        guard let apiKey else { throw ServiceError.missingKey("Gemini") }

        let claimed = await MainActor.run { AIBudget.shared.claim() }
        guard claimed else { throw ServiceError.budgetExhausted(limit) }

        // A previously resolved substitute wins, so one 404 costs one discovery
        // call rather than one per request.
        let modelID = await MainActor.run { AppSettings.shared.resolvedGeminiModelID }
            ?? model.rawValue

        guard let url = URL(string: "\(base)/\(modelID):generateContent") else {
            await MainActor.run { AIBudget.shared.refund() }
            throw ServiceError.badURL
        }

        var generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": schema,
            // Low but not zero: vibe tags benefit from a little variety, and
            // the schema constrains the shape regardless.
            "temperature": 0.4,
            "maxOutputTokens": model.maxOutputTokens
        ]

        // Not every model accepts a zero thinking budget, and the rejection is
        // a generic INVALID_ARGUMENT that names no field. The retry below drops
        // this first.
        if model.disablesThinking && !isMinimal {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": generationConfig,
            // Descriptions of horror and war titles otherwise trip the default
            // thresholds. Raising the bar to "high" keeps genuinely harmful
            // output blocked without losing half a watchlist.
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"]
            ]
        ]

        do {
            let response: GenerateResponse = try await HTTPClient.shared.postJSON(
                url,
                body: body,
                as: GenerateResponse.self,
                // The key goes in a header rather than the query string so it
                // stays out of URL logs.
                headers: ["x-goog-api-key": apiKey]
            )

            if let usage = response.usageMetadata, let total = usage.totalTokenCount, total > 0 {
                await MainActor.run { AIBudget.shared.record(tokens: total) }
            }

            // A prompt rejected outright carries no candidates at all.
            if let block = response.promptFeedback?.blockReason {
                throw ServiceError.refused(block)
            }

            guard let candidate = response.candidates?.first else {
                throw ServiceError.decoding("Model returned no candidates.")
            }

            switch candidate.finishReason {
            case "MAX_TOKENS":
                throw ServiceError.decoding("Response hit the token ceiling before finishing.")
            case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST":
                throw ServiceError.refused(candidate.finishReason)
            case "RECITATION":
                throw ServiceError.decoding("Response was withheld as likely recitation.")
            default:
                break
            }

            guard let text = candidate.text else {
                throw ServiceError.decoding("Model returned no content.")
            }

            guard let data = text.data(using: .utf8) else {
                throw ServiceError.decoding("Model output was not valid UTF-8.")
            }

            return try HTTPClient.shared.decode(type, from: data)
        } catch let error as ServiceError {
            // A 404 means the model id is gone, not that the request was wrong.
            // Ask the API what it supports, remember the answer, and retry once.
            if case .http(let code, _) = error, code == 404, !isRetry {
                await MainActor.run { AIBudget.shared.refund() }

                if let available = try? await availableModels(),
                   let replacement = substitute(for: model, from: available),
                   replacement != modelID {
                    NSLog("[SwitchBlade] Model '%@' returned 404; switching to '%@'.",
                          modelID, replacement)
                    await MainActor.run {
                        AppSettings.shared.resolvedGeminiModelID = replacement
                    }
                    return try await generate(
                        prompt: prompt, schema: schema, as: type,
                        isRetry: true, isMinimal: isMinimal
                    )
                }

                NSLog("[SwitchBlade] Model '%@' returned 404 and no substitute was found.", modelID)
                throw error
            }

            // A 400 here is usually an optional tuning field the model doesn't
            // accept, not a broken prompt. Retry once with those stripped.
            if case .http(let code, _) = error, code == 400, !isMinimal {
                await MainActor.run { AIBudget.shared.refund() }
                NSLog("[SwitchBlade] Model '%@' rejected the request; retrying without tuning fields.",
                      modelID)
                return try await generate(
                    prompt: prompt, schema: schema, as: type,
                    isRetry: isRetry, isMinimal: true
                )
            }

            // Refund transport failures, but not decode failures or refusals —
            // those consumed provider quota.
            if case .http = error {
                await MainActor.run { AIBudget.shared.refund() }
            }
            throw error
        } catch {
            await MainActor.run { AIBudget.shared.refund() }
            throw error
        }
    }
}

// MARK: - generateContent envelope

private struct GenerateResponse: Decodable {
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
    let usageMetadata: Usage?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?

        struct Content: Decodable {
            let parts: [Part]?

            struct Part: Decodable {
                let text: String?
            }
        }

        /// Joins the parts — long JSON responses arrive split across several.
        var text: String? {
            let joined = (content?.parts ?? []).compactMap(\.text).joined()
            return joined.isEmpty ? nil : joined
        }
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    struct Usage: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
    }
}
