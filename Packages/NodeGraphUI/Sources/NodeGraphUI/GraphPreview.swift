#if !os(tvOS) && !os(watchOS)
import NodeGraphCore
import SwiftUI

/// What a proposed change would do to the open graph, for the canvas to draw as a ghost: nodes and
/// links it adds, nodes and links it removes, and nodes it alters. Nothing here is applied; the
/// host accepts by performing the change's command through the model (one undo step) and rejects
/// by clearing ``GraphEditorModel/preview``.
public struct GraphPreview: Sendable {
    /// The graph as it would be after the change.
    public let result: Graph
    public let addedNodes: Set<NodeID>
    public let removedNodes: Set<NodeID>
    /// Nodes in both graphs that differ (properties, title, mode, position).
    public let changedNodes: Set<NodeID>
    public let addedLinks: Set<LinkID>
    public let removedLinks: Set<LinkID>

    /// Compares `base` with `result` by identity: ids only in `result` are added, ids only in
    /// `base` are removed, and ids in both whose value differs are changed.
    public init(base: Graph, result: Graph) {
        self.result = result
        let before = Set(base.nodes.keys), after = Set(result.nodes.keys)
        addedNodes = after.subtracting(before)
        removedNodes = before.subtracting(after)
        changedNodes = before.intersection(after).filter { base.nodes[$0] != result.nodes[$0] }
        let linksBefore = Set(base.links.keys), linksAfter = Set(result.links.keys)
        addedLinks = linksAfter.subtracting(linksBefore)
        removedLinks = linksBefore.subtracting(linksAfter)
    }

    public var isEmpty: Bool {
        addedNodes.isEmpty && removedNodes.isEmpty && changedNodes.isEmpty
            && addedLinks.isEmpty && removedLinks.isEmpty
    }

    /// Nodes drawn from the result graph instead of the open one.
    var ghostNodes: Set<NodeID> { addedNodes.union(changedNodes) }
}

extension GraphEditorModel {
    /// The geometry of a node of the preview's result graph, or nil if it is not one.
    func ghostLayout(of id: NodeID) -> NodeLayout? {
        guard let node = preview?.result.nodes[id] else { return nil }
        let definition = definition(of: node)
        return NodeLayout(
            node: node, definition: definition, widgets: widgetSpecs(for: node, definition: definition),
            contentHeight: contentDrawings[node.typeID]?.height ?? 0, metrics: layoutMetrics)
    }
}

extension GraphCanvasRenderer {
    /// Draws the pending change over the graph: removed things struck in red, added things as
    /// translucent copies with a dashed outline, altered nodes ringed.
    func drawPreview(_ context: inout GraphicsContext, _ preview: GraphPreview, visible: GraphRect, lod: LevelOfDetail) {
        let theme = model.theme
        let zoom = model.camera.zoom
        let added = Color(theme.selection), removed = Color(theme.failed)
        let line: CGFloat = max(2, 2 / zoom)
        let dash: [CGFloat] = [6 / zoom, 4 / zoom]

        func layout(_ id: NodeID) -> NodeLayout? {
            preview.ghostNodes.contains(id) ? model.ghostLayout(of: id) : model.layout(of: id)
        }
        func route(_ link: GraphLink, using layout: (NodeID) -> NodeLayout?) -> Path? {
            guard let source = layout(link.source.node), let target = layout(link.target.node) else { return nil }
            let start = source.port(link.source)?.position
                ?? GraphPoint(x: source.frame.maxX, y: source.frame.minY + source.header.size.height / 2)
            let end = target.port(link.target)?.position
                ?? GraphPoint(x: target.frame.minX, y: target.frame.minY + target.header.size.height / 2)
            let route = LinkPath(from: start, to: end, waypoints: link.waypoints, style: model.linkStyle)
            var path = Path()
            path.move(to: CGPoint(route.start))
            for segment in route.segments {
                switch segment {
                case .line(let to): path.addLine(to: CGPoint(to))
                case .cubic(let c1, let c2, let to): path.addCurve(to: CGPoint(to), control1: CGPoint(c1), control2: CGPoint(c2))
                }
            }
            return path
        }

        for id in preview.removedLinks {
            guard let link = model.graph.links[id], let path = route(link, using: { model.layout(of: $0) }) else { continue }
            context.stroke(path, with: .color(removed.opacity(0.8)), style: StrokeStyle(lineWidth: line, lineCap: .round, dash: dash))
        }
        for id in preview.addedLinks {
            guard let link = preview.result.links[id], let path = route(link, using: layout) else { continue }
            context.stroke(path, with: .color(added.opacity(0.9)), style: StrokeStyle(lineWidth: line, lineCap: .round, dash: dash))
        }
        for id in preview.removedNodes {
            guard let frame = model.layout(of: id)?.frame, frame.intersects(visible) else { continue }
            let rect = CGRect(frame)
            context.fill(Path(roundedRect: rect, cornerRadius: theme.cornerRadius), with: .color(removed.opacity(0.18)))
            context.stroke(
                Path(roundedRect: rect, cornerRadius: theme.cornerRadius), with: .color(removed),
                style: StrokeStyle(lineWidth: line, dash: dash))
            var cross = Path()
            cross.move(to: CGPoint(x: rect.minX, y: rect.minY)); cross.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            cross.move(to: CGPoint(x: rect.maxX, y: rect.minY)); cross.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.stroke(cross, with: .color(removed.opacity(0.7)), lineWidth: line)
        }
        for id in preview.addedNodes {
            guard let ghost = model.ghostLayout(of: id), ghost.frame.intersects(visible),
                  let node = preview.result.nodes[id] else { continue }
            context.drawLayer { layer in
                layer.opacity = 0.55
                drawNodeContents(&layer, node, ghost, lod: lod)
            }
            let rect = CGRect(ghost.frame)
            context.stroke(
                Path(roundedRect: rect, cornerRadius: theme.cornerRadius), with: .color(added),
                style: StrokeStyle(lineWidth: line, dash: dash))
        }
        for id in preview.changedNodes {
            guard let ghost = model.ghostLayout(of: id), ghost.frame.intersects(visible) else { continue }
            let rect = CGRect(ghost.frame).insetBy(dx: -4 / zoom, dy: -4 / zoom)
            context.stroke(
                Path(roundedRect: rect, cornerRadius: theme.cornerRadius + 4 / zoom), with: .color(added),
                style: StrokeStyle(lineWidth: line, dash: dash))
        }
    }
}
#endif
