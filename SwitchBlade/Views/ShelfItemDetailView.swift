import SwiftUI
import SwiftData

struct ShelfItemDetailView: View {
    @Bindable var item: ShelfItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var draft = Draft()
    @State private var showingDeleteAlert = false
    @State private var showingDoneConfirm = false

    private let enrichment = EnrichmentService.shared

    private struct Draft {
        var name = ""
        var year = ""
        var description = ""
        var genre = ""
        var vibes = ""
        var rating = 0.0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero

                if isEditing {
                    editor
                } else {
                    details
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 14)
        }
        .background(Color.appBackground)
        .scrollIndicators(.hidden)
        .navigationTitle(isEditing ? "Edit" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button("Done") {
                        commitEdits()
                        isEditing = false
                    }
                    .fontWeight(.semibold)
                    .tint(.appAccent)
                } else {
                    Menu {
                        Button {
                            beginEditing()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button {
                            enrichment.forceRefresh(item, in: modelContext)
                        } label: {
                            Label("Refresh from source", systemImage: "arrow.clockwise")
                        }

                        Button {
                            item.isFavorite.toggle()
                            try? modelContext.save()
                        } label: {
                            Label(
                                item.isFavorite ? "Remove Favourite" : "Mark Favourite",
                                systemImage: item.isFavorite ? "heart.slash" : "heart"
                            )
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(.appAccent)
                }
            }
        }
        .alert("Delete “\(item.name)”?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                modelContext.delete(item)
                try? modelContext.save()
                dismiss()
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                PosterThumbnail(
                    url: item.posterURL,
                    symbol: item.shelf?.kind.itemSymbol ?? "square.stack",
                    width: 84,
                    height: 122
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(item.name)
                        .font(.system(.title3, design: .serif, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let year = item.year {
                        Text(String(year))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if !item.genre.isEmpty {
                        Text(item.genre)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        RatingBadge(value: item.rating, source: item.ratingSource)

                        if item.secondaryRating > 0 {
                            RatingBadge(
                                value: item.secondaryRating,
                                source: item.secondaryRatingSource
                            )
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .cardSurface()
    }

    // MARK: - Read mode

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            block(title: "Description") {
                switch item.enrichment {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking it up…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.enrichmentError ?? "Couldn't fetch details.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Try again") {
                            enrichment.forceRefresh(item, in: modelContext)
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(.appAccent)
                    }
                default:
                    if item.descriptionText.isEmpty {
                        Text("Nothing yet. Tap Edit to write your own.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(item.descriptionText)
                            .font(.subheadline)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !item.vibesList.isEmpty {
                block(title: "Vibes") {
                    FlowLayout(spacing: 7, lineSpacing: 7) {
                        ForEach(item.vibesList, id: \.self) { vibe in
                            TagChip(text: vibe)
                        }
                    }
                }
            }

            if !item.castList.isEmpty {
                block(title: castTitle) {
                    FlowLayout(spacing: 7, lineSpacing: 7) {
                        ForEach(item.castList, id: \.self) { person in
                            TagChip(text: person)
                        }
                    }
                }
            }

            block(title: "Notes") {
                TextField(
                    "Thoughts, where you left off, who recommended it…",
                    text: $item.notes,
                    axis: .vertical
                )
                .font(.subheadline)
                .lineLimit(3...10)
                .onChange(of: item.notes) { _, _ in
                    try? modelContext.save()
                }
            }

            markDoneButton

            metaFooter
        }
    }

    /// Finishing something takes it off the shelf — the shelf is the backlog,
    /// so a finished entry has nowhere left to sit.
    private var markDoneButton: some View {
        Button {
            showingDoneConfirm = true
        } label: {
            Label(doneVerb, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appPositive)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(Color.appPositive.opacity(0.13))
        )
        .confirmationDialog(
            "\(doneVerb)?",
            isPresented: $showingDoneConfirm,
            titleVisibility: .visible
        ) {
            Button(doneVerb, role: .destructive) {
                modelContext.delete(item)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes “\(item.name)” from the shelf.")
        }
    }

    private var doneVerb: String {
        item.shelf?.kind == .game ? "Mark as played" : "Mark as watched"
    }

    /// A game's "cast" is its studio, so the heading follows the shelf.
    private var castTitle: String {
        item.shelf?.kind == .game ? "Studio" : "Cast"
    }

    private var metaFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Added \(item.dateAdded.formatted(date: .abbreviated, time: .omitted))")

            if let source = item.externalSource, !source.isEmpty {
                Text("Details from \(sourceLabel(source))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private func sourceLabel(_ raw: String) -> String {
        switch raw {
        case "tmdb": return "TMDB"
        case "steam": return "Steam"
        case "gemini": return "Gemini"
        default: return raw
        }
    }

    // MARK: - Edit mode

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            block(title: "Title") {
                TextField("Title", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }

            block(title: "Year") {
                TextField("e.g. 2010", text: $draft.year)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .keyboardType(.numberPad)
            }

            block(title: "Genres") {
                TextField("Comma separated", text: $draft.genre)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }

            block(title: "Vibes") {
                TextField("Comma separated", text: $draft.vibes)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }

            block(title: "Rating — \(String(format: "%.1f", draft.rating))") {
                Slider(value: $draft.rating, in: 0...10, step: 0.1)
                    .tint(.appAccent)
            }

            block(title: "Description") {
                TextField("Description", text: $draft.description, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(4...12)
            }

            Text("Saving marks this entry as edited by hand, so an automatic refresh won't overwrite it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    private func block<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).eyebrowStyle()
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Editing

    private func beginEditing() {
        draft = Draft(
            name: item.name,
            year: item.year.map(String.init) ?? "",
            description: item.descriptionText,
            genre: item.genre,
            vibes: item.vibesList.joined(separator: ", "),
            rating: item.rating
        )
        isEditing = true
    }

    private func commitEdits() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // A changed title means the entry now refers to a different work, so
        // everything sourced against the old one is stale — including the
        // poster, which would otherwise show the wrong film entirely.
        let titleChanged = !trimmedName.isEmpty
            && trimmedName.compare(item.name, options: .caseInsensitive) != .orderedSame

        if !trimmedName.isEmpty { item.name = trimmedName }

        item.year = Int(draft.year.trimmingCharacters(in: .whitespacesAndNewlines))
        item.descriptionText = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        item.genre = draft.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        item.rating = draft.rating

        item.vibesList = draft.vibes
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if item.rating > 0, item.ratingSource.isEmpty {
            item.ratingSource = "Yours"
        }

        if titleChanged {
            // Clear what was tied to the previous title so a failed lookup
            // can't leave the old work's artwork and ids attached.
            item.posterPath = nil
            item.externalID = nil
            item.externalSource = nil
            item.castList = []
            try? modelContext.save()

            enrichment.forceRefresh(item, in: modelContext)
        } else {
            // Only a hand-edit of the details: don't let a later refresh
            // overwrite what the user wrote.
            item.enrichment = .manual
            try? modelContext.save()
        }
    }
}
