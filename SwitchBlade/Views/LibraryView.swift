import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\MediaShelf.sortIndex), SortDescriptor(\MediaShelf.name)])
    private var shelves: [MediaShelf]

    @State private var showingNewShelf = false
    @State private var showingImport = false
    @State private var shelfPendingDeletion: MediaShelf?

    private let settings = AppSettings.shared
    private let enrichment = EnrichmentService.shared

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !settings.hasCompletedImport {
                        importPrompt
                    }

                    if enrichment.isWorking {
                        enrichmentBanner
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shelves) { shelf in
                            NavigationLink {
                                ShelfDetailView(shelf: shelf)
                            } label: {
                                ShelfCard(shelf: shelf)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if !shelf.isBuiltIn {
                                    Button(role: .destructive) {
                                        shelfPendingDeletion = shelf
                                    } label: {
                                        Label("Delete Shelf", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        newShelfButton
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
            }
            .background(Color.appBackground)
            .scrollIndicators(.hidden)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNewShelf = true
                        } label: {
                            Label("New Shelf", systemImage: "plus.rectangle.on.folder")
                        }

                        Button {
                            showingImport = true
                        } label: {
                            Label("Import a List", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(.appAccent)
                }
            }
            .sheet(isPresented: $showingNewShelf) {
                ShelfEditorView(existingCount: shelves.count)
            }
            .sheet(isPresented: $showingImport) {
                ImportView()
            }
            .alert(
                "Delete “\(shelfPendingDeletion?.name ?? "")”?",
                isPresented: Binding(
                    get: { shelfPendingDeletion != nil },
                    set: { if !$0 { shelfPendingDeletion = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { shelfPendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    if let shelf = shelfPendingDeletion {
                        modelContext.delete(shelf)
                        try? modelContext.save()
                    }
                    shelfPendingDeletion = nil
                }
            } message: {
                Text("This removes the shelf and its \(shelfPendingDeletion?.items.count ?? 0) entries. It can't be undone.")
            }
        }
    }

    // MARK: - Banners

    private var importPrompt: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title3)
                .foregroundStyle(Color.appAccent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bring your existing lists over")
                    .font(.subheadline.weight(.semibold))

                Text("Paste a watchlist or games list once. Everything else fills in automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay(alignment: .topTrailing) {
            Button {
                settings.hasCompletedImport = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            .buttonStyle(.plain)
        }
        .onTapGesture { showingImport = true }
    }

    private var enrichmentBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)

            Text("Filling in \(enrichment.inFlight) \(enrichment.inFlight == 1 ? "entry" : "entries")…")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Metrics.controlRadius)
    }

    private var newShelfButton: some View {
        Button {
            showingNewShelf = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                Text("New Shelf")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.appAccent)
            .frame(maxWidth: .infinity, minHeight: 132)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Color.appAccent.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        Color.appAccent.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shelf card

struct ShelfCard: View {
    let shelf: MediaShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: shelf.iconName)
                .font(.title3)
                .foregroundStyle(Color.appAccent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.appAccent.opacity(0.13)))

            Spacer(minLength: 10)

            Text(shelf.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .cardSurface()
    }

    private var subtitle: String {
        let total = shelf.items.count
        guard total > 0 else { return "Empty" }
        return total == 1 ? "1 waiting" : "\(total) waiting"
    }
}

// MARK: - Shelf editor

struct ShelfEditorView: View {
    let existingCount: Int
    var editing: MediaShelf?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "books.vertical.fill"
    @State private var kind: ShelfKind = .custom

    private let icons = [
        "books.vertical.fill", "film.stack.fill", "gamecontroller.fill", "tv.fill",
        "music.note.list", "headphones", "book.closed.fill", "sparkles.tv.fill",
        "theatermasks.fill", "paintpalette.fill", "globe.americas.fill", "fork.knife",
        "figure.run", "camera.fill", "puzzlepiece.fill", "map.fill"
    ]

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Books, Anime, Podcasts", text: $name)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Fill details using", selection: $kind) {
                        Text("Films — TMDB").tag(ShelfKind.movie)
                        Text("TV shows — TMDB").tag(ShelfKind.tv)
                        Text("Games — Steam").tag(ShelfKind.game)
                        Text("Anything else — Gemini").tag(ShelfKind.custom)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Source")
                } footer: {
                    Text(kindFooter)
                }

                Section("Icon") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6),
                        spacing: 12
                    ) {
                        ForEach(icons, id: \.self) { candidate in
                            Button {
                                icon = candidate
                            } label: {
                                Image(systemName: candidate)
                                    .font(.body)
                                    .frame(width: 40, height: 40)
                                    .foregroundStyle(icon == candidate ? Color.appBackground : Color.primary)
                                    .background(
                                        Circle().fill(
                                            icon == candidate ? Color.appAccent : Color.appSurfaceElevated
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(isEditing ? "Edit Shelf" : "New Shelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard let editing else { return }
                name = editing.name
                icon = editing.iconName
                kind = editing.kind
            }
        }
    }

    private var kindFooter: String {
        switch kind {
        case .movie:
            return "Descriptions, genres, posters, and IMDb-style scores come from TMDB's film catalogue. No AI cost."
        case .tv:
            return "Descriptions, genres, posters, and IMDb-style scores come from TMDB's television catalogue. No AI cost."
        case .game:
            return "Descriptions, genres, and Metacritic scores come from Steam, which needs no key. Console-only titles aren't on Steam and fall back to Gemini."
        case .custom:
            return "There's no metadata API for this, so entries are filled in by Gemini in batches."
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let editing {
            editing.name = trimmed
            editing.iconName = icon
            editing.kind = kind
        } else {
            modelContext.insert(MediaShelf(
                name: trimmed,
                iconName: icon,
                kind: kind,
                sortIndex: existingCount
            ))
        }

        try? modelContext.save()
        dismiss()
    }
}
