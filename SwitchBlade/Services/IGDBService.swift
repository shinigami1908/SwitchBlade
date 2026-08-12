import Foundation

/// Game metadata from IGDB, the only free source that covers consoles properly.
///
/// Steam has artwork but is PC-only, and Wikipedia has console articles but no
/// cover art — game covers are non-free and aren't exposed through its API. For
/// a PS5 backlog that leaves every exclusive without a cover. IGDB has both,
/// across every platform.
///
/// The cost is setup: it authenticates through Twitch, so it needs a client id
/// and secret rather than a single key. That's why it's optional — without it
/// the Steam and Wikipedia path still works, just without covers for
/// exclusives.
actor IGDBService {
    static let shared = IGDBService()

    private let tokenEndpoint = "https://id.twitch.tv/oauth2/token"
    private let gamesEndpoint = "https://api.igdb.com/v4/games"
    private let imageBase = "https://images.igdb.com/igdb/image/upload"

    /// Cached app access token. IGDB tokens last ~60 days, so re-fetching per
    /// request would be wasteful and rate-limited.
    private var token: String?
    private var tokenExpiry: Date?

    // MARK: - Auth

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private func accessToken(clientID: String, clientSecret: String) async throws -> String {
        // Refresh a minute early rather than racing the expiry.
        if let token, let tokenExpiry, tokenExpiry.timeIntervalSinceNow > 60 {
            return token
        }

        guard let url = URL.build(tokenEndpoint, [
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "client_credentials"
        ]) else { throw ServiceError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let response: TokenResponse = try await HTTPClient.shared.send(
            request,
            as: TokenResponse.self
        )

        guard let accessToken = response.accessToken else {
            throw ServiceError.missingKey("IGDB (token exchange returned no token)")
        }

        token = accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
        return accessToken
    }

    // MARK: - Lookup

    private struct Game: Decodable {
        let name: String?
        let summary: String?
        let firstReleaseDate: Int?
        let totalRating: Double?
        let cover: Cover?
        let genres: [Named]?
        let involvedCompanies: [Involved]?

        enum CodingKeys: String, CodingKey {
            case name, summary, cover, genres
            case firstReleaseDate = "first_release_date"
            case totalRating = "total_rating"
            case involvedCompanies = "involved_companies"
        }

        struct Cover: Decodable { let imageId: String?
            enum CodingKeys: String, CodingKey { case imageId = "image_id" }
        }
        struct Named: Decodable { let name: String? }
        struct Involved: Decodable {
            let company: Named?
            let developer: Bool?
            let publisher: Bool?
        }
    }

    func lookup(name: String, clientID: String, clientSecret: String) async throws -> MetadataResult {
        let (query, hintedYear) = TitleParser.split(name)
        let bearer = try await accessToken(clientID: clientID, clientSecret: clientSecret)

        // IGDB uses Apicalypse: a plain-text body, not JSON. `search` is fuzzy,
        // so the result still goes through the shared match guard.
        let escaped = query.replacingOccurrences(of: "\"", with: "")
        let body = """
        search "\(escaped)"; \
        fields name,summary,first_release_date,total_rating,cover.image_id,\
        genres.name,involved_companies.company.name,involved_companies.developer,\
        involved_companies.publisher; \
        limit 10;
        """

        guard let url = URL(string: gamesEndpoint) else { throw ServiceError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let games = try await HTTPClient.shared.send(request, as: [Game].self)

        guard let best = TitleMatcher.best(
            from: games.filter { $0.name != nil },
            query: query,
            name: { $0.name ?? "" }
        ) else {
            throw ServiceError.noResults(name)
        }

        var year: Int?
        if let timestamp = best.firstReleaseDate {
            year = Calendar.current.component(
                .year,
                from: Date(timeIntervalSince1970: TimeInterval(timestamp))
            )
        }

        // IGDB's aggregate is 0–100.
        var rating = 0.0
        var ratingSource = ""
        if let total = best.totalRating, total > 0 {
            rating = (total / 10).rounded(toPlaces: 1)
            ratingSource = "IGDB"
        }

        // Developers first — they're what a player recognises.
        let involved = best.involvedCompanies ?? []
        let studios = (involved.filter { $0.developer == true }
                       + involved.filter { $0.publisher == true })
            .compactMap { $0.company?.name }
            .reduce(into: [String]()) { acc, name in
                if !acc.contains(name) { acc.append(name) }
            }

        return MetadataResult(
            title: best.name ?? query,
            year: year ?? hintedYear,
            overview: best.summary ?? "No description available from IGDB for this title.",
            genres: Array((best.genres ?? []).compactMap(\.name).prefix(3)),
            rating: rating,
            ratingSource: ratingSource,
            // t_cover_big is 264×374 — portrait, matching the film posters.
            posterPath: best.cover?.imageId.map { "\(imageBase)/t_cover_big/\($0).jpg" },
            externalID: nil,
            externalSource: "igdb",
            people: Array(studios.prefix(3))
        )
    }
}
