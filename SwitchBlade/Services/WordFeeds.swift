import Foundation

struct DictionaryEntry: Sendable {
    var word: String
    var phonetic: String
    var partOfSpeech: String
    /// Short form shown on the card — the primary sense only.
    var definition: String
    /// Every sense the feed carries. Falls back to `definition` when the
    /// source publishes only one.
    var fullDefinition: String
    /// The feed's own short usage example.
    var example: String
    /// A real-world quotation with its attribution, where the source gives one.
    var citation: String
    /// Etymology or usage notes — Merriam-Webster's "Did you know?" section.
    var notes: String
    var source: String
    var sourceURL: String?
}

/// The two dictionaries the home screen pulls from, one word each per day.
enum WordSource: String, CaseIterable, Sendable {
    case merriamWebster = "Merriam-Webster"
    case wordsmith = "Wordsmith"

    var feedURL: URL? {
        switch self {
        case .merriamWebster:
            return URL(string: "https://www.merriam-webster.com/wotd/feed/rss2")
        case .wordsmith:
            return URL(string: "https://wordsmith.org/awad/rss1.xml")
        }
    }

    /// Shown under the definition on the card.
    var attribution: String {
        switch self {
        case .merriamWebster: return "Merriam-Webster"
        case .wordsmith: return "Wordsmith · A.Word.A.Day"
        }
    }
}

/// Fetches each dictionary's own published Word of the Day.
///
/// These are the editors' picks — the same word Merriam-Webster and Wordsmith
/// put on their sites that morning — rather than a word drawn from a local
/// list. No API key, no account, and no language model involved.
struct WordFeedService: Sendable {
    static let shared = WordFeedService()

    func todaysWord(from source: WordSource) async throws -> DictionaryEntry {
        guard let url = source.feedURL else { throw ServiceError.badURL }

        var request = URLRequest(url: url)
        // Both feeds are cached aggressively by CDNs; a fresh fetch once a day
        // is what we want.
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("SwitchBlade/1.0", forHTTPHeaderField: "User-Agent")

        let data = try await HTTPClient.shared.data(for: request)

        guard let item = RSSParser.firstItem(in: data) else {
            throw ServiceError.decoding("Could not read the \(source.rawValue) feed.")
        }

        switch source {
        case .merriamWebster:
            return try parseMerriamWebster(item)
        case .wordsmith:
            return try parseWordsmith(item)
        }
    }

    // MARK: - Merriam-Webster
    //
    // The feed's <description> is a block of HTML in three labelled sections:
    //
    //   <strong>word</strong> &#149; \PRONUNCIATION\&nbsp; &#149; <em>noun</em><br />
    //   <p>The definition.</p>
    //   <p>// A short usage example.</p>
    //   <strong>Examples:</strong>    <p>"A quotation." — Author, Publication, date</p>
    //   <strong>Did you know?</strong> <p>Etymology and usage notes.</p>
    //
    // All of it is kept: the card shows the definition and short example, and
    // the detail view shows the citation and notes too.

    private func parseMerriamWebster(_ item: RSSItem) throws -> DictionaryEntry {
        let word = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else {
            throw ServiceError.decoding("Merriam-Webster feed had no headword.")
        }

        let html = item.description

        // The feed nests <p> elements inside its section paragraphs, which no
        // regex-based paragraph split survives: a non-greedy match on the outer
        // <p> runs to the *inner* </p> and merges two sections together.
        // Splitting on the section headings first sidesteps the malformed
        // nesting entirely.
        let (beforeExamples, citationBlock, notesBlock) = Self.splitSections(html)

        // The header line ends at the first <br />; the definition follows it.
        let breakRange = beforeExamples.range(
            of: #"<br\s*/?>"#,
            options: [.regularExpression, .caseInsensitive]
        )

        let header = breakRange.map { String(beforeExamples[beforeExamples.startIndex..<$0.lowerBound]) }
            ?? beforeExamples
        let body = breakRange.map { String(beforeExamples[$0.upperBound...]) } ?? beforeExamples

        // Pronunciation sits between backslashes on the header line.
        let phonetic = HTMLText.firstMatch(in: header, pattern: #"\\([^\\<>]{2,60})\\"#)
            .map { "\\\($0)\\" } ?? ""

        // Part of speech is the <em> at the end of the header line.
        let partOfSpeech = HTMLText.firstMatch(in: header, pattern: #"<em>([^<]{1,40})</em>"#) ?? ""

        // In the body, usage examples are the paragraphs Merriam-Webster
        // prefixes with "//"; ordinary paragraphs are senses of the definition.
        var senses: [String] = []
        var example = ""

        for paragraph in HTMLText.paragraphs(in: body) {
            if paragraph.hasPrefix("//") {
                if example.isEmpty {
                    example = String(paragraph.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            let lower = paragraph.lowercased()
            if lower.contains("word of the day for") { continue }
            // A link back to the dictionary entry, not part of the definition.
            if lower.hasPrefix("see the entry") { continue }
            if paragraph.count < 25 { continue }

            senses.append(paragraph)
        }

        guard let primary = senses.first else {
            throw ServiceError.decoding("Merriam-Webster entry for “\(word)” had no definition.")
        }

        return DictionaryEntry(
            word: word.capitalizedFirst,
            phonetic: phonetic,
            partOfSpeech: partOfSpeech,
            definition: primary.withTerminalPeriod,
            fullDefinition: senses.joined(separator: "\n\n"),
            example: example,
            citation: HTMLText.paragraphs(in: citationBlock)
                .filter { !$0.lowercased().hasPrefix("examples:") }
                .joined(separator: "\n\n"),
            notes: HTMLText.paragraphs(in: notesBlock)
                .filter { !$0.lowercased().hasPrefix("did you know") }
                .joined(separator: "\n\n"),
            source: WordSource.merriamWebster.rawValue,
            sourceURL: item.link
        )
    }

    /// Cuts the description at its two section headings, returning the
    /// definition block, the citation block, and the notes block.
    private static func splitSections(_ html: String) -> (String, String, String) {
        func cut(_ text: String, at pattern: String) -> (String, String) {
            guard let range = text.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) else { return (text, "") }
            return (
                String(text[text.startIndex..<range.lowerBound]),
                String(text[range.lowerBound...])
            )
        }

        let (beforeExamples, rest) = cut(html, at: #"<strong>\s*Examples:\s*</strong>"#)
        let (citation, notes) = cut(rest, at: #"<strong>\s*Did you know\?*\s*</strong>"#)
        return (beforeExamples, citation, notes)
    }

    // MARK: - Wordsmith
    //
    // Far simpler: <title> is the word and <description> is
    // "noun: 1. First sense. 2. Second sense." — the part of speech is the
    // prefix before the first colon.

    private func parseWordsmith(_ item: RSSItem) throws -> DictionaryEntry {
        let word = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = HTMLText.strip(item.description).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !word.isEmpty, !body.isEmpty else {
            throw ServiceError.decoding("Wordsmith feed entry was incomplete.")
        }

        var partOfSpeech = ""
        var definition = body

        // Only treat a leading colon as a part-of-speech marker when what
        // precedes it is short — definitions contain colons too.
        if let colon = body.firstIndex(of: ":") {
            let head = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if head.count <= 24, !head.contains(".") {
                partOfSpeech = head
                definition = String(body[body.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return DictionaryEntry(
            word: word.capitalizedFirst,
            phonetic: "",
            partOfSpeech: partOfSpeech,
            definition: Self.firstSense(of: definition).withTerminalPeriod,
            // Wordsmith's feed carries every sense in one string; the detail
            // view shows them all, split onto their own lines.
            fullDefinition: Self.splitSenses(definition),
            example: "",
            citation: "",
            notes: "",
            source: WordSource.wordsmith.rawValue,
            sourceURL: item.link
        )
    }

    /// Puts each numbered sense on its own line so the detail view can show the
    /// whole entry without it reading as one run-on paragraph.
    private static func splitSenses(_ definition: String) -> String {
        definition.replacingOccurrences(
            of: #"\s(?=\d\.\s)"#,
            with: "\n",
            options: .regularExpression
        )
        .replacingOccurrences(
            // A second part of speech starts a new block, e.g. "verb tr.: 1. …".
            of: #"\n?(?=\b(?:noun|verb|adjective|adverb|pronoun|interjection)\b[^:]{0,12}:)"#,
            with: "\n\n",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wordsmith packs every sense — and often a second part of speech — into
    /// one string: "1. A state of ecstasy. 2. (often Rapture) … verb tr.: 1. …".
    /// A card has room for the primary sense, and truncating mid-sentence reads
    /// far worse than stopping cleanly at the first one.
    private static func firstSense(of definition: String) -> String {
        let trimmed = definition.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("1.") else { return trimmed }

        let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // Cut at " 2. " — the start of the next numbered sense.
        guard let next = body.range(of: #"\s2\.\s"#, options: .regularExpression) else {
            return body
        }
        return String(body[body.startIndex..<next.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Minimal RSS reading

struct RSSItem: Sendable {
    var title: String = ""
    var link: String?
    var description: String = ""
}

/// Reads the first `<item>` out of an RSS 2.0 feed.
///
/// Both feeds publish today's word as the newest item, so there is no need for
/// a general-purpose feed reader — just the first entry.
enum RSSParser {
    static func firstItem(in data: Data) -> RSSItem? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.finished
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private var current: RSSItem?
        private var element = ""
        private var buffer = ""
        private(set) var finished: RSSItem?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            element = elementName
            buffer = ""
            if elementName == "item", finished == nil {
                current = RSSItem()
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            defer { buffer = "" }
            guard current != nil else { return }

            switch elementName {
            case "title":
                current?.title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            case "link":
                let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { current?.link = value }
            case "description":
                current?.description = buffer
            case "item":
                finished = current
                current = nil
                // Only the newest entry is needed; stop rather than walking
                // the rest of the feed.
                parser.abortParsing()
            default:
                break
            }
        }
    }
}

// MARK: - HTML helpers

enum HTMLText {
    /// Removes tags and decodes the handful of entities these feeds use.
    static func strip(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )

        let entities: [String: String] = [
            "&nbsp;": " ", "&#149;": "•", "&#8226;": "•",
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&#8217;": "’", "&#8220;": "“", "&#8221;": "”"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Any remaining numeric references.
        text = text.replacingOccurrences(
            of: "&#[0-9]+;",
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )

        // Tags are replaced with a space, so an inline <em> that ends a clause
        // leaves "fire ." or "The Week , 23 Jan." Pull punctuation back onto the
        // preceding word.
        text = text.replacingOccurrences(
            of: #" +([,.;:!?%)\]”’])"#,
            with: "$1",
            options: .regularExpression
        )

        // The same in reverse for opening brackets and quotes.
        text = text.replacingOccurrences(
            of: #"([(\[“‘]) +"#,
            with: "$1",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tag-stripped contents of each `<p>` block, in order.
    static func paragraphs(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<p[^>]*>(.*?)</p>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: html) else { return nil }
            let text = strip(String(html[captured]))
            return text.isEmpty ? nil : text
        }
    }

    /// First capture group of `pattern`, if it matches.
    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }

        let value = strip(String(text[captured]))
        return value.isEmpty ? nil : value
    }
}

// MARK: - String helpers

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }

    var withTerminalPeriod: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
