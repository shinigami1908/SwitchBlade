import SwiftUI

// MARK: - Tags

/// Small pill used for vibes, genres, and categories.
struct TagChip: View {
    let text: String
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? Color.appBackground : Color.secondary)
            .background(
                Capsule().fill(filled ? Color.appAccent : Color.appSurfaceElevated)
            )
    }
}

// MARK: - Rating

/// Score with its provenance. The source label is always shown, so a
/// model-estimated number is never mistaken for an IMDb rating.
struct RatingBadge: View {
    let value: Double
    let source: String
    var compact = false

    private var isEstimate: Bool { source.localizedCaseInsensitiveContains("AI") }

    var body: some View {
        if value > 0 {
            VStack(spacing: compact ? 0 : 1) {
                Text(String(format: "%.1f", value))
                    .font(.system(compact ? .subheadline : .title3, design: .rounded, weight: .bold))
                    .foregroundStyle(isEstimate ? Color.secondary : Color.appAccent)
                    .monospacedDigit()

                if !compact, !source.isEmpty {
                    Text(source)
                        .font(.system(size: 8, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isEstimate ? Color.appSurfaceElevated : Color.appAccent.opacity(0.13))
            )
        }
    }
}

// MARK: - Poster

/// Async artwork with a typed placeholder, so rows keep a fixed height whether
/// or not an image exists.
/// Decoded posters, held for the life of the launch.
///
/// `AsyncImage` restarts its load every time its view is re-created, passing
/// back through the empty phase first. Inside a `List` that meant any unrelated
/// state change on the shelf — opening a dialog, editing a filter — made every
/// poster blink to a grey spinner and back. The URL cache didn't help, because
/// the flash comes from re-decoding, not re-downloading.
private enum PosterCache {
    static let images = NSCache<NSURL, UIImage>()
}

struct PosterThumbnail: View {
    let url: URL?
    let symbol: String
    var width: CGFloat = 54
    var height: CGFloat = 78

    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded).resizable().scaledToFill()
            } else if url != nil {
                ZStack {
                    Color.appSurfaceElevated
                    ProgressView().controlSize(.small)
                }
            } else {
                placeholder
            }
        }
        // Keyed on the URL so a refreshed poster replaces the old one, and so
        // a recycled row doesn't keep showing the previous entry's artwork.
        .task(id: url) { await load() }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: Metrics.hairline)
        )
    }

    private func load() async {
        guard let url else {
            loaded = nil
            return
        }

        if let cached = PosterCache.images.object(forKey: url as NSURL) {
            loaded = cached
            return
        }

        guard let data = try? await HTTPClient.shared.data(for: URLRequest(url: url)),
              let image = UIImage(data: data)
        else { return }

        PosterCache.images.setObject(image, forKey: url as NSURL)
        loaded = image
    }

    private var placeholder: some View {
        ZStack {
            Color.appSurfaceElevated
            Image(systemName: symbol)
                .font(.system(size: width * 0.34))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.appAccent)
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Section header

struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).sectionTitleStyle()

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Body copy

/// Renders prose split into paragraphs on blank lines.
///
/// Deliberately **not** markdown-parsed. Everything shown here is plain text
/// from Wikipedia or a dictionary feed, and running it through the markdown
/// parser silently corrupts it: real article text like "written as _leading and
/// trailing_ forms" comes back with the underscores eaten and the words
/// italicised, and technical notation such as `C*-algebra` is a coin flip. The
/// sources emit no markdown, so parsing it is pure downside.
struct FormattedText: View {
    let text: String
    var font: Font = .body

    private var paragraphs: [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(font)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
