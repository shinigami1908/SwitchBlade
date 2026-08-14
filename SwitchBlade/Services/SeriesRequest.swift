import Foundation

/// Decides whether typed text is asking for a whole series rather than one
/// title, and cleans it up for searching.
///
/// The bar for saying yes is deliberately high. A false positive here would
/// interrupt someone adding a single film, which is the common case and the
/// one that must stay frictionless — so nothing is ever expanded automatically.
/// This only decides whether to *offer*.
enum SeriesRequest {
    /// Words that only appear when someone means the whole set.
    private static let keywords = [
        "trilogy", "quadrilogy", "tetralogy", "saga", "franchise",
        "collection", "series", "complete", "entire", "boxset", "box set"
    ]

    /// Phrases that mean "all of them" but are two words.
    private static let phrases = [
        "all movies", "all films", "all parts", "all the movies", "all the films",
        "every movie", "every film"
    ]

    static func looksLikeSeries(_ text: String) -> Bool {
        let lower = text.lowercased()

        if keywords.contains(where: { lower.contains($0) }) { return true }
        if phrases.contains(where: { lower.contains($0) }) { return true }

        // "Spider-Man 1-3" or "Spider-Man 1 to 3".
        if lower.range(of: #"\b\d\s*(?:-|–|—|to)\s*\d\b"#, options: .regularExpression) != nil {
            return true
        }

        // Two or more standalone numbers: "spider man 1 2 3".
        //
        // A single number is deliberately not enough. "Spider-Man 2" and
        // "Dune: Part Two" are ordinary single entries, and treating them as
        // series requests is exactly the interference worth avoiding.
        let standaloneNumbers = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            // Four digits is a year — "Dune (2021)" is one film.
            .filter { $0.count < 3 }
        if standaloneNumbers.count >= 2 { return true }

        // A bare plural: "old spider man movies".
        if lower.range(of: #"\b(movies|films)\b"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// The phrase with the series words and numbering stripped, so it can be
    /// searched. "old spider man 1 2 3" becomes "spider man".
    static func searchTerm(_ text: String) -> String {
        var cleaned = text.lowercased()

        for phrase in phrases + keywords {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: " ")
        }

        for pattern in [
            #"\b\d\s*(?:-|–|—|to)\s*\d\b"#,   // ranges
            #"\b\d{1,2}\b"#,                   // loose numbering
            #"\b(old|new|original|first)\b"#,  // era hints the search can't use
            #"\b(movies|films|parts)\b"#
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: " ", options: .regularExpression
            )
        }

        let result = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If stripping removed everything, the original is a better query than
        // an empty string.
        return result.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }
}
