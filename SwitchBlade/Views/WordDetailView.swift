import SwiftUI
import SwiftData

/// The full entry as the dictionary published it — every sense, the usage
/// example, the quotation, and the etymology notes, none of which fit on the
/// home-screen card.
struct WordDetailView: View {
    @Bindable var word: WordOfTheDayItem
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading

                Divider()

                section("Definition") {
                    FormattedText(text: word.fullDefinition.isEmpty ? word.definition : word.fullDefinition)
                }

                if !word.example.isEmpty {
                    section("In use") {
                        Text(word.example)
                            .font(.body.italic())
                            .lineSpacing(5)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.appAccent.opacity(0.5))
                                    .frame(width: 2)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !word.citation.isEmpty {
                    section("Seen in print") {
                        FormattedText(text: word.citation, font: .subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if !word.notes.isEmpty {
                    section("Did you know?") {
                        FormattedText(text: word.notes, font: .subheadline)
                    }
                }

                footer
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 16)
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    word.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: word.isFavorite ? "heart.fill" : "heart")
                }
                .tint(.appAccent)
            }

            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .tint(.appAccent)
            }
        }
    }

    // MARK: - Pieces

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(word.word)
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !word.partOfSpeech.isEmpty {
                    Text(word.partOfSpeech)
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                }

                if !word.phonetic.isEmpty {
                    Text(word.phonetic)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrowStyle()
            content()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if let link = word.sourceURL.flatMap(URL.init) {
                Link(destination: link) {
                    Label("Open on \(attribution)", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.appAccent)
            }

            Text("\(attribution) · \(word.date.formatted(date: .long, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var attribution: String {
        WordSource(rawValue: word.source)?.attribution ?? word.source
    }

    private var shareText: String {
        var parts = ["\(word.word) — \(word.partOfSpeech)".trimmingCharacters(in: .whitespaces)]
        parts.append(word.fullDefinition.isEmpty ? word.definition : word.fullDefinition)
        if !word.example.isEmpty { parts.append(word.example) }
        if let url = word.sourceURL { parts.append(url) }
        return parts.joined(separator: "\n\n")
    }
}
