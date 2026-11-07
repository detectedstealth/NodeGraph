import NodeGraphCore
import SwiftUI

extension Color {
    /// The SwiftUI color for a platform-neutral one.
    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

/// Draws the graph into a `GraphicsContext`. Holds no state of its own: everything it draws is
/// read from the model, and all geometry comes from the model's layouts, link paths and camera,
/// so what is drawn is what hit testing sees.
@MainActor
struct GraphCanvasRenderer {
    let model: GraphEditorModel
    /// What a drag in progress adds to the picture; nil draws the graph alone.
    var controller: GraphInteractionController?

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let theme = model.theme
        let camera = model.camera
        let lod = LevelOfDetail(zoom: camera.zoom)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(theme.background)))

        let visible = camera.visibleRect(in: size)
        // Everything below is drawn in graph space.
        context.scaleBy(x: camera.zoom, y: camera.zoom)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)

        drawGrid(&context, visible: visible, zoom: camera.zoom, theme: theme)
        for item in model.items(in: visible) {
            switch item {
            case .group(let id):
                if let group = model.graph.groups[id] { drawGroup(&context, group, lod: lod) }
            case .link(let id):
                if let link = model.graph.links[id], controller?.hiddenLinks.contains(id) != true {
                    drawLink(&context, link, lod: lod)
                }
            case .node(let id):
                if let layout = model.layout(of: id) { drawNode(&context, layout, lod: lod) }
            }
        }
        if let draft = controller?.draft { drawDraft(&context, draft) }
        if let marquee = controller?.marquee { drawMarquee(&context, marquee) }
    }

    // MARK: Interaction overlay

    private func drawDraft(_ context: inout GraphicsContext, _ draft: ConnectionDraft) {
        let theme = model.theme
        let zoom = model.camera.zoom
        // End the draft on the candidate port when there is one, so it visibly snaps there.
        let target = draft.candidate.flatMap { model.layout(of: $0.node)?.port($0)?.position } ?? draft.pointer
        let route = draft.anchor.direction == .output
            ? LinkPath(from: draft.anchorPosition, to: target, style: model.linkStyle)
            : LinkPath(from: target, to: draft.anchorPosition, style: model.linkStyle)
        var path = Path()
        path.move(to: CGPoint(route.start))
        for segment in route.segments {
            switch segment {
            case .line(let to): path.addLine(to: CGPoint(to))
            case .cubic(let c1, let c2, let to): path.addCurve(to: CGPoint(to), control1: CGPoint(c1), control2: CGPoint(c2))
            }
        }
        let anchorPort = model.layout(of: draft.anchor.node)?.port(draft.anchor)?.definition
        let color = anchorPort.map { model.color(of: $0) } ?? theme.link
        context.stroke(
            path, with: .color(Color(color).opacity(0.85)),
            style: StrokeStyle(lineWidth: max(theme.linkWidth, 1.5 / zoom), lineCap: .round, dash: [6, 4]))

        for (address, ringColor) in [(draft.candidate, theme.selection), (draft.rejected, theme.failed)] {
            guard let address, let position = model.layout(of: address.node)?.port(address)?.position else { continue }
            let r = model.metrics.portRadius + 4
            context.stroke(
                Path(ellipseIn: CGRect(x: position.x - r, y: position.y - r, width: 2 * r, height: 2 * r)),
                with: .color(Color(ringColor)), lineWidth: 2)
        }
    }

    private func drawMarquee(_ context: inout GraphicsContext, _ marquee: GraphRect) {
        let theme = model.theme
        let path = Path(CGRect(marquee))
        context.fill(path, with: .color(Color(theme.selection.withAlpha(0.12))))
        context.stroke(path, with: .color(Color(theme.selection.withAlpha(0.8))), lineWidth: 1 / model.camera.zoom)
    }

    // MARK: Grid

    private func drawGrid(_ context: inout GraphicsContext, visible: GraphRect, zoom: Double, theme: GraphTheme) {
        let spacing = theme.gridSpacing
        guard spacing > 0 else { return }
        let hairline = 1 / zoom
        let majorEvery = max(theme.gridMajorEvery, 1)

        func lines(step: Double, skipping: Int?) -> Path {
            var path = Path()
            let first = Int((visible.minX / step).rounded(.up)), last = Int((visible.maxX / step).rounded(.down))
            guard last - first < 600 else { return path }
            for i in first...max(first, last) where skipping.map({ i % $0 != 0 }) ?? true {
                path.move(to: CGPoint(x: Double(i) * step, y: visible.minY))
                path.addLine(to: CGPoint(x: Double(i) * step, y: visible.maxY))
            }
            let firstRow = Int((visible.minY / step).rounded(.up)), lastRow = Int((visible.maxY / step).rounded(.down))
            guard lastRow - firstRow < 600 else { return path }
            for i in firstRow...max(firstRow, lastRow) where skipping.map({ i % $0 != 0 }) ?? true {
                path.move(to: CGPoint(x: visible.minX, y: Double(i) * step))
                path.addLine(to: CGPoint(x: visible.maxX, y: Double(i) * step))
            }
            return path
        }

        if zoom >= LevelOfDetail.minorGridFrom {
            context.stroke(lines(step: spacing, skipping: majorEvery), with: .color(Color(theme.gridMinor)), lineWidth: hairline)
        }
        // Major lines are drawn on their own so they stay when the minor ones are dropped.
        let majorStep = spacing * Double(majorEvery)
        if majorStep * zoom >= 8 {
            context.stroke(lines(step: majorStep, skipping: nil), with: .color(Color(theme.gridMajor)), lineWidth: hairline)
        }
    }

    // MARK: Groups

    private func drawGroup(_ context: inout GraphicsContext, _ group: NodeGroup, lod: LevelOfDetail) {
        let theme = model.theme
        let rect = CGRect(group.bounds)
        let shape = Path(roundedRect: rect, cornerRadius: lod.drawsRoundedCorners ? theme.cornerRadius : 0)
        let selected = model.selection.groups.contains(group.id)
        let tint = group.color
        context.fill(shape, with: .color(Color(tint.map { $0.withAlpha(0.12) } ?? theme.groupFill)))
        context.stroke(
            shape, with: .color(Color(selected ? theme.selection : tint?.withAlpha(0.6) ?? theme.groupBorder)),
            lineWidth: max(selected ? 2 : theme.borderWidth, 1 / model.camera.zoom))
        if lod.drawsTitles {
            let title = context.resolve(
                Text(group.title).font(.system(size: theme.titleFontSize, weight: .semibold))
                    .foregroundColor(Color(theme.groupTitle)))
            context.draw(title, at: CGPoint(x: rect.minX + 10, y: rect.minY + 8), anchor: .topLeading)
        }
    }

    // MARK: Links

    private func drawLink(_ context: inout GraphicsContext, _ link: GraphLink, lod: LevelOfDetail) {
        let theme = model.theme
        guard let ends = model.endpoints(of: link) else { return }
        var path = Path()
        if lod.drawsLinkCurves, let route = model.linkPath(of: link) {
            path.move(to: CGPoint(route.start))
            for segment in route.segments {
                switch segment {
                case .line(let to): path.addLine(to: CGPoint(to))
                case .cubic(let c1, let c2, let to):
                    path.addCurve(to: CGPoint(to), control1: CGPoint(c1), control2: CGPoint(c2))
                }
            }
        } else {
            path.move(to: CGPoint(ends.source))
            path.addLine(to: CGPoint(ends.target))
        }
        let selected = model.selection.links.contains(link.id)
        let sourcePort = model.layout(of: link.source.node)?.port(link.source)?.definition
        let color: RGBAColor
        if selected {
            color = theme.linkSelected
        } else if let sourcePort {
            color = sourcePort.kind == .trigger ? theme.linkTrigger : model.color(of: sourcePort)
        } else {
            color = theme.link
        }
        let width = max(theme.linkWidth, 1.5 / model.camera.zoom) * (selected ? 1.5 : 1)
        context.stroke(path, with: .color(Color(color)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    // MARK: Nodes

    private func drawNode(_ context: inout GraphicsContext, _ layout: NodeLayout, lod: LevelOfDetail) {
        guard let node = model.graph.nodes[layout.node] else { return }
        let theme = model.theme
        let zoom = model.camera.zoom
        let frame = CGRect(layout.frame)
        let selected = model.selection.nodes.contains(node.id)
        let radius = lod.drawsRoundedCorners ? theme.cornerRadius : 0
        let shape = Path(roundedRect: frame, cornerRadius: radius)
        let headerColor = node.color ?? theme.nodeHeader
        let dimmed = node.mode == .never || node.mode == .muted || node.mode == .bypassed

        context.drawLayer { layer in
            if dimmed { layer.opacity = theme.inactiveOpacity }

            if lod.tier == .minimal {
                layer.fill(shape, with: .color(Color(headerColor)))
            } else {
                layer.fill(shape, with: .color(Color(theme.nodeBody)))
                layer.drawLayer { clipped in
                    clipped.clip(to: shape)
                    clipped.fill(Path(CGRect(layout.header)), with: .color(Color(headerColor)))
                }
            }
            layer.stroke(
                shape, with: .color(Color(selected ? theme.selection : theme.nodeBorder)),
                lineWidth: max(selected ? 2 : theme.borderWidth, 1 / zoom))

            if lod.drawsTitles {
                let definition = model.definition(of: node)
                let title = node.title ?? definition?.displayName ?? node.typeID.rawValue
                let text = layer.resolve(
                    Text(title).font(.system(size: theme.titleFontSize, weight: .semibold))
                        .foregroundColor(Color(theme.nodeTitle)))
                layer.drawLayer { clipped in
                    clipped.clip(to: Path(CGRect(layout.header).insetBy(dx: 6, dy: 0)))
                    clipped.draw(
                        text, at: CGPoint(x: layout.header.minX + 10, y: layout.header.minY + layout.header.size.height / 2),
                        anchor: .leading)
                }
            }
            if lod.drawsPorts {
                for port in layout.inputs + layout.outputs { drawPort(&layer, port, layout: layout, lod: lod) }
            }
            if selected, !layout.isCollapsed, lod.tier == .full { drawResizeHandle(&layer, layout) }
        }
    }

    private func drawPort(_ context: inout GraphicsContext, _ port: PortLayout, layout: NodeLayout, lod: LevelOfDetail) {
        let theme = model.theme
        let metrics = model.metrics
        let center = CGPoint(port.position)
        let r = metrics.portRadius
        let color = Color(model.color(of: port.definition))
        let connected = port.address.direction == .input
            ? !model.graph.links(into: port.address).isEmpty : !model.graph.links(from: port.address).isEmpty

        let shape: Path
        if port.definition.kind == .trigger {
            // Trigger ports are diamonds, so they read differently from data dots at a glance.
            var diamond = Path()
            diamond.move(to: CGPoint(x: center.x, y: center.y - r * 1.3))
            diamond.addLine(to: CGPoint(x: center.x + r * 1.3, y: center.y))
            diamond.addLine(to: CGPoint(x: center.x, y: center.y + r * 1.3))
            diamond.addLine(to: CGPoint(x: center.x - r * 1.3, y: center.y))
            diamond.closeSubpath()
            shape = diamond
        } else {
            shape = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
        if connected {
            context.fill(shape, with: .color(color))
        } else {
            context.fill(shape, with: .color(Color(theme.nodeBody)))
            context.stroke(shape, with: .color(color), lineWidth: 1.5)
        }

        guard lod.drawsPortLabels, !layout.isCollapsed else { return }
        let label = context.resolve(
            Text(port.definition.displayName).font(.system(size: theme.portFontSize))
                .foregroundColor(Color(theme.portLabel)))
        if port.address.direction == .input {
            context.draw(label, at: CGPoint(x: center.x + r + 6, y: center.y), anchor: .leading)
        } else {
            context.draw(label, at: CGPoint(x: center.x - r - 6, y: center.y), anchor: .trailing)
        }
    }

    private func drawResizeHandle(_ context: inout GraphicsContext, _ layout: NodeLayout) {
        let handle = CGRect(layout.resizeHandle)
        var grip = Path()
        for inset in [4.0, 8.0] {
            grip.move(to: CGPoint(x: handle.maxX - 2, y: handle.maxY - inset))
            grip.addLine(to: CGPoint(x: handle.maxX - inset, y: handle.maxY - 2))
        }
        context.stroke(grip, with: .color(Color(model.theme.selection)), lineWidth: 1.5)
    }
}

extension CGPoint {
    init(_ point: GraphPoint) { self.init(x: point.x, y: point.y) }
}

extension CGRect {
    init(_ rect: GraphRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)
    }
}

extension RGBAColor {
    func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
