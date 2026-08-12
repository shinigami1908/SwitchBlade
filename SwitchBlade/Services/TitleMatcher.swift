import Foundation

/// Decides whether a provider's result is really the title that was asked for.
///
/// Shared by every keyless provider, because the failure it prevents is the
/// same everywhere and is worse than finding nothing: a plausible-looking entry
/// filed under the user's title, with someone else's description and score.
///
/// The subtlety is single-word queries. Measuring only how much of the *query*
/// the candidate covers gives "Cyberpunk" a perfect score against "VA-11 Hall-A:
/// Cyberpunk Bartender Action" — the one word matches, so recall is 1.0. The
/// score has to account for how much of the *candidate* is unaccounted for too.
enum TitleMatcher {
    /// 0…1, where 1 is an exact match after normalisation.
    static func score(candidate: String, query: String) -> Double {
        let candidateText = TitleParser.normalize(stripQualifier(candidate))
        let queryText = TitleParser.normalize(query)

        guard !candidateText.isEmpty, !queryText.isEmpty else { return 0 }

        if candidateText == queryText { return 1.0 }

        // Also compare without a leading article, so "The Matrix" and "Matrix"
        // are the same title.
        let bareCandidate = TitleParser.stripLeadingArticle(candidateText)
        let bareQuery = TitleParser.stripLeadingArticle(queryText)
        if bareCandidate == bareQuery { return 0.95 }

        if bareCandidate.hasPrefix(bareQuery) || bareQuery.hasPrefix(bareCandidate) {
            // "Hades" must not match "Hades II". A prefix match that adds an
            // installment number is a different work, and when the provider
            // returns only the sequel there is nothing better to rank against.
            if addsInstallmentNumber(candidate: bareCandidate, query: bareQuery) {
                return 0.5
            }
            return 0.9
        }

        let candidateTokens = Set(bareCandidate.split(separator: " ").map(String.init))
        let queryTokens = Set(bareQuery.split(separator: " ").map(String.init))
        guard !candidateTokens.isEmpty, !queryTokens.isEmpty else { return 0 }

        // A multi-word query appearing verbatim inside a longer title is a real
        // match — "Breath of the Wild" inside "The Legend of Zelda: Breath of
        // the Wild". Deliberately not applied to single-word queries, which is
        // exactly how "Cyberpunk" matched a bartending game.
        if queryTokens.count >= 2, bareCandidate.contains(bareQuery) {
            return 0.85
        }

        // Otherwise balance both directions: how much of the query was found,
        // and how much of the candidate is unexplained.
        let overlap = Double(candidateTokens.intersection(queryTokens).count)
        guard overlap > 0 else { return 0 }

        let recall = overlap / Double(queryTokens.count)
        let precision = overlap / Double(candidateTokens.count)
        return 2 * precision * recall / (precision + recall)
    }

    /// Picks the best candidate, or nothing when none clears the bar.
    static func best<T>(
        from candidates: [T],
        query: String,
        minimumScore: Double = 0.75,
        name: (T) -> String
    ) -> T? {
        var best: (item: T, score: Double)?

        for candidate in candidates {
            let value = score(candidate: name(candidate), query: query)
            if best == nil || value > best!.score {
                best = (candidate, value)
            }
        }

        guard let best, best.score >= minimumScore else { return nil }
        return best.item
    }

    /// True when the candidate is the query plus a sequel number.
    ///
    /// Only the tokens the candidate adds are considered, so "Uncharted 4"
    /// matching "Uncharted 4: A Thief's End" is unaffected — the query already
    /// carries the number.
    private static func addsInstallmentNumber(candidate: String, query: String) -> Bool {
        let candidateTokens = candidate.split(separator: " ").map(String.init)
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let added = candidateTokens.filter { !queryTokens.contains($0) }
        guard !added.isEmpty else { return false }

        // Spelled-out forms matter as much as digits: "Dune: Part Two" is not
        // "Dune".
        let installmentWords: Set<String> = [
            "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
            "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"
        ]

        return added.contains { token in
            // A bare number reads as an installment; a year-like number
            // ("Cyberpunk 2077") is part of the title.
            installmentWords.contains(token)
                || (Int(token).map { $0 >= 2 && $0 <= 99 } ?? false)
        }
    }

    /// Removes a trailing disambiguator like "(video game)" or "(2015 film)".
    private static func stripQualifier(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#,
            with: "",
            options: .regularExpression
        )
    }
}
