import Foundation
import SwiftData

// MARK: - Enumerations
//
// SwiftData stores these as raw strings so the schema stays stable if cases are
// added later. Each model exposes a typed computed accessor over the raw value.

/// What kind of thing a shelf holds. Drives which metadata provider is used.
enum ShelfKind: String, CaseIterable, Codable, Sendable {
    case movie
    case tv
    case game
    case custom

    var label: String {
        switch self {
        case .movie: return "Movies"
        case .tv: return "TV Shows"
        case .game: return "Games"
        case .custom: return "Custom"
        }
    }

    /// Noun used when asking the model for vibe tags.
    var promptNoun: String {
        switch self {
        case .movie: return "film"
        case .tv: return "television series"
        case .game: return "video game"
        case .custom: return "item"
        }
    }

    var defaultIcon: String {
        switch self {
        case .movie: return "film.stack.fill"
        case .tv: return "tv.fill"
        case .game: return "gamecontroller.fill"
        case .custom: return "books.vertical.fill"
        }
    }

    var itemSymbol: String {
        switch self {
        case .movie: return "film"
        case .tv: return "tv"
        case .game: return "gamecontroller"
        case .custom: return "square.stack"
        }
    }
}

/// Lifecycle of the automatic metadata lookup for an entry.
enum EnrichmentState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case manual   // user edited by hand; never overwrite automatically
}

// MARK: - Shelf

@Model
final class MediaShelf {
    #Index<MediaShelf>([\.sortIndex])

    @Attribute(.unique) var id: UUID
    var name: String
    var iconName: String
    var kindRaw: String
    var sortIndex: Int
    var createdAt: Date
    /// Set on the three shelves created at first launch so they can't be
    /// deleted out from under the rest of the app.
    var isBuiltIn: Bool

    @Relationship(deleteRule: .cascade, inverse: \ShelfItem.shelf)
    var items: [ShelfItem] = []

    var kind: ShelfKind {
        get { ShelfKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String,
        kind: ShelfKind,
        sortIndex: Int = 0,
        createdAt: Date = .now,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.kindRaw = kind.rawValue
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Shelf item
//
// Everything on a shelf is, by definition, still to be watched or played —
// there is no status field. Finishing something removes it.

@Model
final class ShelfItem {
    #Index<ShelfItem>([\.dateAdded], [\.name])

    @Attribute(.unique) var id: UUID
    var name: String
    var year: Int?
    var descriptionText: String
    var genre: String
    var vibesList: [String]
    /// Top-billed cast for film and TV; studio for a game. Defaulted so
    /// entries stored before this field existed still load.
    var castList: [String] = []
    /// Length in minutes: the film's runtime, or a series' typical episode
    /// length. Zero means the provider didn't say. Defaulted so entries stored
    /// before this field existed still load.
    var runtimeMinutes: Int = 0
    /// 0–10. Zero means "not rated yet".
    var rating: Double
    /// "IMDb", "TMDB", "Metacritic", "AI estimate" — shown next to the score so
    /// the number is never presented as more authoritative than it is.
    var ratingSource: String
    /// Second score, when a provider supplies one. Defaulted so entries saved
    /// before this field existed still load.
    var secondaryRating: Double = 0
    var secondaryRatingSource: String = ""
    var dateAdded: Date
    var notes: String
    var isFavorite: Bool

    var enrichmentRaw: String
    var enrichmentError: String?
    var lastEnrichedAt: Date?

    /// Provider identifiers, kept so a refresh can skip the search step.
    var posterPath: String?
    var externalID: String?
    var externalSource: String?

    var shelf: MediaShelf?

    var enrichment: EnrichmentState {
        get { EnrichmentState(rawValue: enrichmentRaw) ?? .pending }
        set { enrichmentRaw = newValue.rawValue }
    }

    /// Genres are stored as one display string; filtering needs them apart.
    var genreList: [String] {
        genre.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// "1h 47m" / "48m". Nil when the provider had no runtime, so callers can
    /// omit the field entirely rather than print a zero.
    var runtimeLabel: String? {
        guard runtimeMinutes > 0 else { return nil }
        let hours = runtimeMinutes / 60
        let minutes = runtimeMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        if posterPath.hasPrefix("http") { return URL(string: posterPath) }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }

    init(
        id: UUID = UUID(),
        name: String,
        year: Int? = nil,
        descriptionText: String = "",
        genre: String = "",
        vibesList: [String] = [],
        rating: Double = 0,
        ratingSource: String = "",
        dateAdded: Date = .now,
        notes: String = "",
        isFavorite: Bool = false,
        enrichment: EnrichmentState = .pending
    ) {
        self.id = id
        self.name = name
        self.year = year
        self.descriptionText = descriptionText
        self.genre = genre
        self.vibesList = vibesList
        self.rating = rating
        self.ratingSource = ratingSource
        self.dateAdded = dateAdded
        self.notes = notes
        self.isFavorite = isFavorite
        self.enrichmentRaw = enrichment.rawValue
        self.enrichmentError = nil
        self.lastEnrichedAt = nil
        self.posterPath = nil
        self.externalID = nil
        self.externalSource = nil
    }
}

// MARK: - Word of the day

@Model
final class WordOfTheDayItem {
    #Index<WordOfTheDayItem>([\.dayKey])

    @Attribute(.unique) var id: UUID
    /// "<source>|<yyyy-MM-dd>" — one entry per dictionary per day.
    @Attribute(.unique) var slotKey: String
    var dayKey: String
    var word: String
    var phonetic: String
    var partOfSpeech: String
    /// Primary sense — what the card shows.
    var definition: String
    /// Every sense the source published, for the detail view. Defaulted so an
    /// entry saved before this field existed still opens.
    var fullDefinition: String = ""
    var example: String
    /// A quotation with attribution, where the source supplies one.
    var citation: String = ""
    /// Etymology and usage notes.
    var notes: String = ""
    /// The dictionary that published it, shown on the card.
    var source: String
    var sourceURL: String?
    var date: Date
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        word: String,
        phonetic: String,
        partOfSpeech: String,
        definition: String,
        fullDefinition: String = "",
        example: String,
        citation: String = "",
        notes: String = "",
        source: String,
        sourceURL: String? = nil,
        date: Date = .now,
        dayKey: String,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.slotKey = "\(source)|\(dayKey)"
        self.dayKey = dayKey
        self.word = word
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.fullDefinition = fullDefinition.isEmpty ? definition : fullDefinition
        self.example = example
        self.citation = citation
        self.notes = notes
        self.source = source
        self.sourceURL = sourceURL
        self.date = date
        self.isFavorite = isFavorite
    }
}

// MARK: - Knowledge article

@Model
final class KnowledgeArticleItem {
    #Index<KnowledgeArticleItem>([\.fetchedAt])

    @Attribute(.unique) var id: UUID
    /// Wikipedia canonical title, lowercased — keeps the feed free of repeats.
    @Attribute(.unique) var lookupKey: String
    var title: String
    /// The field this came from, e.g. "Mythology" — used as the card's tag.
    var category: String
    /// Wikidata short description, used as the card's one-line hook.
    var summary: String
    var content: String
    var articleURL: String?
    var thumbnailURL: String?
    /// Images that appear in the article body, with their captions. Parallel
    /// arrays because SwiftData stores primitive collections but not structs.
    var imageURLs: [String] = []
    var imageCaptions: [String] = []
    var fetchedAt: Date
    var isFavorite: Bool
    var isRead: Bool
    /// Whether this is part of the current rotating feed. Saving an article and
    /// showing it in the feed are separate things: a saved article survives
    /// "New set" but gives up its slot, so favourites never crowd out new
    /// reading. Defaulted true so entries stored before this field still show.
    var isInFeed: Bool = true

    init(
        id: UUID = UUID(),
        title: String,
        category: String,
        summary: String,
        content: String,
        articleURL: String? = nil,
        thumbnailURL: String? = nil,
        imageURLs: [String] = [],
        imageCaptions: [String] = [],
        fetchedAt: Date = .now,
        isFavorite: Bool = false,
        isRead: Bool = false,
        isInFeed: Bool = true
    ) {
        self.id = id
        self.lookupKey = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title
        self.category = category
        self.summary = summary
        self.content = content
        self.articleURL = articleURL
        self.thumbnailURL = thumbnailURL
        self.imageURLs = imageURLs
        self.imageCaptions = imageCaptions
        self.fetchedAt = fetchedAt
        self.isFavorite = isFavorite
        self.isRead = isRead
        self.isInFeed = isInFeed
    }
}

// MARK: - Shared helpers

extension DateFormatter {
    /// Stable, locale-independent day key. Used for word-of-the-day rotation and
    /// the AI budget ledger, both of which must not shift with locale.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension Date {
    var dayKey: String { DateFormatter.dayKey.string(from: self) }
}
