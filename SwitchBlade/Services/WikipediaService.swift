import Foundation

struct KnowledgeArticle: Sendable {
    var title: String
    var category: String
    var summary: String
    var extract: String
    var articleURL: String?
    var thumbnailURL: String?
    var monthlyViews: Int
}

/// Pulls the Learn feed from Wikipedia in real time.
///
/// The approach is two requests per batch: list the members of a curated topic
/// category, then fetch intros, short descriptions, thumbnails, and pageview
/// counts for a random sample of them. Pageviews are the quality filter —
/// category listings are full of stubs, and view count separates "Sisyphus"
/// (~136k views a month) from "Armenus" (~200). No API key, no account, and no
/// language model.
struct WikipediaService: Sendable {
    static let shared = WikipediaService()

    private let apiBase = "https://en.wikipedia.org/w/api.php"
    /// Wikimedia asks clients to identify themselves.
    private let userAgent = "SwitchBlade/1.0 (personal watchlist app)"

    /// A readable label paired with the Wikipedia category it draws from.
    struct Topic: Sendable {
        let label: String
        let category: String
    }

    /// Curated seeds. Chosen because their category listings are dense with
    /// genuinely interesting articles rather than administrative stubs.
    static let topics: [Topic] = [
        Topic(label: "Mythology", category: "Greek_mythology"),
        Topic(label: "Mythology", category: "Norse_mythology"),
        Topic(label: "Mythology", category: "Egyptian_mythology"),
        Topic(label: "Philosophy", category: "Philosophical_theories"),
        Topic(label: "Philosophy", category: "Thought_experiments"),
        Topic(label: "Philosophy", category: "Ethical_theories"),
        Topic(label: "Psychology", category: "Cognitive_biases"),
        Topic(label: "Psychology", category: "Psychological_theories"),
        Topic(label: "Physics", category: "Concepts_in_physics"),
        Topic(label: "Physics", category: "Astrophysics"),
        Topic(label: "Biology", category: "Evolutionary_biology"),
        Topic(label: "Biology", category: "Neuroscience"),
        Topic(label: "Engineering", category: "Inventions"),
        Topic(label: "Engineering", category: "Mechanical_engineering"),
        Topic(label: "History", category: "Ancient_Rome"),
        Topic(label: "History", category: "Historical_eras"),
        Topic(label: "Linguistics", category: "Etymology"),
        Topic(label: "Linguistics", category: "Historical_linguistics"),
        Topic(label: "Mathematics", category: "Mathematical_theorems"),
        Topic(label: "Mathematics", category: "Mathematical_paradoxes"),
        Topic(label: "Economics", category: "Economics_effects"),
        Topic(label: "Economics", category: "Game_theory"),
        Topic(label: "Astronomy", category: "Astronomical_objects"),
        Topic(label: "Chemistry", category: "Chemical_processes")
    ]

    /// Quality thresholds. A page needs both a decent readership and a
    /// substantial intro to make the feed.
    private let minimumMonthlyViews = 12_000
    private let minimumExtractLength = 500

    // MARK: - Public entry point

    /// Fetches up to `count` articles, skipping anything already stored.
    ///
    /// `excluding` carries the lowercased titles already in the feed, so a
    /// refresh brings genuinely new material rather than reshuffling.
    func fetchArticles(count: Int, excluding used: Set<String>) async throws -> [KnowledgeArticle] {
        var collected: [KnowledgeArticle] = []
        var seen = used
        // Shuffling the topic list keeps the feed from leaning on whichever
        // categories happen to be first.
        var remainingTopics = Self.topics.shuffled()

        // Without a per-topic cap one dense category fills most of the set —
        // twenty maths articles is not "learn something new about anything".
        let perTopicCap = max(2, count / 6)
        var takenPerLabel: [String: Int] = [:]

        // Two rounds. The first spreads the set across fields using the cap;
        // the second fills whatever's left without it, because running out of
        // topics with a half-empty feed is worse than a little repetition —
        // and the quality filter rejects enough that the first round often
        // falls short on its own.
        var round = 1

        while collected.count < count {
            if remainingTopics.isEmpty {
                guard round == 1 else { break }
                round = 2
                remainingTopics = Self.topics.shuffled()
            }

            let topic = remainingTopics.removeFirst()

            // Several categories share a label (Greek/Norse/Egyptian all map to
            // "Mythology"), so the cap is counted per label, not per category.
            if round == 1, takenPerLabel[topic.label, default: 0] >= perTopicCap {
                continue
            }

            guard let candidates = try? await categoryMembers(topic.category) else { continue }

            let sample = candidates
                .filter { !seen.contains($0.lowercased()) }
                .shuffled()
                .prefix(20)

            guard !sample.isEmpty else { continue }

            guard let details = try? await pageDetails(titles: Array(sample)) else { continue }

            let qualifying = details
                .filter { $0.monthlyViews >= minimumMonthlyViews }
                .filter { $0.extract.count >= minimumExtractLength }
                .sorted { $0.monthlyViews > $1.monthlyViews }

            for var article in qualifying {
                guard collected.count < count else { break }
                if round == 1, takenPerLabel[topic.label, default: 0] >= perTopicCap { break }
                guard seen.insert(article.title.lowercased()).inserted else { continue }

                article.category = topic.label
                collected.append(article)
                takenPerLabel[topic.label, default: 0] += 1
            }
        }

        // Interleave so the finished feed alternates fields rather than
        // arriving in topic-sized blocks.
        collected = Self.interleaveByCategory(collected)

        guard !collected.isEmpty else {
            throw ServiceError.noResults("new articles")
        }

        return collected
    }

    /// Round-robins across categories so consecutive cards come from different
    /// fields.
    private static func interleaveByCategory(_ articles: [KnowledgeArticle]) -> [KnowledgeArticle] {
        var buckets: [String: [KnowledgeArticle]] = [:]
        // Preserve first-seen category order so the result is deterministic for
        // a given fetch rather than reshuffling on every access.
        var order: [String] = []

        for article in articles {
            if buckets[article.category] == nil { order.append(article.category) }
            buckets[article.category, default: []].append(article)
        }

        var result: [KnowledgeArticle] = []
        while result.count < articles.count {
            for category in order {
                guard var bucket = buckets[category], !bucket.isEmpty else { continue }
                result.append(bucket.removeFirst())
                buckets[category] = bucket
            }
        }

        return result
    }

    // MARK: - Article images

    struct ArticleImage: Sendable {
        var url: String
        var caption: String
    }

    private struct MediaList: Decodable {
        let items: [Item]?

        struct Item: Decodable {
            let type: String?
            let showInGallery: Bool?
            let caption: Caption?
            let srcset: [Source]?

            struct Caption: Decodable { let text: String? }
            struct Source: Decodable { let src: String? }
        }
    }

    /// Images that appear in the article body, in the order they appear there.
    ///
    /// Returns an empty array rather than throwing — an article with no images
    /// is completely normal, and shouldn't look like a failure.
    func images(for title: String, limit: Int = 6) async -> [ArticleImage] {
        let slug = title
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title

        guard let url = URL(
            string: "https://en.wikipedia.org/api/rest_v1/page/media-list/\(slug)"
        ) else { return [] }

        guard let list = try? await HTTPClient.shared.get(
            url,
            as: MediaList.self,
            headers: ["User-Agent": userAgent]
        ) else { return [] }

        var results: [ArticleImage] = []

        for item in list.items ?? [] {
            guard results.count < limit else { break }
            guard item.type == "image", item.showInGallery != false else { continue }
            guard let src = item.srcset?.first?.src, !src.isEmpty else { continue }

            // Protocol-relative URLs need a scheme before URLSession will load
            // them.
            let absolute = src.hasPrefix("//") ? "https:\(src)" : src

            // Interface furniture that appears in the media list but isn't part
            // of the article's illustration.
            let noise = ["commons-logo", "wiki-letter", "edit-icon", "ambox",
                         "question_book", "wikiquote", "wikisource", "disambig",
                         "portal", "loudspeaker", "increase2", "decrease2"]
            let lowered = absolute.lowercased()
            if noise.contains(where: lowered.contains) { continue }

            // A caption is a single line by definition, so collapse the
            // paragraph breaks `tidy` leaves behind after removing a formula.
            let caption = Self.tidy(item.caption?.text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            results.append(ArticleImage(url: absolute, caption: caption))
        }

        return results
    }

    // MARK: - Category listing

    private struct CategoryResponse: Decodable {
        let query: Query?

        struct Query: Decodable {
            let categorymembers: [Member]?
        }

        struct Member: Decodable {
            let title: String
        }
    }

    private func categoryMembers(_ category: String) async throws -> [String] {
        guard let url = URL.build(apiBase, [
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "list": "categorymembers",
            "cmtitle": "Category:\(category)",
            // Namespace 0 is articles only — this is what keeps templates,
            // talk pages, and sub-categories out of the results.
            "cmnamespace": "0",
            "cmtype": "page",
            "cmlimit": "300"
        ]) else { throw ServiceError.badURL }

        let response = try await HTTPClient.shared.get(
            url,
            as: CategoryResponse.self,
            headers: ["User-Agent": userAgent]
        )

        let members = response.query?.categorymembers?.map(\.title) ?? []
        guard !members.isEmpty else { throw ServiceError.noResults(category) }
        return members
    }

    // MARK: - Page details

    private struct DetailResponse: Decodable {
        let query: Query?

        struct Query: Decodable {
            let pages: [Page]?
        }

        struct Page: Decodable {
            let title: String
            let extract: String?
            let description: String?
            let thumbnail: Thumbnail?
            let pageviews: [String: Int?]?
            let missing: Bool?
        }

        struct Thumbnail: Decodable {
            let source: String?
        }
    }

    /// One batched request for up to 20 titles: intro text, short description,
    /// thumbnail, and the daily pageview series.
    private func pageDetails(titles: [String]) async throws -> [KnowledgeArticle] {
        guard !titles.isEmpty else { return [] }

        guard let url = URL.build(apiBase, [
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "prop": "extracts|description|pageimages|pageviews",
            // Intro section only, as plain text rather than HTML.
            "exintro": "1",
            "explaintext": "1",
            "exlimit": "20",
            "piprop": "thumbnail",
            "pithumbsize": "640",
            "titles": titles.joined(separator: "|")
        ]) else { throw ServiceError.badURL }

        let response = try await HTTPClient.shared.get(
            url,
            as: DetailResponse.self,
            headers: ["User-Agent": userAgent]
        )

        return (response.query?.pages ?? []).compactMap { page -> KnowledgeArticle? in
            guard page.missing != true,
                  let extract = page.extract,
                  !extract.isEmpty
            else { return nil }

            // `pageviews` is a date-keyed series over the last ~60 days, with
            // nulls for days Wikimedia hasn't aggregated yet.
            let views = (page.pageviews ?? [:]).values.compactMap { $0 }.reduce(0, +)

            let slug = page.title
                .replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page.title

            return KnowledgeArticle(
                title: page.title,
                category: "",
                summary: (page.description ?? "").capitalizedFirst,
                extract: Self.tidy(extract),
                articleURL: "https://en.wikipedia.org/wiki/\(slug)",
                thumbnailURL: page.thumbnail?.source,
                monthlyViews: views
            )
        }
    }

    /// Wikipedia intros carry pronunciation guides and citation debris that
    /// read poorly on a card.
    private static func tidy(_ extract: String) -> String {
        var text = MathCleaner.clean(extract)

        // Parenthesised pronunciation blocks, e.g. "(/ˈsɪsɪfəs/; Ancient Greek: …)".
        text = text.replacingOccurrences(
            of: #"\s*\([^()]*(?:listen|pronunciation|IPA|/[^/()]+/)[^()]*\)"#,
            with: "",
            options: .regularExpression
        )

        // Bracketed IPA, e.g. Llanfairpwllgwyngyll's "[ˌɬan.vair.pʊɬ.ˌɡwɨ̞ŋ…]".
        // These are the one thing in the corpus that produces a single
        // unbreakable 80-character token, and they read as noise on a card.
        text = text.replacingOccurrences(
            of: #"\s*\[[^\]]*[ɬʊɨəˌˈɡʃʒθðŋɹɾʁχ][^\]]*\]"#,
            with: "",
            options: .regularExpression
        )

        // Leftover citation markers.
        text = text.replacingOccurrences(
            of: #"\[\d+\]"#,
            with: "",
            options: .regularExpression
        )

        // Soft hyphens are invisible but survive copy/paste and confuse search.
        text = text.replacingOccurrences(of: "\u{00AD}", with: "")

        return text
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
