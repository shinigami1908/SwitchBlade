import Foundation

/// Everything a provider can tell us about one entry. Sendable so it can cross
/// back to the main actor before touching SwiftData.
struct MetadataResult: Sendable {
    var title: String
    var year: Int?
    var overview: String
    var genres: [String]
    var rating: Double
    var ratingSource: String
    /// A second opinion, where two are available — IMDb and TMDB disagree often
    /// enough that showing both is more informative than picking one.
    var secondaryRating: Double = 0
    var secondaryRatingSource: String = ""
    var posterPath: String?
    var externalID: String?
    var externalSource: String
    /// Top-billed cast for a film or series; developer and publisher for a
    /// game. Empty when the provider has nothing.
    var people: [String] = []
    /// Film runtime, or a series' typical episode length, in minutes. Zero when
    /// the provider doesn't say.
    var runtimeMinutes: Int = 0
}

// MARK: - TMDB (films and television)

/// Searches the film and television endpoints separately.
///
/// The shelf decides which one to hit, so a title that exists as both a film
/// and a series resolves to whichever the user filed it under rather than
/// whichever TMDB ranks higher.
struct TMDBService: Sendable {
    static let shared = TMDBService()

    private let base = "https://api.themoviedb.org/3"

    // TMDB returns genre ids on search results; the id→name maps are small and
    // effectively frozen, so bundling them avoids two extra requests per lookup.
    private static let movieGenres: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western"
    ]

    private static let tvGenres: [Int: String] = [
        10759: "Action & Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 10762: "Kids", 9648: "Mystery",
        10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap",
        10767: "Talk", 10768: "War & Politics", 37: "Western"
    ]

    private struct SearchResponse: Decodable {
        let results: [Result]

        struct Result: Decodable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let overview: String?
            let releaseDate: String?
            let firstAirDate: String?
            let posterPath: String?
            let voteAverage: Double?
            let voteCount: Int?
            let popularity: Double?
            let genreIDs: [Int]?

            enum CodingKeys: String, CodingKey {
                case id
                case mediaType = "media_type"
                case title, name, overview
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
                case posterPath = "poster_path"
                case voteAverage = "vote_average"
                case voteCount = "vote_count"
                case popularity
                case genreIDs = "genre_ids"
            }
        }
    }

    private struct ExternalIDs: Decodable {
        let imdbID: String?
        enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
    }

    private struct Credits: Decodable {
        let cast: [Member]?

        struct Member: Decodable {
            let name: String?
            let order: Int?
        }
    }

    func lookup(name: String, kind: ShelfKind, apiKey: String) async throws -> MetadataResult {
        let (query, hintedYear) = TitleParser.split(name)
        let isTV = kind == .tv
        let path = isTV ? "tv" : "movie"

        // TMDB matches on whole words, so a dropped article or a stray
        // subtitle returns nothing rather than a near miss. Each fallback
        // widens the net a little before giving up.
        var attempts = [query]

        let withoutArticles = TitleParser.stripLeadingArticle(query)
        if withoutArticles != query { attempts.append(withoutArticles) }

        // "Dune: Part Two" → "Dune", for lists that record a subtitle the
        // provider files differently.
        if let colon = query.firstIndex(of: ":") {
            let head = String(query[query.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            if head.count >= 3 { attempts.append(head) }
        }

        var results: [SearchResponse.Result] = []

        for attempt in attempts {
            guard let url = URL.build("\(base)/search/\(path)", [
                "api_key": apiKey,
                "query": attempt,
                "include_adult": "false",
                "language": "en-US",
                "page": "1"
            ]) else { throw ServiceError.badURL }

            let response = try await HTTPClient.shared.get(url, as: SearchResponse.self)
            if !response.results.isEmpty {
                results = response.results
                break
            }
        }

        guard let best = pickBest(from: results, query: query, year: hintedYear) else {
            throw ServiceError.noResults(name)
        }

        let title = best.title ?? best.name ?? query
        let dateString = best.releaseDate ?? best.firstAirDate
        let year = dateString.flatMap { Int($0.prefix(4)) }
        let genreMap = isTV ? Self.tvGenres : Self.movieGenres
        let genres = (best.genreIDs ?? []).compactMap { genreMap[$0] }

        // TMDB's own score is used unless an OMDb key is present, in which case
        // the enrichment coordinator overwrites it with the real IMDb rating.
        var result = MetadataResult(
            title: title,
            year: year,
            overview: best.overview ?? "",
            genres: Array(genres.prefix(3)),
            rating: (best.voteAverage ?? 0).rounded(toPlaces: 1),
            ratingSource: "TMDB",
            posterPath: best.posterPath,
            externalID: String(best.id),
            externalSource: "tmdb"
        )

        if result.overview.isEmpty {
            result.overview = "No synopsis available from TMDB for this title."
        }

        return result
    }

    private struct Details: Decodable {
        let runtime: Int?
        let episodeRunTime: [Int]?
        let credits: Credits?
        let externalIDs: ExternalIDs?

        enum CodingKeys: String, CodingKey {
            case runtime
            case episodeRunTime = "episode_run_time"
            case credits
            case externalIDs = "external_ids"
        }
    }

    /// Runtime, cast, and the IMDb id — everything the search result doesn't
    /// carry.
    ///
    /// These were three separate requests. `append_to_response` folds them into
    /// one, which is worth having when a bulk import fires them for a couple of
    /// hundred titles at once.
    struct Supplement: Sendable {
        var runtimeMinutes = 0
        var cast: [String] = []
        var imdbID: String?
    }

    func supplement(
        for tmdbID: String,
        kind: ShelfKind,
        apiKey: String,
        castLimit: Int = 6
    ) async throws -> Supplement {
        let path = kind == .tv ? "tv" : "movie"
        guard let url = URL.build("\(base)/\(path)/\(tmdbID)", [
            "api_key": apiKey,
            "append_to_response": "credits,external_ids",
            "language": "en-US"
        ]) else { throw ServiceError.badURL }

        let details = try await HTTPClient.shared.get(url, as: Details.self)

        // A film reports one runtime; a series reports its typical episode
        // length, which is the more useful number when deciding what to start.
        let runtime = details.runtime ?? details.episodeRunTime?.first ?? 0

        let cast = (details.credits?.cast ?? [])
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .compactMap(\.name)
            .prefix(castLimit)
            .map { $0 }

        return Supplement(
            runtimeMinutes: max(0, runtime),
            cast: cast,
            imdbID: details.externalIDs?.imdbID
        )
    }

    /// Prefers an exact title match, then a year match, then popularity — TMDB's
    /// default ordering alone tends to surface remakes and documentaries.
    private func pickBest(
        from results: [SearchResponse.Result],
        query: String,
        year: Int?
    ) -> SearchResponse.Result? {
        guard !results.isEmpty else { return nil }

        let normalizedQuery = TitleParser.normalize(query)

        return results.max { lhs, rhs in
            score(lhs, normalizedQuery: normalizedQuery, year: year)
                < score(rhs, normalizedQuery: normalizedQuery, year: year)
        }
    }

    private func score(_ result: SearchResponse.Result, normalizedQuery: String, year: Int?) -> Double {
        var score = 0.0

        let title = TitleParser.normalize(result.title ?? result.name ?? "")
        if title == normalizedQuery {
            score += 1000
        } else if title.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(title) {
            score += 400
        } else {
            // "lord of the rings" should still match "The Lord of the Rings".
            let bareTitle = TitleParser.stripLeadingArticle(title)
            let bareQuery = TitleParser.stripLeadingArticle(normalizedQuery)
            if bareTitle == bareQuery {
                score += 900
            } else {
                let titleTokens = Set(bareTitle.split(separator: " "))
                let queryTokens = Set(bareQuery.split(separator: " "))
                if !queryTokens.isEmpty {
                    let overlap = Double(titleTokens.intersection(queryTokens).count)
                        / Double(queryTokens.count)
                    score += overlap * 350
                }
            }
        }

        if let year {
            let resultYear = (result.releaseDate ?? result.firstAirDate).flatMap { Int($0.prefix(4)) }
            if resultYear == year { score += 500 }
        }

        // Vote count separates a well-known title from an obscure same-name one.
        score += min(200, Double(result.voteCount ?? 0) / 25)
        score += min(100, result.popularity ?? 0)

        return score
    }
}

// MARK: - OMDb (authoritative IMDb ratings)

struct OMDbService: Sendable {
    static let shared = OMDbService()

    private struct Response: Decodable {
        let imdbRating: String?
        let imdbVotes: String?
        let response: String?

        enum CodingKeys: String, CodingKey {
            case imdbRating = "imdbRating"
            case imdbVotes = "imdbVotes"
            case response = "Response"
        }
    }

    /// Returns the IMDb score for an IMDb id, or nil when OMDb has no rating.
    func rating(forIMDbID imdbID: String, apiKey: String) async throws -> Double? {
        guard let url = URL.build("https://www.omdbapi.com/", [
            "apikey": apiKey,
            "i": imdbID
        ]) else { throw ServiceError.badURL }

        let response = try await HTTPClient.shared.get(url, as: Response.self)
        guard response.response == "True",
              let text = response.imdbRating,
              text != "N/A",
              let value = Double(text)
        else { return nil }

        return value
    }
}

// MARK: - Title parsing

enum TitleParser {
    /// Splits "Inception (2010)" or "Inception, 2010" into a query and a year
    /// hint, which sharpens provider matching considerably.
    static func split(_ raw: String) -> (query: String, year: Int?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a trailing bracketed or comma-separated four-digit year.
        let patterns = [
            #"\s*[\(\[](\d{4})[\)\]]\s*$"#,
            #"\s*[,–-]\s*(\d{4})\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let yearRange = Range(match.range(at: 1), in: text),
                  let year = Int(text[yearRange]),
                  (1880...2100).contains(year),
                  let fullRange = Range(match.range, in: text)
            else { continue }

            text.removeSubrange(fullRange)
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), year)
        }

        return (text, nil)
    }

    /// Drops a leading article so "The Matrix" and "Matrix" compare equal.
    static func stripLeadingArticle(_ text: String) -> String {
        for article in ["the ", "a ", "an "] where text.lowercased().hasPrefix(article) {
            return String(text.dropFirst(article.count))
        }
        return text
    }

    /// Case- and punctuation-insensitive form used for match scoring.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
