import Foundation

/// Game metadata from Steam's public storefront.
///
/// This replaced RAWG, which went down (HTTP 522) and took every game lookup
/// with it. Steam needs no API key at all, which removes a signup step, and its
/// `library_600x900` artwork is portrait so game covers sit correctly next to
/// film posters.
///
/// The tradeoff is coverage: Steam is PC-only, so console exclusives aren't
/// there. Worse, its search is a loose fuzzy match — "the legend of zelda
/// breath of the wild" returns "Legend of the Master Baiter Origins" — so a
/// strict guard rejects weak matches and lets the caller fall back to the model
/// rather than filing confident nonsense.
struct SteamService: Sendable {
    static let shared = SteamService()

    private let searchBase = "https://steamcommunity.com/actions/SearchApps"
    private let detailBase = "https://store.steampowered.com/api/appdetails"
    private let artworkBase = "https://cdn.cloudflare.steamstatic.com/steam/apps"

    // MARK: - Search

    private struct SearchResult: Decodable {
        let appid: String
        let name: String
    }

    // MARK: - Details
    //
    // appdetails is keyed by app id and wraps everything in a success flag.

    private struct DetailEnvelope: Decodable {
        let success: Bool
        let data: Details?
    }

    private struct Details: Decodable {
        let name: String?
        let shortDescription: String?
        let metacritic: Metacritic?
        let genres: [Genre]?
        let releaseDate: ReleaseDate?
        let developers: [String]?
        let publishers: [String]?

        enum CodingKeys: String, CodingKey {
            case name
            case shortDescription = "short_description"
            case metacritic, genres
            case releaseDate = "release_date"
            case developers, publishers
        }

        struct Metacritic: Decodable { let score: Int? }
        struct Genre: Decodable { let description: String? }
        struct ReleaseDate: Decodable { let date: String? }
    }

    func lookup(name: String) async throws -> MetadataResult {
        let (query, hintedYear) = TitleParser.split(name)

        guard let searchURL = URL(
            string: "\(searchBase)/\(query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query)"
        ) else { throw ServiceError.badURL }

        let candidates = try await HTTPClient.shared.get(searchURL, as: [SearchResult].self)
        guard !candidates.isEmpty else { throw ServiceError.noResults(name) }

        guard let best = Self.pickBest(from: candidates, query: query) else {
            // A weak match is worse than none: it files a confidently wrong
            // description under the user's title.
            throw ServiceError.noResults(name)
        }

        guard let detailURL = URL.build(detailBase, [
            "appids": best.appid,
            "l": "english"
        ]) else { throw ServiceError.badURL }

        let envelope = try await HTTPClient.shared.get(
            detailURL,
            as: [String: DetailEnvelope].self
        )

        guard let entry = envelope[best.appid], entry.success, let details = entry.data else {
            throw ServiceError.noResults(name)
        }

        // Metacritic is on a 0–100 scale; the app shows everything out of 10.
        var rating = 0.0
        var ratingSource = ""
        if let score = details.metacritic?.score, score > 0 {
            rating = (Double(score) / 10).rounded(toPlaces: 1)
            ratingSource = "Metacritic"
        }

        let year = Self.year(from: details.releaseDate?.date) ?? hintedYear

        var overview = details.shortDescription ?? ""
        if overview.isEmpty {
            overview = "No description available from Steam for this title."
        }

        return MetadataResult(
            title: details.name ?? best.name,
            year: year,
            overview: overview,
            genres: Array((details.genres ?? []).compactMap(\.description).prefix(3)),
            rating: rating,
            ratingSource: ratingSource,
            // Portrait library art rather than the landscape header, so game
            // covers match the shape of film posters.
            posterPath: "\(artworkBase)/\(best.appid)/library_600x900.jpg",
            externalID: best.appid,
            externalSource: "steam",
            // Studio stands in for a cast on a game.
            people: Array(((details.developers ?? []) + (details.publishers ?? []))
                .reduce(into: [String]()) { acc, name in
                    if !acc.contains(name) { acc.append(name) }
                }
                .prefix(3))
        )
    }

    // MARK: - Matching

    /// Requires a genuine title match rather than trusting Steam's ranking.
    private static func pickBest(
        from candidates: [SearchResult],
        query: String
    ) -> SearchResult? {
        TitleMatcher.best(from: candidates, query: query) { $0.name }
    }

    private static func year(from date: String?) -> Int? {
        guard let date else { return nil }
        // Steam formats vary: "17 Sep, 2020", "2020", "Sep 2020".
        guard let match = date.range(of: #"\d{4}"#, options: .regularExpression) else {
            return nil
        }
        return Int(date[match])
    }
}
