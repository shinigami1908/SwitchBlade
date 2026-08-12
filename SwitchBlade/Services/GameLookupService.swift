import Foundation

/// Finds a game across platforms.
///
/// Steam is tried first: it needs no key and carries cover art and a Metacritic
/// score. It is PC-only though, so console exclusives — which is most of a
/// typical console backlog — miss entirely.
///
/// Wikipedia covers those. It has an article for essentially every notable
/// console release, with a factual description and the release year in its
/// short description. What it can't give is cover art: game covers are
/// non-free, so they live outside Commons and aren't exposed through the API.
/// Genres and a score come from the model afterwards, in the same batched call
/// that produces vibe tags.
struct GameLookupService: Sendable {
    static let shared = GameLookupService()

    private let apiBase = "https://en.wikipedia.org/w/api.php"
    private let userAgent = "SwitchBlade/1.0 (personal watchlist app)"

    func lookup(name: String) async throws -> MetadataResult {
        let credentials = await MainActor.run {
            (
                id: AppSettings.shared.key(for: .igdbClientID),
                secret: AppSettings.shared.key(for: .igdbClientSecret)
            )
        }

        // IGDB first when configured: it's the only source with cover art for
        // console exclusives.
        if let id = credentials.id, let secret = credentials.secret {
            do {
                return try await IGDBService.shared.lookup(
                    name: name, clientID: id, clientSecret: secret
                )
            } catch {
                NSLog("[SwitchBlade] IGDB lookup failed for '%@': %@",
                      name, (error as? ServiceError)?.errorDescription ?? "\(error)")
            }
        }

        // Steam covers PC and needs no key; it's the only other source with art.
        if let steam = try? await SteamService.shared.lookup(name: name) {
            return steam
        }

        return try await wikipediaLookup(name: name)
    }

    // MARK: - Wikipedia

    private struct SearchResponse: Decodable {
        let query: Query?

        struct Query: Decodable {
            let search: [Hit]?
        }

        struct Hit: Decodable {
            let title: String
        }
    }

    private struct PageResponse: Decodable {
        let query: Query?

        struct Query: Decodable {
            let pages: [Page]?
        }

        struct Page: Decodable {
            let title: String
            let extract: String?
            let description: String?
            let missing: Bool?
        }
    }

    private func wikipediaLookup(name: String) async throws -> MetadataResult {
        let (query, hintedYear) = TitleParser.split(name)

        // Scoping the search to video games keeps "Hades" off the Greek god.
        guard let searchURL = URL.build(apiBase, [
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "list": "search",
            "srsearch": "\(query) video game",
            "srlimit": "5"
        ]) else { throw ServiceError.badURL }

        let search = try await HTTPClient.shared.get(
            searchURL,
            as: SearchResponse.self,
            headers: ["User-Agent": userAgent]
        )

        let hits = search.query?.search?.map(\.title) ?? []
        guard let best = Self.pickBest(from: hits, query: query) else {
            throw ServiceError.noResults(name)
        }

        guard let pageURL = URL.build(apiBase, [
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "prop": "extracts|description",
            "exintro": "1",
            "explaintext": "1",
            "redirects": "1",
            "titles": best
        ]) else { throw ServiceError.badURL }

        let page = try await HTTPClient.shared.get(
            pageURL,
            as: PageResponse.self,
            headers: ["User-Agent": userAgent]
        )

        guard let entry = page.query?.pages?.first,
              entry.missing != true,
              let extract = entry.extract,
              !extract.isEmpty
        else { throw ServiceError.noResults(name) }

        // Wikipedia's short description for a game reads "2015 video game",
        // which is the cheapest reliable source of the release year.
        let year = Self.year(in: entry.description ?? "")
            ?? Self.year(in: String(extract.prefix(400)))
            ?? hintedYear

        return MetadataResult(
            title: entry.title,
            year: year,
            overview: Self.summarise(extract),
            // Left to the model, along with vibes, in the batched call.
            genres: [],
            rating: 0,
            ratingSource: "",
            posterPath: nil,
            externalID: nil,
            externalSource: "wikipedia"
        )
    }

    // MARK: - Helpers

    /// Requires a real title match — a loose one files the wrong game's
    /// description under the user's entry, which is worse than failing.
    private static func pickBest(from titles: [String], query: String) -> String? {
        TitleMatcher.best(from: titles, query: query, minimumScore: 0.7) { $0 }
    }

    private static func year(in text: String) -> Int? {
        guard let match = text.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[match])
    }

    /// Wikipedia intros run long; a card wants the first few sentences.
    private static func summarise(_ extract: String, sentences: Int = 3) -> String {
        let cleaned = MathCleaner.clean(extract)
            .replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\([^()]*(?:IPA|Japanese:|lit\.)[^()]*\)"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var result = ""
        var count = 0

        for character in cleaned {
            result.append(character)
            if ".!?".contains(character) {
                count += 1
                if count >= sentences { break }
            }
        }

        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
