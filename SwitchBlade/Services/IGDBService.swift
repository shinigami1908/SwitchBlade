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
        let id: Int?
        let name: String?
        let alternativeNames: [Named]?
        let summary: String?
        let firstReleaseDate: Int?
        let totalRating: Double?
        let cover: Cover?
        let genres: [Named]?
        let involvedCompanies: [Involved]?

        enum CodingKeys: String, CodingKey {
            case id, name, summary, cover, genres
            case alternativeNames = "alternative_names"
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
        // alternative_names is what makes a nickname resolvable: IGDB knows
        // "RDR" as an alternative name for Red Dead Redemption, where a title
        // comparison alone would never connect the two.
        let body = """
        search "\(escaped)"; \
        fields id,name,alternative_names.name,summary,first_release_date,\
        total_rating,cover.image_id,genres.name,involved_companies.company.name,\
        involved_companies.developer,involved_companies.publisher; \
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

        let candidates = games.filter { $0.name != nil }

        // An exact hit on a listed alternative name wins outright — that's the
        // provider telling us the nickname belongs to this game, which beats
        // any string similarity the matcher could compute.
        let needle = TitleParser.normalize(query)
        let byNickname = candidates.first { game in
            (game.alternativeNames ?? []).contains { alt in
                guard let alt = alt.name else { return false }
                return TitleParser.normalize(alt) == needle
            }
        }

        guard let best = byNickname ?? TitleMatcher.best(
            from: candidates,
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

        // Fetched here rather than in a second pass so one lookup returns a
        // complete entry. A game with no logged times just returns nil.
        var times: Playtime?
        if let gameID = best.id {
            times = try? await playtime(
                forGameID: gameID, clientID: clientID, clientSecret: clientSecret
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
            externalID: best.id.map(String.init),
            externalSource: "igdb",
            people: Array(studios.prefix(3)),
            playtimeMainMinutes: times?.main ?? 0,
            playtimeCompletionistMinutes: times?.completionist ?? 0
        )
    }

    // MARK: - Collections

    /// A game series as IGDB files it — "Red Dead" gathers Redemption, its
    /// sequel and the older Revolver.
    ///
    /// One request rather than TMDB's two: Apicalypse can nest the member games
    /// inside the collection query, so the years needed to tell similar series
    /// apart come back with the names.
    struct GameCollection: Identifiable, Sendable {
        let id: Int
        let name: String
        var parts: [Part]

        struct Part: Identifiable, Sendable {
            let id: Int
            let title: String
            let year: Int?
        }

        var yearRange: String? {
            let years = parts.compactMap(\.year).sorted()
            guard let first = years.first, let last = years.last else { return nil }
            return first == last ? "\(first)" : "\(first)–\(last)"
        }
    }

    private struct CollectionRow: Decodable {
        let id: Int
        let name: String?
        let games: [GameRow]?

        struct GameRow: Decodable {
            let id: Int
            let name: String?
            let firstReleaseDate: Int?

            enum CodingKeys: String, CodingKey {
                case id, name
                case firstReleaseDate = "first_release_date"
            }
        }
    }

    func collections(
        matching query: String,
        clientID: String,
        clientSecret: String,
        limit: Int = 4
    ) async throws -> [GameCollection] {
        let bearer = try await accessToken(clientID: clientID, clientSecret: clientSecret)
        guard let url = URL(string: "https://api.igdb.com/v4/collections") else {
            throw ServiceError.badURL
        }

        let escaped = query.replacingOccurrences(of: "\"", with: "")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        search "\(escaped)"; \
        fields name,games.name,games.first_release_date; \
        limit \(limit);
        """.utf8)

        let rows = try await HTTPClient.shared.send(request, as: [CollectionRow].self)

        return rows.compactMap { row -> GameCollection? in
            guard let name = row.name else { return nil }

            let parts = (row.games ?? []).compactMap { game -> GameCollection.Part? in
                guard let title = game.name, !title.isEmpty else { return nil }
                let year = game.firstReleaseDate.map {
                    Calendar.current.component(
                        .year, from: Date(timeIntervalSince1970: TimeInterval($0))
                    )
                }
                return GameCollection.Part(id: game.id, title: title, year: year)
            }
            // Release order, as anyone thinks about a series.
            .sorted { ($0.year ?? .max) < ($1.year ?? .max) }

            guard !parts.isEmpty else { return nil }
            return GameCollection(id: row.id, name: name, parts: parts)
        }
    }

    // MARK: - How long it takes

    private struct TimeToBeat: Decodable {
        let normally: Int?
        let completely: Int?
    }

    struct Playtime: Sendable {
        let main: Int
        let completionist: Int
    }

    /// Main-story and completionist times, in minutes.
    ///
    /// IGDB reports these in seconds, aggregated from player submissions, so a
    /// game nobody has logged simply has no row — hence the optional return
    /// rather than zeros that would look like a real answer.
    func playtime(
        forGameID gameID: Int,
        clientID: String,
        clientSecret: String
    ) async throws -> Playtime? {
        let bearer = try await accessToken(clientID: clientID, clientSecret: clientSecret)
        guard let url = URL(string: "https://api.igdb.com/v4/game_time_to_beats") else {
            throw ServiceError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("fields normally,completely; where game_id = \(gameID); limit 1;".utf8)

        let rows = try await HTTPClient.shared.send(request, as: [TimeToBeat].self)
        guard let row = rows.first else { return nil }

        let main = (row.normally ?? 0) / 60
        let full = (row.completely ?? 0) / 60
        guard main > 0 || full > 0 else { return nil }
        return Playtime(main: main, completionist: full)
    }
}
