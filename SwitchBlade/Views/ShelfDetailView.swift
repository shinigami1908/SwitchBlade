import SwiftUI
import SwiftData

struct ShelfDetailView: View {
    @Bindable var shelf: MediaShelf

    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var sort: SortOption = .recentlyAdded
    @State private var activeGenres: Set<String> = []
    @State private var activeRatings: Set<String> = []
    @State private var activeRuntimes: Set<String> = []
    @State private var showingFilters = false
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var showingEditor = false
    @State private var showingSeries = false
    @State private var newItemName = ""
    @State private var recentlyRemoved: RemovedItem?
    @State private var undoDismissTask: Task<Void, Never>?

    private let enrichment = EnrichmentService.shared

    enum SortOption: String, CaseIterable, Identifiable {
        case recentlyAdded = "Recently added"
        case title = "Title"
        case rating = "Rating"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .recentlyAdded: return "clock"
            case .title: return "textformat.abc"
            case .rating: return "star"
            }
        }
    }

    /// Snapshot of an entry removed by "Done", kept just long enough for undo.
    private struct RemovedItem: Identifiable {
        let id = UUID()
        let name: String
        let restore: () -> Void
    }

    private var filteredItems: [ShelfItem] {
        var items = shelf.items

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.genre.localizedCaseInsensitiveContains(query)
                    || $0.descriptionText.localizedCaseInsensitiveContains(query)
                    || $0.vibesList.contains { $0.localizedCaseInsensitiveContains(query) }
                    || $0.castList.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        // Filters are AND across the two categories and OR within each, which
        // is what "Sci-Fi or Thriller, but only the slow-burn ones" needs.
        if !activeGenres.isEmpty {
            items = items.filter { !activeGenres.isDisjoint(with: $0.genreList) }
        }

        if !activeRatings.isEmpty {
            let bands = RatingBand.all.filter { activeRatings.contains($0.label) }
            items = items.filter { item in
                // Unrated entries are excluded rather than kept: asking for
                // "8 and up" shouldn't return things with no score at all.
                item.rating > 0 && bands.contains { $0.range.contains(item.rating) }
            }
        }

        if !activeRuntimes.isEmpty {
            let bands = availableRuntimeBands.filter { activeRuntimes.contains($0.label) }
            items = items.filter { item in
                // An entry with no runtime is excluded rather than kept: asking
                // for "under 90 minutes" shouldn't return things of unknown
                // length.
                item.runtimeMinutes > 0
                    && bands.contains { $0.range.contains(item.runtimeMinutes) }
            }
        }

        switch sort {
        case .recentlyAdded:
            return items.sorted { $0.dateAdded > $1.dateAdded }
        case .title:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .rating:
            return items.sorted { $0.rating > $1.rating }
        }
    }

    /// Only values present on this shelf are offered, so the sheet can never
    /// show a filter that would return nothing.
    private var availableGenres: [String] {
        Set(shelf.items.flatMap(\.genreList)).sorted()
    }

    /// Only bands some entry actually falls into, so the sheet can't offer a
    /// score that returns nothing.
    private var availableRatingBands: [RatingBand] {
        let scores = shelf.items.map(\.rating).filter { $0 > 0 }
        guard !scores.isEmpty else { return [] }
        return RatingBand.all.filter { band in
            scores.contains { band.range.contains($0) }
        }
    }

    /// Only bands that some entry actually falls into, so the sheet can't offer
    /// a length that returns nothing.
    private var availableRuntimeBands: [RuntimeBand] {
        let lengths = shelf.items.map(\.runtimeMinutes).filter { $0 > 0 }
        guard !lengths.isEmpty else { return [] }
        return RuntimeBand.bands(for: shelf.kind).filter { band in
            lengths.contains { band.range.contains($0) }
        }
    }

    private var activeFilterCount: Int {
        activeGenres.count + activeRatings.count + activeRuntimes.count
    }

    /// The entry already on this shelf that the typed title would duplicate.
    ///
    /// Year-aware on purpose. Comparing titles alone would either miss "Dune
    /// (2021)" against a stored "Dune" — the matcher doesn't strip a bracketed
    /// year, so that only scores 0.90 — or, if the bar were lowered to catch
    /// it, would flag "Spider-Man 2" as a duplicate of "Spider-Man", which
    /// scores the same 0.90 and is a different film. Stripping the year and
    /// then comparing years separately gets both cases right.
    private var duplicateOfTyped: ShelfItem? {
        let (query, typedYear) = TitleParser.split(newItemName)
        guard query.count >= 2 else { return nil }

        return shelf.items.first { item in
            guard TitleMatcher.score(candidate: item.name, query: query) >= 0.99 else {
                return false
            }
            // Two films can share a title — a remake is not a duplicate — so a
            // year on both sides has to agree. A year on neither, or on only
            // one, is treated as the same work.
            guard let typedYear, let storedYear = item.year else { return true }
            return typedYear == storedYear
        }
    }

    private var failedItems: [ShelfItem] {
        shelf.items.filter { $0.enrichment == .failed }
    }

    /// Entries that filled in fine but never got their tags — the state a
    /// rate-limited bulk import leaves behind. They aren't failed, so the retry
    /// banner never sees them.
    private var untaggedItems: [ShelfItem] {
        shelf.items.filter {
            $0.vibesList.isEmpty && $0.enrichment == .completed
        }
    }

    /// Entries filled in before runtime was a field. Only TMDB-sourced ones can
    /// be backfilled, which is why this isn't simply "runtime is zero".
    private var untimedItems: [ShelfItem] {
        guard shelf.kind == .movie || shelf.kind == .tv else { return [] }
        return shelf.items.filter {
            $0.runtimeMinutes == 0
                && $0.externalSource == "tmdb"
                && $0.externalID != nil
        }
    }

    var body: some View {
        List {
            if activeFilterCount > 0 {
                Section {
                    activeFilterRow
                        .listRowInsets(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 4, trailing: Metrics.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if !failedItems.isEmpty {
                Section {
                    retryBanner
                        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if !untimedItems.isEmpty || enrichment.runtimesRemaining > 0 {
                Section {
                    runtimeBanner
                        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if !untaggedItems.isEmpty || enrichment.vibesRemaining > 0 {
                Section {
                    vibeBanner
                        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if filteredItems.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(filteredItems) { item in
                        ZStack {
                            // A plain NavigationLink inside List draws a
                            // chevron and its own padding; this keeps the row
                            // custom while preserving push behaviour.
                            NavigationLink {
                                ShelfItemDetailView(item: item)
                            } label: { EmptyView() }
                            .opacity(0)

                            ItemRow(item: item, kind: shelf.kind)
                        }
                        .listRowBackground(Color.appSurface)
                        .listRowSeparatorTint(Color.appBorder)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            // Finishing something takes it off the shelf —
                            // the shelf is the backlog, so a finished entry
                            // has nowhere to sit.
                            Button {
                                markDone(item)
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .tint(.appPositive)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                enrichment.forceRefresh(item, in: modelContext)
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .tint(.appAccentAlt)
                        }
                    }
                } header: {
                    Text("\(filteredItems.count) waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .searchable(text: $searchText, prompt: "Search \(shelf.name)")
        .navigationTitle(shelf.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { undoBanner }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: activeFilterCount > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .tint(.appAccent)
                .disabled(
                    availableGenres.isEmpty
                        && availableRatingBands.isEmpty
                        && availableRuntimeBands.isEmpty
                )
            }

            // Adding is the thing you come to a shelf to do, so it's a button
            // rather than the first line of a menu.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(.appAccent)
                .accessibilityLabel("Add to \(shelf.name)")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Paste a List", systemImage: "square.and.arrow.down")
                    }

                    Divider()

                    Picker("Sort", selection: $sort) {
                        ForEach(SortOption.allCases) { option in
                            Label(option.rawValue, systemImage: option.symbol).tag(option)
                        }
                    }

                    Divider()

                    Button {
                        showingEditor = true
                    } label: {
                        Label("Shelf Settings", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(.appAccent)
            }
        }
        .sheet(isPresented: $showingAdd) { addSheet }
        .sheet(isPresented: $showingFilters) {
            FilterSheet(
                genres: availableGenres,
                ratingBands: availableRatingBands,
                runtimeBands: availableRuntimeBands,
                selectedGenres: $activeGenres,
                selectedRatings: $activeRatings,
                selectedRuntimes: $activeRuntimes
            )
        }
        .sheet(isPresented: $showingImport) { ImportView(preselectedShelf: shelf) }
        .sheet(isPresented: $showingEditor) {
            ShelfEditorView(existingCount: 0, editing: shelf)
        }
        .onDisappear { undoDismissTask?.cancel() }
    }

    // MARK: - Undo

    @ViewBuilder
    private var undoBanner: some View {
        if let removed = recentlyRemoved {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.appPositive)

                Text("Removed “\(removed.name)”")
                    .font(.footnote)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Undo") {
                    undoDismissTask?.cancel()
                    removed.restore()
                    recentlyRemoved = nil
                }
                .font(.footnote.weight(.semibold))
                .tint(.appAccent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .cardSurface(radius: Metrics.controlRadius)
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var activeFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(activeGenres.sorted(), id: \.self) { genre in
                    RemovableChip(text: genre) { activeGenres.remove(genre) }
                }
                ForEach(activeRatings.sorted(), id: \.self) { rating in
                    RemovableChip(text: rating) { activeRatings.remove(rating) }
                }
                ForEach(activeRuntimes.sorted(), id: \.self) { runtime in
                    RemovableChip(text: runtime) { activeRuntimes.remove(runtime) }
                }

                Button("Clear all") {
                    activeGenres.removeAll()
                    activeRatings.removeAll()
                    activeRuntimes.removeAll()
                }
                .font(.caption.weight(.medium))
                .tint(.appAccent)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Banners and empty state

    /// Offers the length backfill for entries that predate the runtime field.
    /// Separate from the vibe banner because this one is free — mixing them
    /// would hide a no-cost action behind an AI-budget decision.
    private var runtimeBanner: some View {
        let isWorking = enrichment.runtimesRemaining > 0

        return HStack(spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(Color.appAccentAlt)

            VStack(alignment: .leading, spacing: 2) {
                Text(isWorking
                     ? "Fetching lengths — \(enrichment.runtimesRemaining) to go"
                     : "\(untimedItems.count) without a length")
                    .font(.footnote.weight(.medium))

                Text("From TMDB, so it costs nothing against your AI budget.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Button("Get lengths") {
                    enrichment.fillMissingRuntimes(for: untimedItems, in: modelContext)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.appAccentAlt)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Metrics.controlRadius)
    }

    /// Offers the tag backfill, and is the one place a vibe failure is ever
    /// reported — it used to be recorded and never shown.
    private var vibeBanner: some View {
        let isWorking = enrichment.vibesRemaining > 0

        return HStack(spacing: 10) {
            Image(systemName: isWorking ? "sparkles" : "tag")
                .foregroundStyle(Color.appAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(isWorking
                     ? "Adding vibes — \(enrichment.vibesRemaining) to go"
                     : "\(untaggedItems.count) without vibes")
                    .font(.footnote.weight(.medium))

                if let message = enrichment.lastVibeError {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Color.appWarning)
                        .lineLimit(2)
                } else {
                    Text("Sent \(EnrichmentService.vibeChunkSize) at a time, spaced out to stay under the model's rate limit.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Button("Add vibes") {
                    enrichment.fillMissingVibes(for: untaggedItems, in: modelContext)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.appAccent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Metrics.controlRadius)
    }

    private var retryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appWarning)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(failedItems.count) couldn't be filled in")
                    .font(.footnote.weight(.medium))
                if let message = failedItems.first?.enrichmentError {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            Button("Retry") {
                enrichment.enrich(failedItems, in: modelContext)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.appAccent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Metrics.controlRadius)
    }

    @ViewBuilder
    private var emptyState: some View {
        if shelf.items.isEmpty {
            EmptyStateView(
                symbol: shelf.iconName,
                title: "Nothing on this shelf",
                message: "Add a title and the description, genre, vibes, and score fill in on their own.",
                actionTitle: "Add Entry"
            ) {
                showingAdd = true
            }
        } else if activeFilterCount > 0 {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "No matches",
                message: "Nothing on this shelf has all of the selected filters.",
                actionTitle: "Clear filters"
            ) {
                activeGenres.removeAll()
                activeRatings.removeAll()
                activeRuntimes.removeAll()
            }
        } else {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "Nothing here fits the current search."
            )
        }
    }

    // MARK: - Add sheet

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $newItemName)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(addItem)
                } header: {
                    Text("What are you adding?")
                } footer: {
                    Text("A year in brackets sharpens the match — “Dune (2021)”.")
                }

                if let existing = duplicateOfTyped {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(Color.appWarning)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Already on \(shelf.name)")
                                    .font(.subheadline.weight(.medium))
                                Text([existing.name, existing.year.map(String.init)]
                                    .compactMap { $0 }
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Only ever an offer. Typing a single title never triggers this,
                // and even when it appears, "Add" still adds exactly what was
                // typed — expanding is a separate, deliberate tap.
                if SeriesRequest.looksLikeSeries(newItemName) {
                    Section {
                        Button {
                            showingSeries = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "square.stack.3d.up")
                                    .foregroundStyle(Color.appAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Looks like a series")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("Find the films and add them together")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section {
                    Label(sourceDescription, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add to \(shelf.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAdd = false
                        newItemName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: addItem)
                        .disabled(
                            newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || duplicateOfTyped != nil
                        )
                }
            }
            // Presented from inside the add sheet so it stacks on top of it;
            // attaching it to the parent instead would fight the sheet already
            // on screen and never appear.
            .sheet(isPresented: $showingSeries) {
                SeriesExpansionView(shelf: shelf, query: newItemName) {
                    // Only on a real add — backing out of the series sheet
                    // returns you to the field with your text intact.
                    newItemName = ""
                    showingAdd = false
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sourceDescription: String {
        switch shelf.kind {
        case .movie: return "Details come from TMDB's film catalogue."
        case .tv: return "Details come from TMDB's television catalogue."
        case .game: return "Details come from Steam. Console-only titles fall back to Gemini."
        case .custom: return "Details are written by Gemini."
        }
    }

    // MARK: - Actions

    private func addItem() {
        let name = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Also checked here, not just on the button: the keyboard's return key
        // submits too, and it doesn't consult the button's disabled state.
        guard duplicateOfTyped == nil else { return }

        let item = ShelfItem(name: name)
        item.shelf = shelf
        modelContext.insert(item)
        try? modelContext.save()

        enrichment.enrich(item, in: modelContext)

        newItemName = ""
        showingAdd = false
    }

    /// Removes a finished entry, offering a brief window to put it back.
    private func markDone(_ item: ShelfItem) {
        // Snapshot the fields needed to rebuild it, since the object itself is
        // about to be deleted from the store.
        let name = item.name
        let year = item.year
        let description = item.descriptionText
        let genre = item.genre
        let vibes = item.vibesList
        let rating = item.rating
        let ratingSource = item.ratingSource
        let dateAdded = item.dateAdded
        let notes = item.notes
        let isFavorite = item.isFavorite
        let posterPath = item.posterPath
        let externalID = item.externalID
        let externalSource = item.externalSource
        let enrichmentState = item.enrichment
        let shelfRef = shelf

        modelContext.delete(item)
        try? modelContext.save()

        undoDismissTask?.cancel()

        withAnimation(.easeOut(duration: 0.2)) {
            recentlyRemoved = RemovedItem(name: name) {
                let restored = ShelfItem(
                    name: name,
                    year: year,
                    descriptionText: description,
                    genre: genre,
                    vibesList: vibes,
                    rating: rating,
                    ratingSource: ratingSource,
                    dateAdded: dateAdded,
                    notes: notes,
                    isFavorite: isFavorite,
                    enrichment: enrichmentState
                )
                restored.posterPath = posterPath
                restored.externalID = externalID
                restored.externalSource = externalSource
                restored.shelf = shelfRef
                modelContext.insert(restored)
                try? modelContext.save()
            }
        }

        undoDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                recentlyRemoved = nil
            }
        }
    }

    private func delete(_ item: ShelfItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }
}

// MARK: - Row

struct ItemRow: View {
    let item: ShelfItem
    let kind: ShelfKind

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterThumbnail(url: item.posterURL, symbol: kind.itemSymbol)

            // The ratings sit beside the text column rather than inside it. In
            // the same column, a second rating made the title's row taller and
            // pushed the details down, so the gap under the title varied from
            // row to row depending on whether IMDb had a score.
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                secondaryLine

                if !item.castList.isEmpty {
                    Text(item.castList.prefix(3).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !item.vibesList.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(item.vibesList.prefix(2), id: \.self) { vibe in
                            TagChip(text: vibe)
                        }
                    }
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            // One score per row — the primary, which is IMDb whenever OMDb has
            // it. The second opinion is worth a glance, not a scan, so TMDB
            // appears only on the detail screen.
            RatingBadge(value: item.rating, source: item.ratingSource, compact: true)
                .fixedSize()

            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.appAccent)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var secondaryLine: some View {
        switch item.enrichment {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking it up…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Label("Couldn't fill in — swipe to retry", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color.appWarning)
                .lineLimit(1)
        case .pending:
            Text("Queued")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .completed, .manual:
            HStack(spacing: 6) {
                if let year = item.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let runtime = item.runtimeLabel {
                    if item.year != nil {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(runtime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !item.genre.isEmpty {
                    if item.year != nil || item.runtimeLabel != nil {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(item.genre)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
