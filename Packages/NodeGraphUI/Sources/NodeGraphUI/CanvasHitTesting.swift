import NodeGraphCore

/// Something drawn on the canvas that can be hit or selected.
public enum CanvasItem: Hashable, Sendable {
    case node(NodeID)
    case link(LinkID)
    case group(GroupID)
}

extension GraphEditorModel {
    /// Room added around a link's end and waypoint box, because the drawn curve bulges outside it.
    static var linkBoundsPadding: Double { 24 }

    /// Everything whose bounds intersect `rect`, in draw order (groups, then links, then nodes;
    /// within each, storage order). Use it to draw only what is visible.
    ///
    /// Link bounds are the box around their ends and waypoints, padded; they can include a link
    /// that is just off screen, never miss one that is on it.
    public func items(in rect: GraphRect) -> [CanvasItem] {
        spatialIndex.ids(in: rect)
    }

    /// The topmost node whose frame contains `point`.
    public func node(at point: GraphPoint) -> NodeID? {
        for item in spatialIndex.ids(at: point).reversed() {
            if case .node(let id) = item, layout(of: id)?.frame.contains(point) == true { return id }
        }
        return nil
    }

    /// The port nearest `point` within the metrics' hit radius, on the topmost node that has one.
    public func port(at point: GraphPoint) -> PortLayout? {
        let radius = metrics.portHitRadius
        for item in spatialIndex.ids(at: point, radius: radius).reversed() {
            if case .node(let id) = item, let port = layout(of: id)?.port(at: point, radius: radius) {
                return port
            }
        }
        return nil
    }

    /// The topmost group whose bounds contain `point`.
    public func group(at point: GraphPoint) -> GroupID? {
        for item in spatialIndex.ids(at: point).reversed() {
            if case .group(let id) = item, graph.groups[id]?.bounds.contains(point) == true { return id }
        }
        return nil
    }

    /// Nodes whose frame intersects `rect`, in storage order. For marquee selection, pass the
    /// marquee; with `fullyInside` only nodes completely within it count.
    public func nodes(in rect: GraphRect, fullyInside: Bool = false) -> [NodeID] {
        items(in: rect).compactMap { item in
            guard case .node(let id) = item, let frame = layout(of: id)?.frame else { return nil }
            return !fullyInside || rect.contains(frame) ? id : nil
        }
    }

    /// The index over groups, links and nodes, rebuilt on first use after any edit.
    var spatialIndex: SpatialIndex<CanvasItem> {
        if let index = cachedSpatialIndex { return index }
        var index = SpatialIndex<CanvasItem>()
        var order = 0
        for group in graph.groups.values {
            index.insert(.group(group.id), rect: group.bounds, order: order)
            order += 1
        }
        for link in graph.links.values {
            if let bounds = linkBounds(link) { index.insert(.link(link.id), rect: bounds, order: order) }
            order += 1
        }
        for node in graph.nodes.values {
            if let frame = layout(of: node.id)?.frame { index.insert(.node(node.id), rect: frame, order: order) }
            order += 1
        }
        cachedSpatialIndex = index
        return index
    }

    private func linkBounds(_ link: Link) -> GraphRect? {
        guard let ends = endpoints(of: link) else { return nil }
        let points = [ends.source, ends.target] + link.waypoints
        let pad = Self.linkBoundsPadding
        let minX = points.map(\.x).min()! - pad, maxX = points.map(\.x).max()! + pad
        let minY = points.map(\.y).min()! - pad, maxY = points.map(\.y).max()! + pad
        return GraphRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
