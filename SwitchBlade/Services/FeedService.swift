import Foundation
import SwiftData
import Observation

/// Fills the two home-screen feeds.
///
/// Neither one costs an AI call. Words are each dictionary's own published Word
/// of the Day, fetched once per source per day. The Learn feed is a fixed set of
/// articles pulled live from Wikipedia and filtered by readership.
@MainActor
@Observable
final class FeedService {
    static let shared = FeedService()

    /// The Learn feed holds exactly this many articles. Refreshing replaces
    /// them rather than growing the list — there is no endless scroll.
    static let articleCount = 20

    private(set) var isLoadingWords = false
    private(set) var isLoadingArticles = false
    private(set) var wordError: String?
    private(set) var articleError: String?

    /// Guards against overlapping refreshes.
    private var articleFetchInProgress = false

    private init() {}

    // MARK: - Word of the day

    /// Ensures both dictionaries have contributed a word for today.
    /// Safe to call on every appearance: it returns immediately once the day's
    /// two entries are stored.
    func ensureWordsForToday(context: ModelContext) async {
        guard !isLoadingWords else { return }

        let today = Date.now.dayKey
        let descriptor = FetchDescriptor<WordOfTheDayItem>(
            predicate: #Predicate { $0.dayKey == today }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        let haveSources = Set(existing.map(\.source))

        let missing = WordSource.allCases.filter { !haveSources.contains($0.rawValue) }
        guard !missing.isEmpty else { return }

        isLoadingWords = true
        defer { isLoadingWords = false }

        var failures: [String] = []

        // Sequential: two small feed reads, and the sources are unrelated so a
        // failure on one shouldn't hold up the other.
        for source in missing {
            do {
                let entry = try await WordFeedService.shared.todaysWord(from: source)

                // Re-check in case a concurrent pass stored it.
                let slot = "\(entry.source)|\(today)"
                let duplicate = FetchDescriptor<WordOfTheDayItem>(
                    predicate: #Predicate { $0.slotKey == slot }
                )
                if let found = try? context.fetch(duplicate), !found.isEmpty { continue }

                context.insert(WordOfTheDayItem(
                    word: entry.word,
                    phonetic: entry.phonetic,
                    partOfSpeech: entry.partOfSpeech,
                    definition: entry.definition,
                    fullDefinition: entry.fullDefinition,
                    example: entry.example,
                    citation: entry.citation,
                    notes: entry.notes,
                    source: entry.source,
                    sourceURL: entry.sourceURL,
                    dayKey: today
                ))
            } catch {
                failures.append(source.rawValue)
            }
        }

        try? context.save()

        wordError = failures.isEmpty
            ? nil
            : "Couldn't reach \(failures.joined(separator: " and "))."
    }

    /// Repairs article text stored before the formula cleanup existed.
    ///
    /// Cheaper than making the user refetch, and it preserves favourites.
    func repairStoredArticles(context: ModelContext) {
        let stored = (try? context.fetch(FetchDescriptor<KnowledgeArticleItem>())) ?? []
        var repaired = 0

        // No pre-filter: `clean` decides for itself whether there's anything to
        // do, and it recognises half-repaired text that no longer carries a
        // LaTeX marker. Filtering on the marker here is what let the debris
        // survive a second pass.
        for article in stored {
            var changed = false

            let cleanedContent = MathCleaner.clean(article.content)
            if cleanedContent != article.content {
                article.content = cleanedContent
                changed = true
            }

            // Captions carry the same flattened formulae — a diagram captioned
            // "Graph of y = 1/x" arrives as one symbol per line plus the LaTeX,
            // exactly like body text.
            let cleanedCaptions = article.imageCaptions.map { caption in
                MathCleaner.clean(caption)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if cleanedCaptions != article.imageCaptions {
                article.imageCaptions = cleanedCaptions
                changed = true
            }

            if changed { repaired += 1 }
        }

        if repaired > 0 {
            try? context.save()
            NSLog("[SwitchBlade] Repaired formula text in %d stored article(s).", repaired)
        }
    }

    // MARK: - Knowledge feed

    /// Loads the initial set of articles if the feed is empty.
    func ensureArticles(context: ModelContext) async {
        let stored = (try? context.fetch(FetchDescriptor<KnowledgeArticleItem>())) ?? []
        guard stored.filter(\.isInFeed).count < Self.articleCount else { return }
        await loadArticles(context: context, replacing: false)
    }

    /// Fetches a fresh set. When `replacing` is true, unfavourited articles are
    /// cleared first so the feed turns over instead of accumulating.
    func loadArticles(context: ModelContext, replacing: Bool) async {
        guard !articleFetchInProgress else { return }
        articleFetchInProgress = true
        isLoadingArticles = true
        defer {
            articleFetchInProgress = false
            isLoadingArticles = false
        }

        if replacing {
            let stored = (try? context.fetch(FetchDescriptor<KnowledgeArticleItem>())) ?? []
            for article in stored {
                if article.isFavorite {
                    // Keep the record, but retire it from the feed so it isn't
                    // occupying one of the twenty slots.
                    article.isInFeed = false
                } else {
                    context.delete(article)
                }
            }
            try? context.save()
        }

        let stored = (try? context.fetch(FetchDescriptor<KnowledgeArticleItem>())) ?? []
        let needed = Self.articleCount - stored.filter(\.isInFeed).count
        guard needed > 0 else {
            articleError = nil
            return
        }

        // Exclude saved articles as well as current ones, so a piece you've
        // already kept doesn't come back around.
        let usedKeys = Set(stored.map(\.lookupKey))

        do {
            let articles = try await WikipediaService.shared.fetchArticles(
                count: needed,
                excluding: usedKeys
            )

            // Stagger the timestamps so the newest-first sort produces a stable
            // order rather than an arbitrary one.
            // Images are a second request per article, so they're fetched
            // concurrently rather than one after another.
            let images: [String: [WikipediaService.ArticleImage]] = await withTaskGroup(
                of: (String, [WikipediaService.ArticleImage]).self
            ) { group in
                for article in articles {
                    group.addTask {
                        (article.title, await WikipediaService.shared.images(for: article.title))
                    }
                }

                var collected: [String: [WikipediaService.ArticleImage]] = [:]
                for await (title, found) in group {
                    collected[title] = found
                }
                return collected
            }

            var offset = TimeInterval(0)
            for article in articles {
                offset -= 1
                let found = images[article.title] ?? []
                context.insert(KnowledgeArticleItem(
                    title: article.title,
                    category: article.category,
                    summary: article.summary,
                    content: article.extract,
                    articleURL: article.articleURL,
                    thumbnailURL: article.thumbnailURL,
                    imageURLs: found.map(\.url),
                    imageCaptions: found.map(\.caption),
                    fetchedAt: Date.now.addingTimeInterval(offset)
                ))
            }

            try? context.save()
            articleError = nil
        } catch {
            articleError = (error as? ServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearArticleError() {
        articleError = nil
    }
}
