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

/// A score band offered in the filter.
///
/// Half-open ranges rather than closed ones, so a title scoring exactly 8.0
/// lands in "8 and up" and not also in "7 – 8". The same bands serve every
/// shelf: unlike length, a score means the same thing whether it came from
/// IMDb, Metacritic or IGDB.
struct RatingBand: Identifiable, Hashable {
    let label: String
    let range: Range<Double>

    var id: String { label }

    static let all: [RatingBand] = [
        // Starts above zero because zero means "not rated yet", not "terrible".
        RatingBand(label: "Under 6", range: 0.1..<6),
        RatingBand(label: "6 – 7", range: 6..<7),
        RatingBand(label: "7 – 8", range: 7..<8),
        RatingBand(label: "8 and up", range: 8..<10.1)
    ]
}

/// A period band offered in the filter.
///
/// Built from the years actually on the shelf rather than hardcoded, so the
/// list needs no revisiting in 2030 and a library of recent films isn't padded
/// with empty decades. Everything before 1990 collapses into one band: the
/// difference between a 1959 film and a 1974 one rarely decides what you watch
/// tonight, whereas "old" versus "this decade" does.
struct YearBand: Identifiable, Hashable {
    let label: String
    let range: ClosedRange<Int>

    var id: String { label }

    static let cutoff = 1990

    static func bands(covering years: [Int]) -> [YearBand] {
        // Guards against a stray year from a mis-parsed title.
        let valid = years.filter { $0 > 1800 && $0 < 2200 }
        guard !valid.isEmpty else { return [] }

        var bands: [YearBand] = []

        if valid.contains(where: { $0 < cutoff }) {
            bands.append(YearBand(label: "Before \(cutoff)", range: 1800...(cutoff - 1)))
        }

        let decades = Set(valid.filter { $0 >= cutoff }.map { ($0 / 10) * 10 })
        for decade in decades.sorted() {
            bands.append(YearBand(label: "\(decade)s", range: decade...(decade + 9)))
        }

        return bands
    }
}

/// Genre, score, period, and length filters for a shelf.
///
/// Every list is built from what is actually on the shelf, so no option here
/// can return nothing.
///
/// Vibes are deliberately not filterable. They're free-form and there ends up
/// being nearly one per title, so the list was long enough to be unusable as a
/// filter while adding little a genre filter doesn't already do. They still
/// appear on the entries themselves.
struct FilterSheet: View {
    let genres: [String]
    let ratingBands: [RatingBand]
    let yearBands: [YearBand]
    let runtimeBands: [RuntimeBand]

    @Binding var selectedGenres: Set<String>
    @Binding var selectedRatings: Set<String>
    @Binding var selectedYears: Set<String>
    @Binding var selectedRuntimes: Set<String>

    @Environment(\.dismiss) private var dismiss

    private var total: Int {
        selectedGenres.count + selectedRatings.count
            + selectedYears.count + selectedRuntimes.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if genres.isEmpty && ratingBands.isEmpty
                        && yearBands.isEmpty && runtimeBands.isEmpty {
                        Text("Nothing to filter by yet. Genres, scores, years and lengths appear once entries have filled in.")
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

                    if !ratingBands.isEmpty {
                        group(
                            title: "Rating",
                            options: ratingBands.map(\.label),
                            selection: $selectedRatings
                        )
                    }

                    if !yearBands.isEmpty {
                        group(
                            title: "Year",
                            options: yearBands.map(\.label),
                            selection: $selectedYears
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
                        selectedRatings.removeAll()
                        selectedYears.removeAll()
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
