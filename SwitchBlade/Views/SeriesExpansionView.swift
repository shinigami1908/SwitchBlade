import SwiftUI
import SwiftData

/// Turns "old spider man 1 2 3" into the three films, with a look before it
/// writes anything.
///
/// TMDB's collections do the work: "Spider-Man Collection" (2002–2007) is a
/// different record from "The Amazing Spider-Man Collection" and from the MCU
/// one, so picking the right era is a choice the user makes from real data
/// rather than a guess anyone has to trust. Gemini is offered only when TMDB
/// has no collection to offer, because a description like "old Akshay Kumar
/// comedies" is a category rather than a series — and because a model call is
/// scarce.
struct SeriesExpansionView: View {
    let shelf: MediaShelf
    let query: String
    /// Called only when entries were actually written, so the add sheet behind
    /// this one closes on success and stays put if the user backs out.
    var onAdded: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .searching
    @State private var chosen: TMDBService.MovieCollection?
    @State private var selectedTitles: Set<String> = []
    @State private var askedModel = false

    private let enrichment = EnrichmentService.shared

    private enum Phase {
        case searching
        case collections([TMDBService.MovieCollection])
        case titles([AISeriesResult])
        case empty(String)
        case failed(String)
    }

    private var searchTerm: String { SeriesRequest.searchTerm(query) }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .searching:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for “\(searchTerm)”…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .collections(let collections):
                    if let chosen {
                        partsSection(for: chosen)
                    } else {
                        collectionPicker(collections)
                    }

                case .titles(let results):
                    modelResults(results)

                case .empty(let message):
                    Section {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    geminiSection

                case .failed(let message):
                    Section {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Color.appWarning)
                    }
                    geminiSection
                }
            }
            .navigationTitle("Add a series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(chosen == nil ? "Cancel" : "Back") {
                        if chosen == nil { dismiss() } else { chosen = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedTitles.count)", action: commit)
                        .fontWeight(.semibold)
                        .disabled(selectedTitles.isEmpty)
                }
            }
            .task { await search() }
        }
    }

    // MARK: - Picking

    private func collectionPicker(_ collections: [TMDBService.MovieCollection]) -> some View {
        Section {
            ForEach(collections) { collection in
                Button {
                    chosen = collection
                    // Everything not already on the shelf, ticked.
                    selectedTitles = Set(
                        collection.parts.map(\.title).filter { !isOnShelf($0) }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Text([
                            collection.yearRange,
                            "\(collection.parts.count) films"
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Which one?")
        } footer: {
            Text("Same name, different era — the years are how you tell them apart.")
        }
    }

    private func partsSection(for collection: TMDBService.MovieCollection) -> some View {
        Section {
            ForEach(collection.parts) { part in
                row(
                    title: part.title,
                    detail: part.year.map(String.init),
                    isOn: selectedTitles.contains(part.title)
                ) { toggle(part.title) }
            }
        } header: {
            Text(collection.name)
        } footer: {
            Text("Anything already on \(shelf.name) is unticked.")
        }
    }

    private func modelResults(_ results: [AISeriesResult]) -> some View {
        Section {
            ForEach(results, id: \.title) { result in
                row(
                    title: result.title,
                    detail: result.year.map(String.init),
                    isOn: selectedTitles.contains(result.title)
                ) { toggle(result.title) }
            }
        } header: {
            Text("Suggested")
        } footer: {
            Text("From the model, so check the list before adding — it can invent titles that sound right.")
        }
    }

    private func row(
        title: String,
        detail: String?,
        isOn: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.appAccent : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 4)

                if isOnShelf(title) {
                    Text("already there")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var geminiSection: some View {
        if !askedModel {
            Section {
                Button {
                    Task { await askModel() }
                } label: {
                    Label("Ask the model instead", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                }
            } footer: {
                Text("Uses one call from today's AI budget — \(AIBudget.shared.remainingToday) left. Worth it for a set TMDB doesn't file as a collection, like a run of films by one actor.")
            }
        }
    }

    // MARK: - Work

    private func isOnShelf(_ title: String) -> Bool {
        shelf.items.contains { $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }

    private func toggle(_ title: String) {
        if selectedTitles.contains(title) {
            selectedTitles.remove(title)
        } else {
            selectedTitles.insert(title)
        }
    }

    private func search() async {
        // Collections are films only; television has no equivalent on TMDB, so
        // a TV shelf goes straight to the model rather than searching for
        // something that cannot exist.
        guard shelf.kind == .movie else {
            phase = .empty("TMDB only groups films into collections, so there's nothing to look up for \(shelf.name).")
            return
        }

        guard let key = AppSettings.shared.key(for: .tmdb) else {
            phase = .failed(ServiceError.missingKey("TMDB").errorDescription ?? "No TMDB key.")
            return
        }

        do {
            let found = try await TMDBService.shared.collections(
                matching: searchTerm, apiKey: key
            )
            if found.isEmpty {
                phase = .empty("No collection on TMDB matches “\(searchTerm)”.")
            } else {
                phase = .collections(found)
            }
        } catch {
            phase = .failed((error as? ServiceError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func askModel() async {
        askedModel = true
        phase = .searching

        do {
            let results = try await GeminiService.shared.seriesTitles(
                for: query, context: shelf.kind.promptNoun
            )
            if results.isEmpty {
                phase = .empty("The model couldn't turn “\(query)” into specific titles.")
            } else {
                selectedTitles = Set(results.map(\.title).filter { !isOnShelf($0) })
                phase = .titles(results)
            }
        } catch {
            phase = .failed((error as? ServiceError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func commit() {
        var added: [ShelfItem] = []

        for title in selectedTitles.sorted() where !isOnShelf(title) {
            let item = ShelfItem(name: title)
            item.shelf = shelf
            modelContext.insert(item)
            added.append(item)
        }

        try? modelContext.save()

        if !added.isEmpty {
            enrichment.enrich(added, in: modelContext)
            onAdded()
        }

        dismiss()
    }
}
