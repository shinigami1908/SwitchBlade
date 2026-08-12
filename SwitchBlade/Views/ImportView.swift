import SwiftUI
import SwiftData

/// Bulk transfer for an existing list.
///
/// Two modes. If the pasted text has section headers ("Movies:", "Games:"),
/// each block is routed to the matching shelf. Otherwise everything lands on
/// one chosen shelf. Either way the parse is shown before anything is written.
struct ImportView: View {
    var preselectedShelf: MediaShelf?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\MediaShelf.sortIndex), SortDescriptor(\MediaShelf.name)])
    private var shelves: [MediaShelf]

    @State private var rawText = ""
    @State private var targetShelfID: UUID?
    @State private var startEnrichment = true
    @State private var importSummary: Summary?

    private let enrichment = EnrichmentService.shared

    private struct Summary: Identifiable {
        let id = UUID()
        let added: Int
        let skipped: Int
        let shelfNames: [String]
    }

    // MARK: - Parsing

    /// A block of titles bound for one shelf.
    private struct ParsedGroup: Identifiable {
        let id = UUID()
        var shelf: MediaShelf?
        var headerLabel: String
        var titles: [String]
    }

    private var parsedGroups: [ParsedGroup] {
        let lines = rawText.components(separatedBy: .newlines)
        var groups: [ParsedGroup] = []
        var current = ParsedGroup(
            shelf: resolvedDefaultShelf,
            headerLabel: resolvedDefaultShelf?.name ?? "Unassigned",
            titles: []
        )

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let matched = shelfForHeader(trimmed) {
                if !current.titles.isEmpty { groups.append(current) }
                current = ParsedGroup(shelf: matched, headerLabel: matched.name, titles: [])
                continue
            }

            // Strip common list decorations: bullets, numbering, checkboxes.
            let cleaned = Self.stripDecoration(trimmed)
            guard !cleaned.isEmpty else { continue }

            // A single line with commas and no header is a comma-separated list.
            if lines.count == 1, cleaned.contains(",") {
                current.titles.append(contentsOf:
                    cleaned.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                )
            } else {
                current.titles.append(cleaned)
            }
        }

        if !current.titles.isEmpty { groups.append(current) }

        // Collapse duplicates within the paste itself, preserving order.
        return groups.map { group in
            var seen = Set<String>()
            var unique: [String] = []
            for title in group.titles where seen.insert(title.lowercased()).inserted {
                unique.append(title)
            }
            var copy = group
            copy.titles = unique
            return copy
        }
    }

    /// Recognises a line like "Movies:" or "## Games" as a section header for a
    /// shelf, matching on the shelf's own name and a few common synonyms.
    private func shelfForHeader(_ line: String) -> MediaShelf? {
        var candidate = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-—–:•· "))
            .lowercased()

        guard candidate.count <= 30, !candidate.isEmpty else { return nil }
        // Headers end in a colon, or are a bare known word on their own line.
        let looksLikeHeader = line.hasSuffix(":") || line.hasPrefix("#")

        if candidate.hasSuffix("s") { candidate = String(candidate.dropLast()) }

        let synonyms: [String: ShelfKind] = [
            "movie": .movie, "film": .movie, "watchlist": .movie,
            "tv": .tv, "tv show": .tv, "show": .tv, "series": .tv, "tv serie": .tv,
            "game": .game, "video game": .game, "gaming": .game
        ]

        // Exact shelf name wins over a synonym.
        if let match = shelves.first(where: {
            $0.name.lowercased() == candidate || $0.name.lowercased() == line.lowercased().replacingOccurrences(of: ":", with: "")
        }) {
            return match
        }

        guard looksLikeHeader, let kind = synonyms[candidate] else { return nil }
        return shelves.first { $0.kind == kind }
    }

    private static func stripDecoration(_ line: String) -> String {
        var text = line

        // Leading bullets and checkboxes. En and em dashes are included because
        // iOS smart punctuation rewrites a typed hyphen into one.
        for prefix in ["- [ ] ", "- [x] ", "* ", "- ", "– ", "— ", "• ", "· ", "▪ ", "→ ", "> "] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        // Leading "12." or "12)" numbering.
        if let regex = try? NSRegularExpression(pattern: #"^\d{1,3}[\.\)]\s+"#) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        return text.trimmingCharacters(in: .whitespaces)
    }

    private var resolvedDefaultShelf: MediaShelf? {
        if let preselectedShelf { return preselectedShelf }
        if let targetShelfID { return shelves.first { $0.id == targetShelfID } }
        return shelves.first
    }

    private var totalTitles: Int {
        parsedGroups.reduce(0) { $0 + $1.titles.count }
    }

    private var hasHeaders: Bool {
        parsedGroups.count > 1 || parsedGroups.contains { group in
            group.shelf?.id != resolvedDefaultShelf?.id
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                if preselectedShelf == nil && !hasHeaders {
                    Section {
                        Picker("Add to", selection: Binding(
                            get: { targetShelfID ?? shelves.first?.id },
                            set: { targetShelfID = $0 }
                        )) {
                            ForEach(shelves) { shelf in
                                Label(shelf.name, systemImage: shelf.iconName)
                                    .tag(Optional(shelf.id))
                            }
                        }
                    } footer: {
                        Text("Or use headings like “Movies:” and “Games:” in the text to split the list across shelves automatically.")
                    }
                }

                Section {
                    TextEditor(text: $rawText)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(minHeight: 190)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .overlay(alignment: .topLeading) {
                            if rawText.isEmpty {
                                Text(placeholder)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Your list")
                } footer: {
                    Text("One title per line. Bullets and numbering are stripped automatically.")
                }

                if totalTitles > 0 {
                    previewSection
                }

                Section {
                    Toggle("Fill in details now", isOn: $startEnrichment)
                } footer: {
                    Text(enrichmentFooter)
                }
            }
            .navigationTitle("Import List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(totalTitles > 0 ? "\(totalTitles)" : "")", action: performImport)
                        .disabled(totalTitles == 0)
                        .fontWeight(.semibold)
                }
            }
            .alert(item: $importSummary) { summary in
                Alert(
                    title: Text("Imported \(summary.added)"),
                    message: Text(summaryMessage(summary)),
                    dismissButton: .default(Text("Done")) { dismiss() }
                )
            }
        }
    }

    private var placeholder: String {
        """
        Movies:
        Inception (2010)
        Everything Everywhere All at Once

        TV Shows:
        Severance

        Games:
        Elden Ring
        Hades
        """
    }

    private var previewSection: some View {
        Section {
            ForEach(parsedGroups) { group in
                DisclosureGroup {
                    ForEach(group.titles, id: \.self) { title in
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.subheadline)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if isDuplicate(title, in: group.shelf) {
                                Text("already there")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label(group.headerLabel, systemImage: group.shelf?.iconName ?? "questionmark.folder")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(group.titles.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Preview")
        }
    }

    private var enrichmentFooter: String {
        guard startEnrichment else {
            return "Entries are added as titles only. You can fill them in later from each shelf."
        }

        guard totalTitles > 0 else {
            return "Details are fetched as soon as the list is imported."
        }

        let aiTitles = parsedGroups
            .filter { $0.shelf?.kind == .custom }
            .reduce(0) { $0 + $1.titles.count }
        let structuredTitles = totalTitles - aiTitles

        var parts: [String] = []
        if structuredTitles > 0 {
            parts.append("\(structuredTitles) via TMDB/Steam (no AI cost)")
        }
        if aiTitles > 0 {
            parts.append("\(aiTitles) via Gemini")
        }

        // Vibe tags are the only model call for structured shelves, and they go
        // out 20 titles at a time.
        let vibeCalls = Int(ceil(Double(structuredTitles) / 20))
        let entryCalls = Int(ceil(Double(aiTitles) / 15))
        let total = vibeCalls + entryCalls

        guard total > 0 else { return parts.joined(separator: ", ") + "." }
        return parts.joined(separator: ", ")
            + ". About \(total) AI \(total == 1 ? "call" : "calls") for vibe tags, out of \(AIBudget.shared.remainingToday) left today."
    }

    // MARK: - Import

    private func isDuplicate(_ title: String, in shelf: MediaShelf?) -> Bool {
        guard let shelf else { return false }
        return shelf.items.contains { $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }

    private func performImport() {
        var added: [ShelfItem] = []
        var skipped = 0
        var touchedShelves: Set<String> = []

        for group in parsedGroups {
            guard let shelf = group.shelf else {
                skipped += group.titles.count
                continue
            }

            let existing = Set(shelf.items.map { $0.name.lowercased() })

            for title in group.titles {
                guard !existing.contains(title.lowercased()) else {
                    skipped += 1
                    continue
                }

                let item = ShelfItem(name: title)
                item.shelf = shelf
                modelContext.insert(item)
                added.append(item)
                touchedShelves.insert(shelf.name)
            }
        }

        try? modelContext.save()

        if startEnrichment && !added.isEmpty {
            enrichment.enrich(added, in: modelContext)
        }

        AppSettings.shared.hasCompletedImport = true

        importSummary = Summary(
            added: added.count,
            skipped: skipped,
            shelfNames: Array(touchedShelves).sorted()
        )
    }

    private func summaryMessage(_ summary: Summary) -> String {
        var parts: [String] = []

        if !summary.shelfNames.isEmpty {
            parts.append("Added to \(summary.shelfNames.joined(separator: " and ")).")
        }
        if summary.skipped > 0 {
            parts.append("\(summary.skipped) skipped as duplicates.")
        }
        if startEnrichment && summary.added > 0 {
            parts.append("Details are filling in now.")
        }

        return parts.joined(separator: " ")
    }
}
