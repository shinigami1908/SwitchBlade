import SwiftUI

/// Wraps subviews onto as many rows as they need.
///
/// Built on the `Layout` protocol rather than the older GeometryReader-and-
/// alignment-guide trick, which mutates state during layout and reports a
/// height of zero on first pass.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    struct Cache {
        var rows: [[Int]] = []
        var sizes: [CGSize] = []
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        layout(subviews: subviews, maxWidth: maxWidth, cache: &cache)
        return CGSize(width: proposal.width ?? cache.width, height: cache.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        layout(subviews: subviews, maxWidth: bounds.width, cache: &cache)

        var y = bounds.minY
        for row in cache.rows {
            let rowHeight = row.map { cache.sizes[$0].height }.max() ?? 0
            var x = bounds.minX

            for index in row {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }

            y += rowHeight + lineSpacing
        }
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat, cache: inout Cache) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Recomputing on every pass is wasteful; skip when nothing changed.
        if cache.width == maxWidth && cache.sizes == sizes { return }

        var rows: [[Int]] = []
        var current: [Int] = []
        var lineWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, size) in sizes.enumerated() {
            let needed = current.isEmpty ? size.width : lineWidth + spacing + size.width

            if needed > maxWidth && !current.isEmpty {
                rows.append(current)
                totalHeight += rowHeight + lineSpacing
                current = [index]
                lineWidth = size.width
                rowHeight = size.height
            } else {
                current.append(index)
                lineWidth = needed
                rowHeight = max(rowHeight, size.height)
            }
        }

        if !current.isEmpty {
            rows.append(current)
            totalHeight += rowHeight
        }

        cache.rows = rows
        cache.sizes = sizes
        cache.height = totalHeight
        cache.width = maxWidth
    }
}
