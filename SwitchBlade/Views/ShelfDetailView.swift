import SwiftUI
import SwiftData

struct ShelfDetailView: View {
    @Bindable var shelf: MediaShelf

    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var sort: SortOption = .recentlyAdded
    @State private var activeGenres: Set<String> = []
    @State private var activeVibes: Set<String> = []
    @State private var showingFilters = false
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var showingEditor = false
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

        if !activeVibes.isEmpty {
            items = items.filter { !activeVibes.isDisjoint(with: Set($0.vibesList)) }
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

    private var availableVibes: [String] {
        Set(shelf.items.flatMap(\.vibesList)).sorted()
    }

    private var activeFilterCount: Int {
        activeGenres.count + activeVibes.count
    }

    private var failedItems: [ShelfItem] {
        shelf.items.filter { $0.enrichment == .failed }
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
                .disabled(availableGenres.isEmpty && availableVibes.isEmpty)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Entry", systemImage: "plus")
                    }

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
                vibes: availableVibes,
                selectedGenres: $activeGenres,
                selectedVibes: $activeVibes
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
                ForEach(activeVibes.sorted(), id: \.self) { vibe in
                    RemovableChip(text: vibe) { activeVibes.remove(vibe) }
                }

                Button("Clear all") {
                    activeGenres.removeAll()
                    activeVibes.removeAll()
                }
                .font(.caption.weight(.medium))
                .tint(.appAccent)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Banners and empty state

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
                activeVibes.removeAll()
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
                        .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
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

                if !item.genre.isEmpty {
                    if item.year != nil {
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
