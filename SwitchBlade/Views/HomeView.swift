import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \WordOfTheDayItem.date, order: .reverse)
    private var words: [WordOfTheDayItem]

    @Query(sort: \KnowledgeArticleItem.fetchedAt, order: .reverse)
    private var articles: [KnowledgeArticleItem]

    @State private var now = Date()
    @State private var showSavedOnly = false

    private let feed = FeedService.shared
    private let place = PlaceService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    header
                    wordSection
                    learnSection
                }
                .padding(.vertical, 12)
            }
            .background(Color.appBackground)
            .scrollIndicators(.hidden)
            .navigationTitle("SwitchBlade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .refreshable { await refreshAll() }
        }
        // A one-second timer to render a clock is a full view rebuild every
        // second; the minute is the smallest unit actually displayed.
        .onReceive(
            Timer.publish(every: 30, on: .main, in: .common).autoconnect()
        ) { now = $0 }
        .task { await initialLoad() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { place.refreshIfNeeded() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Baseline alignment, not top alignment: the greeting is a serif
            // largeTitle and the clock a rounded title2, so their frame tops sit
            // at different heights even though the text should share a line.
            HStack(alignment: .firstTextBaseline) {
                Text(greeting)
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                Text(now, format: .dateTime.hour().minute())
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Pull up under the greeting — the baseline row already
                // supplies the gap above.
                .padding(.top, -10)

            if AppSettings.shared.useLocation {
                conditionsRow
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    @ViewBuilder
    private var conditionsRow: some View {
        HStack(spacing: 10) {
            if let weather = place.weather {
                Label {
                    Text("\(weather.temperatureDisplay) · \(weather.summary)")
                        .font(.footnote.weight(.medium))
                } icon: {
                    Image(systemName: weather.symbol)
                        .foregroundStyle(.secondary)
                }
            }

            if let name = place.placeName {
                if place.weather != nil {
                    Divider().frame(height: 12)
                }
                Label {
                    Text(name).font(.footnote.weight(.medium))
                } icon: {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.secondary)
                }
            }

            if place.weather == nil && place.placeName == nil {
                Label {
                    Text(place.authorizationDenied
                         ? "Location off — enable it in iOS Settings"
                         : "Finding your location…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: place.authorizationDenied ? "location.slash" : "location")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .imageScale(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Metrics.controlRadius)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still up"
        }
    }

    // MARK: - Word of the day

    private var wordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Words of the Day",
                subtitle: "Straight from each dictionary"
            ) {
                if feed.isLoadingWords {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Metrics.gutter)

            if todaysWords.isEmpty {
                Text(feed.isLoadingWords
                     ? "Fetching today's words…"
                     : feed.wordError ?? "No words yet — pull to refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .cardSurface()
                    .padding(.horizontal, Metrics.gutter)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(todaysWords) { word in
                            NavigationLink {
                                WordDetailView(word: word)
                            } label: {
                                WordCard(word: word)
                                    // Slightly narrower than the 393pt screen
                                    // so the second card peeks and the row
                                    // reads as scrollable without a visible
                                    // indicator.
                                    .frame(width: 300)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// The latest entry from each dictionary, ordered so the same one always
    /// appears first.
    ///
    /// Newest-per-source rather than filtered by date. Both feeds publish on US
    /// Eastern time, so for most of an Indian morning the newest word in
    /// existence is still yesterday's by the local calendar — matching on the
    /// local day showed nothing, or fell back to an arbitrary pair.
    private var todaysWords: [WordOfTheDayItem] {
        // `words` is already sorted newest first, so the first hit per source
        // is that dictionary's latest.
        var latest: [String: WordOfTheDayItem] = [:]
        for word in words where latest[word.source] == nil {
            latest[word.source] = word
        }

        return Array(latest.values).sorted { lhs, rhs in
            let order = WordSource.allCases.map(\.rawValue)
            let l = order.firstIndex(of: lhs.source) ?? order.count
            let r = order.firstIndex(of: rhs.source) ?? order.count
            return l < r
        }
    }

    // MARK: - Learn something new

    private var learnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Learn Something New",
                subtitle: learnSubtitle
            ) {
                HStack(spacing: 14) {
                    if savedCount > 0 || showSavedOnly {
                        Button {
                            showSavedOnly.toggle()
                        } label: {
                            Label(
                                "\(savedCount)",
                                systemImage: showSavedOnly ? "heart.fill" : "heart"
                            )
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.appAccent)
                    }

                    Button {
                        Task { await feed.loadArticles(context: modelContext, replacing: true) }
                    } label: {
                        // The label stays put while loading. Swapping it for a
                        // spinner made the control jump and duplicated the
                        // progress the section itself already shows; dimming
                        // and locking says "working" without either.
                        Label("New set", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                    .opacity(feed.isLoadingArticles ? 0.4 : 1)
                    .disabled(feed.isLoadingArticles)
                }
            }
            .padding(.horizontal, Metrics.gutter)

            LazyVStack(spacing: 14) {
                ForEach(visibleArticles) { article in
                    NavigationLink {
                        ArticleDetailView(article: article)
                    } label: {
                        KnowledgeCard(article: article)
                    }
                    .buttonStyle(.plain)
                }

                feedFooter
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    private var savedCount: Int {
        articles.filter(\.isFavorite).count
    }

    private var feedArticles: [KnowledgeArticleItem] {
        articles.filter(\.isInFeed)
    }

    private var visibleArticles: [KnowledgeArticleItem] {
        showSavedOnly ? articles.filter(\.isFavorite) : feedArticles
    }

    private var learnSubtitle: String? {
        if showSavedOnly {
            return savedCount == 1 ? "1 saved article" : "\(savedCount) saved articles"
        }
        guard !feedArticles.isEmpty else { return nil }
        return "\(feedArticles.count) from Wikipedia"
    }

    @ViewBuilder
    private var feedFooter: some View {
        if feed.isLoadingArticles && articles.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading Wikipedia…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if let error = feed.articleError {
            VStack(spacing: 10) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try again") {
                    feed.clearArticleError()
                    Task { await feed.loadArticles(context: modelContext, replacing: false) }
                }
                .font(.footnote.weight(.semibold))
                .tint(.appAccent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else if showSavedOnly {
            if savedCount == 0 {
                EmptyStateView(
                    symbol: "heart",
                    title: "Nothing saved yet",
                    message: "Tap the heart on an article to keep it here. Saved articles aren't replaced when you load a new set."
                )
                .cardSurface()
            } else {
                Text("Saved articles are kept here, separate from the feed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        } else if feedArticles.isEmpty {
            EmptyStateView(
                symbol: "books.vertical",
                title: "Nothing loaded yet",
                message: "Pull down to fetch \(FeedService.articleCount) pieces from Wikipedia.",
                actionTitle: "Load articles"
            ) {
                Task { await feed.loadArticles(context: modelContext, replacing: false) }
            }
            .cardSurface()
        } else {
            // The set is deliberately finite: reaching the end is the end.
            Text("That's the set. Tap “New set” for \(FeedService.articleCount) more.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        place.refreshIfNeeded()
        await feed.ensureWordsForToday(context: modelContext)
        await feed.ensureArticles(context: modelContext)
    }

    private func refreshAll() async {
        place.refreshIfNeeded()
        await feed.ensureWordsForToday(context: modelContext)
        await feed.loadArticles(context: modelContext, replacing: true)
    }
}

// MARK: - Word card

struct WordCard: View {
    @Bindable var word: WordOfTheDayItem
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(word.word)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 8)

                Button {
                    word.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: word.isFavorite ? "heart.fill" : "heart")
                        .font(.footnote)
                        .foregroundStyle(word.isFavorite ? Color.appAccent : Color.secondary)
                        // Widen the target beyond the glyph; the card is now a
                        // navigation link, so a near-miss would push instead of
                        // toggling.
                        .contentShape(Rectangle())
                        .padding(.leading, 8)
                        .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
            }

            if !word.partOfSpeech.isEmpty || !word.phonetic.isEmpty {
                HStack(spacing: 6) {
                    if !word.partOfSpeech.isEmpty {
                        Text(word.partOfSpeech)
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                    }
                    if !word.phonetic.isEmpty {
                        Text(word.phonetic)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Text(word.definition)
                .font(.subheadline)
                .lineSpacing(3)
                // Without a usage example the definition gets the space, so
                // the card never renders half empty. The caps are set so the
                // tallest possible content still fits the fixed height below.
                .lineLimit(word.example.isEmpty ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)

            if !word.example.isEmpty {
                Text(word.example)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.appAccent.opacity(0.45))
                            .frame(width: 2)
                    }
            }

            Spacer(minLength: 0)

            Text(attribution)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(16)
        // Fixed so the cards in the row align. Sized for the worst case the
        // line limits above allow, which is the five-line no-example layout.
        .frame(height: 240, alignment: .topLeading)
        .cardSurface()
    }

    private var attribution: String {
        WordSource(rawValue: word.source)?.attribution ?? word.source
    }
}

// MARK: - Knowledge card

struct KnowledgeCard: View {
    let article: KnowledgeArticleItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TagChip(text: article.category)

                    Spacer(minLength: 4)

                    if article.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }

                    if article.isRead {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(article.title)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    // Some titles are a single 58-character word; shrink rather
                    // than run off the card.
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)

                Text(article.summary.isEmpty ? article.content : article.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let thumbnail = article.thumbnailURL.flatMap(URL.init) {
                AsyncImage(url: thumbnail) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.appSurfaceElevated
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
