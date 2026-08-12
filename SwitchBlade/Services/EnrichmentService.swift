import Foundation
import SwiftData
import Observation

/// Turns a bare title into a filled-in entry.
///
/// Routing is by shelf kind, and it matters for cost: films and TV go to TMDB,
/// games to Steam, and only custom shelves reach Gemini for their core fields.
/// Vibe tags — the one thing no metadata API supplies — are gathered for the
/// whole batch in a single model call at the end.
///
/// SwiftData objects never cross an actor boundary. Each item is snapshotted
/// into a `Sendable` request before the network work starts and re-fetched by
/// id when results come back.
@MainActor
@Observable
final class EnrichmentService {
    static let shared = EnrichmentService()

    /// Number of items currently being processed, for progress UI.
    private(set) var inFlight: Int = 0
    private(set) var lastError: String?
    /// Set when vibe tagging fails. Kept apart from `lastError` because the
    /// entry itself enriched fine — only the tags are missing.
    private(set) var lastVibeError: String?

    var isWorking: Bool { inFlight > 0 }

    private init() {}

    // MARK: - Snapshots

    private struct Request: Sendable {
        let id: UUID
        let name: String
        let shelfKind: ShelfKind
        let shelfName: String
    }

    private struct Outcome: Sendable {
        let id: UUID
        var metadata: MetadataResult?
        var vibes: [String]?
        var error: String?
    }

    // MARK: - Entry points

    /// Enriches one item. Used when adding a single entry by hand.
    func enrich(_ item: ShelfItem, in context: ModelContext) {
        enrich([item], in: context)
    }

    /// Enriches many items with as few network and model calls as possible.
    func enrich(_ items: [ShelfItem], in context: ModelContext) {
        let pending = items.filter { $0.enrichment != .running }
        guard !pending.isEmpty else { return }

        let requests: [Request] = pending.compactMap { item in
            guard let shelf = item.shelf else { return nil }
            item.enrichment = .running
            item.enrichmentError = nil
            return Request(
                id: item.id,
                name: item.name,
                shelfKind: shelf.kind,
                shelfName: shelf.name
            )
        }

        guard !requests.isEmpty else { return }
        try? context.save()

        inFlight += requests.count

        Task {
            let outcomes = await process(requests)
            apply(outcomes, in: context)
            inFlight = max(0, inFlight - requests.count)
        }
    }

    /// Re-runs enrichment for an item the user asked to refresh, clearing the
    /// manual flag so provider data is allowed to overwrite.
    func forceRefresh(_ item: ShelfItem, in context: ModelContext) {
        item.enrichment = .pending
        enrich([item], in: context)
    }

    // MARK: - Vibe backfill

    /// Titles per model call. The prompt asks for one line each, so this is
    /// about how much output fits comfortably, not a rate limit.
    static let vibeChunkSize = 20

    /// Seconds between model calls. Gemini's free tier limits requests per
    /// minute, and going out in a burst is what left a bulk import untagged.
    private static let vibeCallSpacing = 4.5

    /// Entries still waiting for tags in a backfill, for progress UI.
    private(set) var vibesRemaining = 0

    /// Adds vibe tags to entries that already have everything else.
    ///
    /// Deliberately separate from `enrich`: these entries aren't failed. They
    /// have their metadata and merely missed their tags, which is what happens
    /// when the model rate-limits partway through a large import — so they're
    /// invisible to the ordinary retry path.
    func fillMissingVibes(for items: [ShelfItem], in context: ModelContext) {
        guard vibesRemaining == 0 else { return }

        let targets: [Request] = items.compactMap { item in
            guard item.vibesList.isEmpty, let shelf = item.shelf else { return nil }
            // The year goes into the name here because this request is only
            // ever used to build the prompt, and it stops the model tagging a
            // remake it happens to know better.
            let title = item.year.map { "\(item.name) (\($0))" } ?? item.name
            return Request(id: item.id, name: title, shelfKind: shelf.kind, shelfName: shelf.name)
        }

        guard !targets.isEmpty else { return }

        guard AppSettings.shared.key(for: .gemini) != nil else {
            lastVibeError = ServiceError.missingKey("Gemini").errorDescription
            return
        }

        lastVibeError = nil
        vibesRemaining = targets.count

        Task {
            defer { vibesRemaining = 0 }

            // One call per chunk, spaced out. The whole reason this action
            // exists is that the import hit the per-minute limit, so firing
            // everything at once would fail exactly the same way.
            for group in Dictionary(grouping: targets, by: \.shelfKind) {
                for chunk in group.value.chunked(into: Self.vibeChunkSize) {
                    do {
                        let results = try await GeminiService.shared.vibes(
                            for: chunk.map(\.name),
                            context: group.key.promptNoun
                        )
                        // Applied per chunk, so a failure halfway through keeps
                        // everything already tagged.
                        applyVibes(Self.align(results, to: chunk, key: \.title), in: context)
                    } catch {
                        let message = (error as? ServiceError)?.errorDescription
                            ?? error.localizedDescription
                        lastVibeError = message
                        NSLog("[SwitchBlade] Vibe backfill failed: %@", message)

                        // A spent budget or a bad key fails identically for
                        // every remaining chunk, so stop rather than grind
                        // through them all to reach the same message.
                        if case ServiceError.budgetExhausted = error { return }
                        if case ServiceError.missingKey = error { return }
                    }

                    vibesRemaining = max(0, vibesRemaining - chunk.count)
                    try? await Task.sleep(for: .seconds(Self.vibeCallSpacing))
                }
            }
        }
    }

    // MARK: - Runtime backfill

    /// Entries still waiting for a length, for progress UI.
    private(set) var runtimesRemaining = 0

    /// Fetches lengths for entries that were filled in before runtime was a
    /// field, so an existing library gains durations without being re-imported.
    ///
    /// Costs nothing against the AI budget — this is TMDB only — so it needs no
    /// pacing beyond the small concurrency window used everywhere else.
    func fillMissingRuntimes(for items: [ShelfItem], in context: ModelContext) {
        guard runtimesRemaining == 0 else { return }

        struct Target: Sendable {
            let id: UUID
            let tmdbID: String
            let kind: ShelfKind
        }

        let targets: [Target] = items.compactMap { item in
            guard item.runtimeMinutes == 0,
                  item.externalSource == "tmdb",
                  let externalID = item.externalID,
                  let kind = item.shelf?.kind,
                  kind == .movie || kind == .tv
            else { return nil }
            return Target(id: item.id, tmdbID: externalID, kind: kind)
        }

        guard !targets.isEmpty else { return }

        guard let tmdbKey = AppSettings.shared.key(for: .tmdb) else {
            lastError = ServiceError.missingKey("TMDB").errorDescription
            return
        }

        runtimesRemaining = targets.count

        Task {
            defer { runtimesRemaining = 0 }

            for chunk in targets.chunked(into: 4) {
                var found: [(UUID, Int)] = []

                await withTaskGroup(of: (UUID, Int).self) { group in
                    for target in chunk {
                        group.addTask {
                            let supplement = try? await TMDBService.shared.supplement(
                                for: target.tmdbID, kind: target.kind, apiKey: tmdbKey
                            )
                            return (target.id, supplement?.runtimeMinutes ?? 0)
                        }
                    }
                    for await result in group where result.1 > 0 {
                        found.append(result)
                    }
                }

                applyRuntimes(found, in: context)
                runtimesRemaining = max(0, runtimesRemaining - chunk.count)
            }
        }
    }

    private func applyRuntimes(_ pairs: [(UUID, Int)], in context: ModelContext) {
        guard !pairs.isEmpty else { return }

        let byID = Dictionary(uniqueKeysWithValues: pairs)
        guard let all = try? context.fetch(FetchDescriptor<ShelfItem>()) else { return }

        for item in all {
            guard let minutes = byID[item.id], minutes > 0 else { continue }
            item.runtimeMinutes = minutes
        }

        try? context.save()
    }

    private func applyVibes(_ pairs: [(Request, AIVibeResult)], in context: ModelContext) {
        guard !pairs.isEmpty else { return }

        let byID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
        guard let all = try? context.fetch(FetchDescriptor<ShelfItem>()) else { return }

        for item in all {
            guard let result = byID[item.id], !result.vibes.isEmpty else { continue }
            item.vibesList = Array(result.vibes.prefix(3))
        }

        try? context.save()
    }

    // MARK: - Pipeline

    private func process(_ requests: [Request]) async -> [Outcome] {
        let keys = await MainActor.run {
            (
                tmdb: AppSettings.shared.key(for: .tmdb),
                omdb: AppSettings.shared.key(for: .omdb),
                gemini: AppSettings.shared.key(for: .gemini)
            )
        }

        var outcomes: [UUID: Outcome] = [:]
        for request in requests {
            outcomes[request.id] = Outcome(id: request.id)
        }

        // --- Stage 1: structured metadata, per provider ---

        let structured = requests.filter { $0.shelfKind != .custom }
        for chunk in structured.chunked(into: 3) {
            await withTaskGroup(of: (UUID, Result<MetadataResult, Error>).self) { group in
                for request in chunk {
                    group.addTask {
                        do {
                            let result = try await Self.fetchMetadata(
                                for: request,
                                tmdbKey: keys.tmdb,
                                omdbKey: keys.omdb
                            )
                            return (request.id, .success(result))
                        } catch {
                            return (request.id, .failure(error))
                        }
                    }
                }

                for await (id, result) in group {
                    switch result {
                    case .success(let metadata):
                        outcomes[id]?.metadata = metadata
                    case .failure(let error):
                        outcomes[id]?.error = (error as? ServiceError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
            }
        }

        // --- Stage 2: custom shelves, batched through the model ---

        // A Wikipedia game lookup gives a solid description and year but no
        // genres or score, so it needs the same model pass custom shelves use.
        let needsSupplement = requests.filter { request in
            outcomes[request.id]?.metadata?.externalSource == "wikipedia"
        }

        let custom = requests.filter { $0.shelfKind == .custom } + needsSupplement
        if !custom.isEmpty, keys.gemini != nil {
            var isFirstCall = true

            for group in Dictionary(grouping: custom, by: \.shelfName) {
                for chunk in group.value.chunked(into: 15) {
                    // `AIBudget` refuses calls closer together than its minimum
                    // interval; wait it out rather than losing the batch.
                    if !isFirstCall { try? await Task.sleep(for: .seconds(2.5)) }
                    isFirstCall = false

                    do {
                        let results = try await GeminiService.shared.entries(
                            for: chunk.map(\.name),
                            shelfName: group.key
                        )
                        let matched = Self.align(results, to: chunk, key: \.title)

                        for (request, result) in matched {
                            // Where a provider already supplied a field, keep
                            // it — the model is filling gaps, not replacing
                            // sourced facts.
                            if var existing = outcomes[request.id]?.metadata {
                                if existing.genres.isEmpty {
                                    existing.genres = Array(result.genres.prefix(3))
                                }
                                if existing.rating == 0, let rating = result.rating {
                                    existing.rating = rating.rounded(toPlaces: 1)
                                    existing.ratingSource = "AI estimate"
                                }
                                if existing.year == nil { existing.year = result.year }
                                outcomes[request.id]?.metadata = existing
                                outcomes[request.id]?.vibes = result.vibes
                                continue
                            }

                            outcomes[request.id]?.metadata = MetadataResult(
                                title: request.name,
                                year: result.year,
                                overview: result.description,
                                genres: Array(result.genres.prefix(3)),
                                rating: (result.rating ?? 0).rounded(toPlaces: 1),
                                ratingSource: result.rating == nil ? "" : "AI estimate",
                                posterPath: nil,
                                externalID: nil,
                                externalSource: "gemini"
                            )
                            outcomes[request.id]?.vibes = result.vibes
                        }
                    } catch {
                        let message = (error as? ServiceError)?.errorDescription ?? error.localizedDescription
                        for request in chunk where outcomes[request.id]?.metadata == nil {
                            outcomes[request.id]?.error = message
                        }
                    }
                }
            }
        } else if !custom.isEmpty {
            for request in custom {
                outcomes[request.id]?.error = ServiceError.missingKey("Gemini").errorDescription
            }
        }

        // --- Stage 3: vibe tags for everything that got metadata ---
        //
        // One model call per 20 titles, regardless of how many were imported.

        var vibeError: String?

        if keys.gemini == nil {
            // Skipping silently made a missing key look like a model with
            // nothing to say. The entries are still fine without tags, so this
            // is reported rather than treated as a failure.
            vibeError = ServiceError.missingKey("Gemini").errorDescription
        } else {
            let needsVibes = requests.filter { request in
                guard let outcome = outcomes[request.id] else { return false }
                return outcome.metadata != nil && (outcome.vibes?.isEmpty ?? true)
            }

            var isFirstCall = custom.isEmpty

            for group in Dictionary(grouping: needsVibes, by: \.shelfKind) {
                for chunk in group.value.chunked(into: Self.vibeChunkSize) {
                    if !isFirstCall { try? await Task.sleep(for: .seconds(Self.vibeCallSpacing)) }
                    isFirstCall = false

                    // Send the resolved title so the model tags the same work
                    // the metadata provider matched.
                    let titles = chunk.map { request -> String in
                        let metadata = outcomes[request.id]?.metadata
                        guard let metadata else { return request.name }
                        if let year = metadata.year {
                            return "\(metadata.title) (\(year))"
                        }
                        return metadata.title
                    }

                    do {
                        let results = try await GeminiService.shared.vibes(
                            for: titles,
                            context: group.key.promptNoun
                        )
                        let matched = Self.align(results, to: chunk, key: \.title)
                        for (request, result) in matched {
                            outcomes[request.id]?.vibes = Array(result.vibes.prefix(3))
                        }
                    } catch {
                        // Swallowing this made a failed vibes call look like a
                        // model that simply had no tags to offer. The entry is
                        // still usable without them, so it isn't marked failed —
                        // but the reason has to reach the user.
                        vibeError = (error as? ServiceError)?.errorDescription
                            ?? error.localizedDescription
                        NSLog("[SwitchBlade] Vibe tags failed: %@", vibeError ?? "unknown")
                    }
                }
            }
        }

        if let vibeError {
            await MainActor.run { self.lastVibeError = vibeError }
        }

        return requests.compactMap { outcomes[$0.id] }
    }

    private static func fetchMetadata(
        for request: Request,
        tmdbKey: String?,
        omdbKey: String?
    ) async throws -> MetadataResult {
        switch request.shelfKind {
        case .movie, .tv:
            guard let tmdbKey else { throw ServiceError.missingKey("TMDB") }
            // The shelf decides which half of TMDB to search, so a film shelf
            // never picks up the series of the same name and vice versa.
            var result = try await TMDBService.shared.lookup(
                name: request.name,
                kind: request.shelfKind,
                apiKey: tmdbKey
            )

            // Runtime, cast, and the IMDb id arrive together in one follow-up
            // request. A failure there shouldn't cost the whole lookup — the
            // rest of the entry is already good.
            if let tmdbID = result.externalID,
               let supplement = try? await TMDBService.shared.supplement(
                for: tmdbID, kind: request.shelfKind, apiKey: tmdbKey
               ) {
                result.runtimeMinutes = supplement.runtimeMinutes
                if !supplement.cast.isEmpty { result.people = supplement.cast }

                // Upgrade TMDB's community score to the real IMDb rating when
                // the user has supplied an OMDb key.
                if let omdbKey, let imdbID = supplement.imdbID,
                   let imdbRating = try? await OMDbService.shared.rating(
                    forIMDbID: imdbID, apiKey: omdbKey
                   ) {
                    // IMDb leads because it's the score people quote, but
                    // TMDB's is kept alongside rather than discarded.
                    result.secondaryRating = result.rating
                    result.secondaryRatingSource = result.ratingSource
                    result.rating = imdbRating
                    result.ratingSource = "IMDb"
                }
            }

            return result

        case .game:
            // Steam for PC titles, Wikipedia for console exclusives. Neither
            // needs a key.
            return try await GameLookupService.shared.lookup(name: request.name)

        case .custom:
            throw ServiceError.missingKey("provider")
        }
    }

    // MARK: - Applying results

    private func apply(_ outcomes: [Outcome], in context: ModelContext) {
        guard !outcomes.isEmpty else { return }

        // Filtering in memory rather than with an `ids.contains` predicate:
        // collection membership doesn't translate reliably to the store, and a
        // personal library is small enough that the difference is immaterial.
        let ids = Set(outcomes.map(\.id))
        guard let all = try? context.fetch(FetchDescriptor<ShelfItem>()) else { return }
        let byID = Dictionary(
            uniqueKeysWithValues: all.filter { ids.contains($0.id) }.map { ($0.id, $0) }
        )

        var latestError: String?

        for outcome in outcomes {
            guard let item = byID[outcome.id] else { continue }

            if let metadata = outcome.metadata {
                // Keep the user's own title; providers often normalise
                // punctuation and subtitles in ways that are jarring in a list.
                item.year = metadata.year ?? item.year
                item.descriptionText = metadata.overview
                item.genre = metadata.genres.joined(separator: ", ")
                item.rating = metadata.rating
                item.ratingSource = metadata.ratingSource
                item.secondaryRating = metadata.secondaryRating
                item.secondaryRatingSource = metadata.secondaryRatingSource
                item.runtimeMinutes = metadata.runtimeMinutes
                item.posterPath = metadata.posterPath
                item.externalID = metadata.externalID
                item.externalSource = metadata.externalSource
                item.enrichment = .completed
                item.enrichmentError = nil
                item.lastEnrichedAt = .now
            } else {
                item.enrichment = .failed
                item.enrichmentError = outcome.error
                latestError = outcome.error
            }

            if let people = outcome.metadata?.people, !people.isEmpty {
                item.castList = people
            }

            if let vibes = outcome.vibes, !vibes.isEmpty {
                item.vibesList = vibes
            }
        }

        try? context.save()
        lastError = latestError
    }

    // MARK: - Matching helpers

    /// Pairs model output back to the requests that produced it.
    ///
    /// Order is the primary signal — the prompt asks for it — but titles are
    /// matched as a fallback, because a model that drops or reorders one entry
    /// would otherwise shift every result after it onto the wrong item.
    private static func align<R>(
        _ results: [R],
        to requests: [Request],
        key: KeyPath<R, String>
    ) -> [(Request, R)] {
        guard !results.isEmpty else { return [] }

        if results.count == requests.count {
            let orderMatches = zip(requests, results).allSatisfy { request, result in
                Self.titlesMatch(request.name, result[keyPath: key])
            }
            if orderMatches {
                return Array(zip(requests, results))
            }
        }

        var remaining = results
        var paired: [(Request, R)] = []

        for request in requests {
            guard let index = remaining.firstIndex(where: {
                Self.titlesMatch(request.name, $0[keyPath: key])
            }) else { continue }
            paired.append((request, remaining.remove(at: index)))
        }

        return paired
    }

    private static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = TitleParser.normalize(TitleParser.split(lhs).query)
        let b = TitleParser.normalize(TitleParser.split(rhs).query)
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
