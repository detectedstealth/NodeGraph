import ImageIO
import NodeGraphCore
import SwiftUI
import UniformTypeIdentifiers

/// The numbers the stats panel shows.
public struct CanvasStats: Hashable, Sendable {
    public var nodes: Int
    public var links: Int
    /// Nodes, links and groups inside the view right now.
    public var visibleItems: Int
    public var zoom: Double

    /// One line per figure, in the order they are drawn.
    public var lines: [String] {
        [
            "Nodes \(nodes)",
            "Links \(links)",
            "Visible \(visibleItems)",
            "Zoom \(Int((zoom * 100).rounded()))%",
        ]
    }
}

extension GraphEditorModel {
    /// Each node's place in the run order, counting from 1, for the current level. Empty when the
    /// graph has a loop that no feedback node breaks. Cached until the next edit.
    public var executionOrder: [NodeID: Int] {
        if let cachedExecutionOrder { return cachedExecutionOrder }
        var order: [NodeID: Int] = [:]
        if let plan = try? ExecutionPlan.compile(graph, nodes: editor.nodes) {
            for (index, id) in plan.order.enumerated() { order[id] = index + 1 }
        }
        cachedExecutionOrder = order
        return order
    }

    /// The figures for the stats panel.
    public var stats: CanvasStats {
        CanvasStats(
            nodes: graph.nodes.count, links: graph.links.count,
            visibleItems: items(in: camera.visibleRect(in: viewSize)).count, zoom: camera.zoom)
    }

    /// The whole graph drawn as it looks now, with `padding` of background around it, at `scale`
    /// pixels per graph unit. Selection and run badges are included; the grid is too. Nil when
    /// there are no nodes.
    public func renderImage(scale: Double = 2, padding: Double = 40) -> CGImage? {
        guard let bounds = contentBounds else { return nil }
        let size = CGSize(width: bounds.size.width + 2 * padding, height: bounds.size.height + 2 * padding)
        // Keep the picture inside what a bitmap can hold.
        let limit = 8192.0
        let factor = min(scale, limit / max(size.width, size.height))
        let saved = camera, savedSize = viewSize
        defer { camera = saved; viewSize = savedSize }
        camera = GraphCamera(
            origin: GraphPoint(x: bounds.origin.x - padding, y: bounds.origin.y - padding), zoom: 1)
        viewSize = size
        let renderer = ImageRenderer(content: Canvas { context, canvasSize in
            var context = context
            MainActor.assumeIsolated {
                GraphCanvasRenderer(model: self, controller: nil).draw(&context, size: canvasSize)
            }
        }.frame(width: size.width, height: size.height))
        renderer.scale = factor
        return renderer.cgImage
    }

    /// ``renderImage(scale:padding:)`` encoded as PNG.
    public func pngData(scale: Double = 2, padding: Double = 40) -> Data? {
        guard let image = renderImage(scale: scale, padding: padding) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Hands a PNG of the graph to ``onExportImage``. Returns whether there was something to export.
    @discardableResult
    public func exportImage() -> Bool {
        guard let onExportImage, let data = pngData() else { return false }
        onExportImage(data)
        return true
    }
}

extension GraphCanvasRenderer {
    /// A small filled arrowhead on the middle of a link, pointing the way it flows.
    func drawLinkArrow(_ context: inout GraphicsContext, _ link: GraphLink, color: RGBAColor) {
        guard let route = model.linkPath(of: link) else { return }
        let (point, angle) = route.midpointWithDirection()
        // Stays readable when zoomed out: never smaller than 5 screen points long.
        let length = max(8, 5 / model.camera.zoom)
        let tip = CGPoint(x: point.x + cos(angle) * length / 2, y: point.y + sin(angle) * length / 2)
        let back = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let half = length * 0.45
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: back.x + sin(angle) * half, y: back.y - cos(angle) * half))
        path.addLine(to: CGPoint(x: back.x - sin(angle) * half, y: back.y + cos(angle) * half))
        path.closeSubpath()
        context.fill(path, with: .color(Color(color)))
    }

    /// A round number badge on a node's top-left corner.
    func drawOrderBadge(_ context: inout GraphicsContext, number: Int, on frame: GraphRect) {
        let theme = model.theme
        let size = theme.portFontSize * model.textScale
        let resolved = context.resolve(
            Text("\(number)").font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(theme.nodeTitle)))
        let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        let width = max(measured.height + 4, measured.width + 8)
        let pill = CGRect(
            x: frame.minX - width / 2, y: frame.minY - measured.height / 2 - 2,
            width: width, height: measured.height + 4)
        context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color(theme.nodeBody)))
        context.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color(theme.selection)), lineWidth: 1)
        context.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    /// The stats panel, in screen space at the top-left of the view.
    func drawStats(_ context: inout GraphicsContext) {
        let theme = model.theme
        let resolved = model.stats.lines.map {
            context.resolve(Text($0).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(theme.nodeTitle)))
        }
        let sizes = resolved.map { $0.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)) }
        let width = (sizes.map(\.width).max() ?? 0) + 16
        let height = sizes.reduce(0) { $0 + $1.height } + 12
        let panel = CGRect(x: 8, y: 8, width: width, height: height)
        context.fill(Path(roundedRect: panel, cornerRadius: 6), with: .color(Color(theme.nodeBody).opacity(0.9)))
        context.stroke(Path(roundedRect: panel, cornerRadius: 6), with: .color(Color(theme.nodeBorder)), lineWidth: 1)
        var y = panel.minY + 6
        for (text, size) in zip(resolved, sizes) {
            context.draw(text, at: CGPoint(x: panel.minX + 8, y: y), anchor: .topLeading)
            y += size.height
        }
    }
}
