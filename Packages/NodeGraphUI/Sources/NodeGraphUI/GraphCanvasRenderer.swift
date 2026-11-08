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

        // A faint wash tells you that you are inside a subgraph, not at the top level.
        if model.currentScope != nil {
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(theme.selection.withAlpha(0.05))))
        }

        let visible = camera.visibleRect(in: size)
        // Drawn last, in screen space, so it keeps a copy of the context before the camera is applied.
        var screenContext = context
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
        if model.showsExecutionOrder, lod.tier == .full {
            for (id, number) in model.executionOrder {
                if let frame = model.layout(of: id)?.frame, frame.intersects(visible) {
                    drawOrderBadge(&context, number: number, on: frame)
                }
            }
        }
        if let draft = controller?.draft { drawDraft(&context, draft) }
        if let marquee = controller?.marquee { drawMarquee(&context, marquee) }
        if model.showsStats { drawStats(&screenContext) }
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
                Text(group.title).font(.system(size: theme.titleFontSize * model.textScale, weight: .semibold))
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
        let hovered = controller?.hover == .link(link.id)
        let width = max(theme.linkWidth, 1.5 / model.camera.zoom) * (selected ? 1.5 : hovered ? 1.35 : 1)
        context.stroke(path, with: .color(Color(color)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        if model.showsLinkArrows, lod.tier == .full { drawLinkArrow(&context, link, color: color) }
        // The value passing along a link, while the pointer is on it or it is selected.
        if (selected || hovered), lod.tier == .full, let text = model.valueLabel(of: link),
           let route = model.linkPath(of: link) {
            drawLinkLabel(&context, text, at: CGPoint(route.midpoint()))
        }
    }

    private func drawLinkLabel(_ context: inout GraphicsContext, _ text: String, at point: CGPoint) {
        let theme = model.theme
        let size = theme.portFontSize * model.textScale
        let resolved = context.resolve(
            Text(text).font(.system(size: size, design: .monospaced)).foregroundColor(Color(theme.nodeTitle)))
        let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        let pill = CGRect(
            x: point.x - measured.width / 2 - 6, y: point.y - measured.height / 2 - 3,
            width: measured.width + 12, height: measured.height + 6)
        context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color(theme.nodeBody)))
        context.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Color(theme.nodeBorder)), lineWidth: 1)
        context.draw(resolved, at: point, anchor: .center)
    }

    // MARK: Nodes

    private func drawNode(_ context: inout GraphicsContext, _ layout: NodeLayout, lod: LevelOfDetail) {
        guard let node = model.graph.nodes[layout.node] else { return }
        // Only a dimmed node needs an offscreen layer, to fade the node as one piece. Layers are
        // costly (each is a canvas-sized buffer), so every other node is drawn straight on.
        if node.mode == .never || node.mode == .muted || node.mode == .bypassed {
            context.drawLayer { layer in
                layer.opacity = model.theme.inactiveOpacity
                drawNodeContents(&layer, node, layout, lod: lod)
            }
        } else {
            drawNodeContents(&context, node, layout, lod: lod)
        }
    }

    private func drawNodeContents(
        _ context: inout GraphicsContext, _ node: Node, _ layout: NodeLayout, lod: LevelOfDetail
    ) {
        let theme = model.theme
        let zoom = model.camera.zoom
        let frame = CGRect(layout.frame)
        let selected = model.selection.nodes.contains(node.id)
        let definition = model.definition(of: node)
        let corners = NodeCorners.radii(
            for: node.resolvedShape(in: definition), radius: lod.drawsRoundedCorners ? theme.cornerRadius : 0)
        let shape = corners.shape.path(in: frame)
        let hovered = controller?.hover == .node(node.id)
        let titleStyle = TitleStyle(node.resolvedTitleMode(in: definition), isActive: selected || hovered)
        let headerColor = node.color ?? theme.nodeHeader

        if lod.tier == .minimal {
            context.fill(shape, with: .color(Color(headerColor)))
        } else {
            context.fill(shape, with: .color(Color(theme.nodeBody)))
            // The bar is the top of the node, so it takes the node's top corners (and the bottom
            // ones too when the node is collapsed to just a bar). That matches the body's outline
            // without clipping.
            if titleStyle.drawsBar {
                context.fill(
                    corners.header(isCollapsed: layout.isCollapsed).shape.path(in: CGRect(layout.header)),
                    with: .color(Color(headerColor)))
            }
        }
        let decoration = model.runDecoration(of: node.id)
        var border = selected ? theme.selection : hovered ? theme.selection.withAlpha(0.55) : theme.nodeBorder
        var borderWidth = selected || hovered ? 2.0 : theme.borderWidth
        // A running or failed node shows it even when selected (the selection still thickens the line).
        if let decoration, decoration.tintsBorder {
            border = theme.color(for: decoration.badge)
            borderWidth = max(borderWidth, 2)
        }
        context.stroke(shape, with: .color(Color(border)), lineWidth: max(borderWidth, 1 / zoom))

        if lod.drawsTitles, titleStyle.drawsTitle {
            let title = node.title ?? model.definition(of: node)?.displayName ?? node.typeID.rawValue
            let text = fittedTitle(&context, title, width: layout.header.size.width - 20)
            context.draw(
                text, at: CGPoint(x: layout.header.minX + 10, y: layout.header.minY + layout.header.size.height / 2),
                anchor: .leading)
            // Two overlapping squares mark an instance of a subgraph, which can be opened.
            if node.typeID.subgraphID != nil {
                let size = 9.0
                let origin = CGPoint(x: layout.header.maxX - 24, y: layout.header.minY + layout.header.size.height / 2 - size / 2 - 1)
                let color = Color(theme.nodeTitle.withAlpha(0.8))
                context.stroke(RoundedRectangle(cornerRadius: 2).path(in: CGRect(x: origin.x + 4, y: origin.y - 3, width: size, height: size)), with: .color(color), lineWidth: 1.2)
                context.stroke(RoundedRectangle(cornerRadius: 2).path(in: CGRect(x: origin.x, y: origin.y + 1, width: size, height: size)), with: .color(color), lineWidth: 1.2)
            }
        }
        if lod.drawsPorts {
            for port in layout.inputs + layout.outputs { drawPort(&context, port, layout: layout, lod: lod) }
        }
        if lod.tier == .full {
            for widget in layout.widgets { drawWidget(&context, widget, on: node) }
        }
        if lod.tier == .full, let area = layout.content, let drawing = model.contentDrawings[node.typeID] {
            // Clipped so a drawing that overruns its area cannot cover ports or neighbours.
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(area)))
                drawing.draw(
                    &layer,
                    NodeContentContext(
                        node: node, definition: model.definition(of: node), rect: CGRect(area), theme: theme,
                        zoom: zoom, values: model.runValues[node.id]))
            }
        }
        if selected, !layout.isCollapsed, lod.tier == .full { drawResizeHandle(&context, layout) }
        if let decoration { drawRunDecoration(&context, decoration, layout: layout, lod: lod) }
    }

    // MARK: Execution state

    private func drawRunDecoration(
        _ context: inout GraphicsContext, _ decoration: NodeRunDecoration, layout: NodeLayout, lod: LevelOfDetail
    ) {
        let theme = model.theme
        let frame = CGRect(layout.frame)
        let color = Color(theme.color(for: decoration.badge))

        // Progress runs along the bottom edge, inside the node.
        if let progress = decoration.progress, lod.tier != .minimal {
            let track = CGRect(x: frame.minX + 4, y: frame.maxY - 6, width: frame.width - 8, height: 3)
            context.fill(Capsule().path(in: track), with: .color(Color(theme.background.withAlpha(0.7))))
            var fill = track
            fill.size.width = track.width * progress
            if fill.width > 0 { context.fill(Capsule().path(in: fill), with: .color(color)) }
        }

        // The badge sits on the top-right corner, clear of the title and the subgraph mark. At the
        // smallest level of detail it is enlarged, since it may be all that is readable.
        let r = lod.tier == .minimal ? 10.0 : 6.0
        let center = CGPoint(x: frame.maxX, y: frame.minY)
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        context.fill(disc, with: .color(color))
        context.stroke(disc, with: .color(Color(theme.background)), lineWidth: 1.5)
        if lod.tier != .minimal { drawBadgeGlyph(&context, decoration.badge, at: center, radius: r) }

        // The reason a node failed, under it, where it does not cover a neighbour's ports.
        if decoration.badge == .failed, let message = decoration.message, lod.tier == .full {
            let text = fittedText(&context, message, width: max(frame.width, 120), color: Color(theme.failed))
            context.draw(text, at: CGPoint(x: frame.minX + 2, y: frame.maxY + 4), anchor: .topLeading)
        }
    }

    /// A small mark inside the badge so state does not rest on color alone.
    private func drawBadgeGlyph(_ context: inout GraphicsContext, _ badge: NodeRunDecoration.Badge, at c: CGPoint, radius r: Double) {
        let k = r * 0.45
        var glyph = Path()
        switch badge {
        case .running:
            glyph.move(to: CGPoint(x: c.x - k * 0.5, y: c.y - k))
            glyph.addLine(to: CGPoint(x: c.x + k, y: c.y))
            glyph.addLine(to: CGPoint(x: c.x - k * 0.5, y: c.y + k))
            glyph.closeSubpath()
            context.fill(glyph, with: .color(.white))
            return
        case .succeeded, .cached:
            glyph.move(to: CGPoint(x: c.x - k, y: c.y))
            glyph.addLine(to: CGPoint(x: c.x - k * 0.2, y: c.y + k * 0.8))
            glyph.addLine(to: CGPoint(x: c.x + k, y: c.y - k * 0.7))
        case .failed:
            glyph.move(to: CGPoint(x: c.x - k * 0.8, y: c.y - k * 0.8))
            glyph.addLine(to: CGPoint(x: c.x + k * 0.8, y: c.y + k * 0.8))
            glyph.move(to: CGPoint(x: c.x + k * 0.8, y: c.y - k * 0.8))
            glyph.addLine(to: CGPoint(x: c.x - k * 0.8, y: c.y + k * 0.8))
        case .cancelled, .skipped:
            glyph.move(to: CGPoint(x: c.x - k, y: c.y))
            glyph.addLine(to: CGPoint(x: c.x + k, y: c.y))
        }
        context.stroke(glyph, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
    }

    /// The title as resolved text that fits in `width`, shortened with an ellipsis if it must
    /// be. Cutting the text is much cheaper than clipping it.
    private func fittedTitle(_ context: inout GraphicsContext, _ title: String, width: Double) -> GraphicsContext.ResolvedText {
        let theme = model.theme
        func resolve(_ string: String) -> GraphicsContext.ResolvedText {
            context.resolve(
                Text(string).font(.system(size: theme.titleFontSize * model.textScale, weight: .semibold))
                    .foregroundColor(Color(theme.nodeTitle)))
        }
        let full = resolve(title)
        let measured = full.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
        guard measured > width, width > 0 else { return full }
        let keep = max(1, Int(Double(title.count) * width / measured) - 1)
        return resolve(String(title.prefix(keep)) + "…")
    }

    // MARK: Widgets

    private func drawWidget(_ context: inout GraphicsContext, _ widget: WidgetLayout, on node: Node) {
        let theme = model.theme
        let spec = widget.spec
        let rect = CGRect(widget.frame)
        let value = node.properties[spec.property ?? ""] ?? spec.property.flatMap { id in
            model.definition(of: node)?.property(id)?.defaultValue
        }
        let isEditing = controller?.editor.map { $0.node == node.id && $0.spec.id == spec.id } ?? false
        let field = RoundedRectangle(cornerRadius: 4).path(in: rect)
        let fieldFill = Color(theme.background.withAlpha(0.7))
        let labelColor = Color(theme.portLabel)
        let valueColor = Color(theme.nodeTitle)

        func text(_ string: String, at point: CGPoint, anchor: UnitPoint, color: Color, width: Double) {
            guard width > 4 else { return }
            let resolved = fittedText(&context, string, width: width, color: color)
            context.draw(resolved, at: point, anchor: anchor)
        }

        // Label on the left, control on the right, for the rows that have both.
        let split = rect.minX + rect.width * 0.42
        let control = CGRect(x: split, y: rect.minY, width: rect.maxX - split, height: rect.height).insetBy(dx: 0, dy: 2)
        func label() {
            text(spec.title, at: CGPoint(x: rect.minX + 2, y: rect.midY), anchor: .leading, color: labelColor, width: split - rect.minX - 8)
        }

        switch spec.kind {
        case .slider:
            let fraction = value.flatMap { spec.kind.fraction(of: $0) } ?? 0
            let track = rect.insetBy(dx: 0, dy: 2)
            context.fill(RoundedRectangle(cornerRadius: 4).path(in: track), with: .color(fieldFill))
            var fill = track
            fill.size.width = track.width * fraction
            if fill.width > 0 {
                context.fill(RoundedRectangle(cornerRadius: 4).path(in: fill), with: .color(Color(theme.selection.withAlpha(0.45))))
            }
            text(spec.title, at: CGPoint(x: track.minX + 6, y: track.midY), anchor: .leading, color: labelColor, width: track.width * 0.55)
            text(spec.kind.display(value), at: CGPoint(x: track.maxX - 6, y: track.midY), anchor: .trailing, color: valueColor, width: track.width * 0.4)

        case .toggle:
            label()
            let on: Bool = if case .bool(let b)? = value { b } else { false }
            let pill = CGRect(x: control.maxX - 32, y: control.midY - 8, width: 32, height: 16)
            context.fill(Capsule().path(in: pill), with: .color(on ? Color(theme.selection) : Color(theme.nodeBorder)))
            let knob = CGRect(x: on ? pill.maxX - 14 : pill.minX + 2, y: pill.minY + 2, width: 12, height: 12)
            context.fill(Circle().path(in: knob), with: .color(.white))

        case .number, .text, .readOnly:
            label()
            if !isEditing {
                context.fill(RoundedRectangle(cornerRadius: 4).path(in: control), with: .color(fieldFill))
                let isNumber: Bool = if case .number = spec.kind { true } else { false }
                text(
                    spec.kind.display(value), at: CGPoint(x: isNumber ? control.midX : control.minX + 6, y: control.midY),
                    anchor: isNumber ? .center : .leading, color: valueColor, width: control.width - 12)
            }

        case .multilineText:
            context.fill(field, with: .color(fieldFill))
            text(spec.title, at: CGPoint(x: rect.minX + 6, y: rect.minY + 8), anchor: .leading, color: labelColor, width: rect.width - 12)
            if !isEditing {
                text(spec.kind.display(value), at: CGPoint(x: rect.minX + 6, y: rect.minY + 26), anchor: .leading, color: valueColor, width: rect.width - 12)
            }

        case .combo:
            label()
            context.fill(RoundedRectangle(cornerRadius: 4).path(in: control), with: .color(fieldFill))
            text(spec.kind.display(value), at: CGPoint(x: control.minX + 6, y: control.midY), anchor: .leading, color: valueColor, width: control.width - 24)
            text("▾", at: CGPoint(x: control.maxX - 8, y: control.midY), anchor: .center, color: labelColor, width: 12)

        case .color:
            label()
            let swatch = control.insetBy(dx: 0, dy: 1)
            if case .color(let color)? = value {
                context.fill(RoundedRectangle(cornerRadius: 4).path(in: swatch), with: .color(Color(color)))
                context.stroke(RoundedRectangle(cornerRadius: 4).path(in: swatch), with: .color(Color(theme.nodeBorder)), lineWidth: 1)
            }

        case .button:
            let button = rect.insetBy(dx: 0, dy: 2)
            context.fill(RoundedRectangle(cornerRadius: 5).path(in: button), with: .color(Color(theme.nodeHeader)))
            context.stroke(RoundedRectangle(cornerRadius: 5).path(in: button), with: .color(Color(theme.nodeBorder)), lineWidth: 1)
            text(spec.title, at: CGPoint(x: button.midX, y: button.midY), anchor: .center, color: valueColor, width: button.width - 12)

        case .custom(let name):
            label()
            if let renderer = model.widgetRenderers[name] {
                renderer(&context, control, value, theme)
            } else {
                text(spec.kind.display(value), at: CGPoint(x: control.minX + 6, y: control.midY), anchor: .leading, color: valueColor, width: control.width - 12)
            }
        }
    }

    /// `string` as resolved text no wider than `width`, shortened with an ellipsis if need be.
    private func fittedText(
        _ context: inout GraphicsContext, _ string: String, width: Double, color: Color
    ) -> GraphicsContext.ResolvedText {
        let size = model.theme.portFontSize * model.textScale
        func resolve(_ value: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(value).font(.system(size: size)).foregroundColor(color))
        }
        let full = resolve(string)
        let measured = full.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
        guard measured > width, !string.isEmpty else { return full }
        let keep = max(1, Int(Double(string.count) * width / measured) - 1)
        return resolve(String(string.prefix(keep)) + "…")
    }

    private func drawPort(_ context: inout GraphicsContext, _ port: PortLayout, layout: NodeLayout, lod: LevelOfDetail) {
        let theme = model.theme
        let metrics = model.metrics
        let center = CGPoint(port.position)
        let r = metrics.portRadius
        let color = Color(model.color(of: port.definition))
        let connected = port.address.direction == .input
            ? !model.graph.links(into: port.address).isEmpty : !model.graph.links(from: port.address).isEmpty

        let shape = model.portShape(of: port.definition).path(center: center, radius: r)
        if connected {
            context.fill(shape, with: .color(color))
        } else {
            context.fill(shape, with: .color(Color(theme.nodeBody)))
            context.stroke(shape, with: .color(color), lineWidth: 1.5)
        }

        if controller?.hover == .port(port.address) {
            let ring = r + 3
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: 2 * ring, height: 2 * ring)),
                with: .color(color.opacity(0.7)), lineWidth: 1.5)
        }

        guard lod.drawsPortLabels, !layout.isCollapsed else { return }
        let label = context.resolve(
            Text(port.definition.displayName).font(.system(size: theme.portFontSize * model.textScale))
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
