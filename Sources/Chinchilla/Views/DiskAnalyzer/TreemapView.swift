import SwiftUI
import DiskScanKit

struct TreemapCell: Identifiable {
    let id = UUID()
    /// nil for the "everything smaller" remainder cell.
    let node: FileNode?
    let rect: CGRect
    let colorIndex: Int
}

enum TreemapLayout {
    /// Squarified treemap (Bruls et al.): values MUST be sorted descending.
    /// Returns one rect per value, in order.
    static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var rects: [CGRect] = []
        var remaining = rect
        var index = 0

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row: [Double] = [areas[index]]
            var next = index + 1
            var currentWorst = worstAspect(row, side: side)
            while next < areas.count {
                let candidate = row + [areas[next]]
                let candidateWorst = worstAspect(candidate, side: side)
                if candidateWorst <= currentWorst {
                    row = candidate
                    currentWorst = candidateWorst
                    next += 1
                } else {
                    break
                }
            }
            rects.append(contentsOf: place(row: row, in: &remaining))
            index = next
        }
        return rects
    }

    private static func worstAspect(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0 else { return .infinity }
        let thickness = sum / side
        var worst = 1.0
        for area in row {
            let length = area / thickness
            let aspect = max(length / thickness, thickness / length)
            worst = max(worst, aspect)
        }
        return worst
    }

    /// Lays `row` along the short side of `remaining`, shrinking it in place.
    private static func place(row: [Double], in remaining: inout CGRect) -> [CGRect] {
        let sum = row.reduce(0, +)
        var rects: [CGRect] = []
        if remaining.width >= remaining.height {
            // Vertical strip on the left.
            let stripWidth = CGFloat(sum) / remaining.height
            var y = remaining.minY
            for area in row {
                let h = CGFloat(area) / stripWidth
                rects.append(CGRect(x: remaining.minX, y: y, width: stripWidth, height: h))
                y += h
            }
            remaining = CGRect(
                x: remaining.minX + stripWidth, y: remaining.minY,
                width: remaining.width - stripWidth, height: remaining.height
            )
        } else {
            // Horizontal strip on top.
            let stripHeight = CGFloat(sum) / remaining.width
            var x = remaining.minX
            for area in row {
                let w = CGFloat(area) / stripHeight
                rects.append(CGRect(x: x, y: remaining.minY, width: w, height: stripHeight))
                x += w
            }
            remaining = CGRect(
                x: remaining.minX, y: remaining.minY + stripHeight,
                width: remaining.width, height: remaining.height - stripHeight
            )
        }
        return rects
    }
}

struct TreemapView: View {
    let model: DiskAnalyzerModel
    @State private var hovered: UUID?

    private static let palette: [Color] = [
        .orange, .blue, .purple, .teal, .pink, .indigo, .mint, .red, .cyan, .yellow,
    ]

    var body: some View {
        GeometryReader { geo in
            let cells = cells(in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 8))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for cell in cells {
                        let inset = cell.rect.insetBy(dx: 1, dy: 1)
                        guard inset.width > 0, inset.height > 0 else { continue }
                        let base = cell.node == nil
                            ? Color.gray.opacity(0.35)
                            : Self.palette[cell.colorIndex % Self.palette.count]
                                .opacity(hovered == cell.id ? 0.95 : 0.75)
                        let path = Path(roundedRect: inset, cornerRadius: 3)
                        context.fill(path, with: .color(base))
                        if inset.width > 70, inset.height > 30 {
                            let name = cell.node?.name ?? String(localized: "Smaller items")
                            let size = cell.node?.size
                            var text = Text(verbatim: name).font(.caption.bold())
                            if let size {
                                text = text + Text(verbatim: "\n")
                                    + Text(size, format: .byteCount(style: .file)).font(.caption2)
                            }
                            context.draw(
                                text.foregroundStyle(.white),
                                in: inset.insetBy(dx: 6, dy: 4)
                            )
                        }
                    }
                }
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        if let cell = cells.last(where: { $0.rect.contains(value.location) }),
                           let node = cell.node {
                            model.drillDown(into: node)
                        }
                    }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hovered = cells.last(where: { $0.rect.contains(point) })?.id
                    case .ended:
                        hovered = nil
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func cells(in rect: CGRect) -> [TreemapCell] {
        guard let dir = model.displayed, !dir.children.isEmpty else { return [] }
        var values = dir.children.map { Double($0.size) }
        var nodes: [FileNode?] = dir.children
        if dir.remainder > 0 {
            values.append(Double(dir.remainder))
            nodes.append(nil)
        }
        // Children are already sorted descending; the remainder may not be —
        // squarify tolerates one out-of-order tail value acceptably.
        let rects = TreemapLayout.layout(values: values, in: rect)
        return zip(nodes, rects).enumerated().map { index, pair in
            TreemapCell(node: pair.0, rect: pair.1, colorIndex: index)
        }
    }
}
