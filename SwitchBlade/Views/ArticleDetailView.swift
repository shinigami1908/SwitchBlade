import SwiftUI
import SwiftData

struct ArticleDetailView: View {
    @Bindable var article: KnowledgeArticleItem
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let thumbnail = article.thumbnailURL.flatMap(URL.init) {
                    AsyncImage(url: thumbnail) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.appSurfaceElevated
                        }
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    TagChip(text: article.category, filled: true)

                    Text(article.title)
                        .font(.system(.title, design: .serif, weight: .semibold))
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.summary.isEmpty {
                        Text(article.summary)
                            .font(.headline.weight(.regular))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                FormattedText(text: article.content)

                if !article.imageURLs.isEmpty {
                    gallery
                }

                if let link = article.articleURL.flatMap(URL.init) {
                    Link(destination: link) {
                        Label("Read the full article on Wikipedia", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                    }
                    .tint(.appAccent)
                    .padding(.top, 4)
                }

                Text("Text from Wikipedia, available under CC BY-SA.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 16)
        }
        .background(Color.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    article.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: article.isFavorite ? "heart.fill" : "heart")
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
        .task {
            // Marking on appearance rather than on tap means the flag reflects
            // what was actually opened.
            guard !article.isRead else { return }
            article.isRead = true
            try? modelContext.save()
        }
    }

    /// Images from the article body, each with its caption where Wikipedia
    /// supplies one. Only shown when the article actually has pictures.
    private var gallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(article.imageURLs.count == 1 ? "Image" : "Images").eyebrowStyle()

            ForEach(Array(article.imageURLs.enumerated()), id: \.offset) { index, urlString in
                VStack(alignment: .leading, spacing: 7) {
                    AsyncImage(url: URL(string: urlString)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            // A dead image URL shouldn't leave a grey slab
                            // behind; collapse to nothing.
                            EmptyView()
                        case .empty:
                            ZStack {
                                Color.appSurfaceElevated
                                ProgressView().controlSize(.small)
                            }
                            .frame(height: 180)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if index < article.imageCaptions.count {
                        let caption = article.imageCaptions[index]
                        if !caption.isEmpty {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var shareText: String {
        var parts = [article.title]
        if !article.summary.isEmpty { parts.append(article.summary) }
        parts.append(article.content)
        if let url = article.articleURL { parts.append(url) }
        return parts.joined(separator: "\n\n")
    }
}
