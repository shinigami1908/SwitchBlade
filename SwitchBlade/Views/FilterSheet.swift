import SwiftUI

/// A length band offered in the filter.
///
/// Films and episodes need different cut-offs — 45 minutes is a short film and
/// a long episode — so the bands come from the shelf's kind rather than being
/// one fixed set. Games have no runtime and get none.
struct RuntimeBand: Identifiable, Hashable {
    let label: String
    let range: ClosedRange<Int>

    var id: String { label }

    static func bands(for kind: ShelfKind) -> [RuntimeBand] {
        switch kind {
        case .tv:
            return [
                RuntimeBand(label: "Under 30m", range: 1...29),
                RuntimeBand(label: "30–60m", range: 30...60),
                RuntimeBand(label: "Over 60m", range: 61...10_000)
            ]
        case .movie, .custom:
            return [
                RuntimeBand(label: "Under 1h 30m", range: 1...89),
                RuntimeBand(label: "1h 30m – 2h", range: 90...120),
                RuntimeBand(label: "2h – 2h 30m", range: 121...150),
                RuntimeBand(label: "Over 2h 30m", range: 151...10_000)
            ]
        case .game:
            return []
        }
    }
}

/// Genre, vibe, and length filters for a shelf.
///
/// Every list is built from what is actually on the shelf, so no option here
/// can return nothing.
struct FilterSheet: View {
    let genres: [String]
    let vibes: [String]
    let runtimeBands: [RuntimeBand]

    @Binding var selectedGenres: Set<String>
    @Binding var selectedVibes: Set<String>
    @Binding var selectedRuntimes: Set<String>

    @Environment(\.dismiss) private var dismiss

    private var total: Int {
        selectedGenres.count + selectedVibes.count + selectedRuntimes.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if genres.isEmpty && vibes.isEmpty && runtimeBands.isEmpty {
                        Text("Nothing to filter by yet. Genres and vibes appear once entries have filled in.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }

                    if !genres.isEmpty {
                        group(
                            title: "Genre",
                            options: genres,
                            selection: $selectedGenres
                        )
                    }

                    if !vibes.isEmpty {
                        group(
                            title: "Vibe",
                            options: vibes,
                            selection: $selectedVibes
                        )
                    }

                    if !runtimeBands.isEmpty {
                        group(
                            title: "Length",
                            options: runtimeBands.map(\.label),
                            selection: $selectedRuntimes
                        )
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 16)
            }
            .background(Color.appBackground)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        selectedGenres.removeAll()
                        selectedVibes.removeAll()
                        selectedRuntimes.removeAll()
                    }
                    .disabled(total == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func group(
        title: String,
        options: [String],
        selection: Binding<Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).eyebrowStyle()
                Spacer()
                if !selection.wrappedValue.isEmpty {
                    Text("\(selection.wrappedValue.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options, id: \.self) { option in
                    let isOn = selection.wrappedValue.contains(option)

                    Button {
                        if isOn {
                            selection.wrappedValue.remove(option)
                        } else {
                            selection.wrappedValue.insert(option)
                        }
                    } label: {
                        Text(option)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .foregroundStyle(isOn ? Color.appBackground : Color.primary)
                            .background(
                                Capsule().fill(isOn ? Color.appAccent : Color.appSurfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A selected filter, with its own remove control.
struct RemovableChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .foregroundStyle(Color.appBackground)
        .background(Capsule().fill(Color.appAccent))
    }
}
