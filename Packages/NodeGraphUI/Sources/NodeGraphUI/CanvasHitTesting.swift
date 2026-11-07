import NodeGraphCore

/// Something drawn on the canvas that can be hit or selected.
public enum CanvasItem: Hashable, Sendable {
    case node(NodeID)
    case link(LinkID)
    case group(GroupID)
}

extension GraphEditorModel {
    /// Room added around a link's path bounds, so links just off screen are still drawn and
    /// picking has some slack.
    static var linkBoundsPadding: Double { 24 }

    /// Everything whose bounds intersect `rect`, in draw order (groups, then links, then nodes;
    /// within each, storage order). Use it to draw only what is visible.
    ///
    /// Link bounds are the box around the drawn path, padded; they can include a link
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

    /// The port nearest `point` within `radius` (the metrics' hit radius by default), on the
    /// topmost node that has one.
    public func port(at point: GraphPoint, radius: Double? = nil) -> PortLayout? {
        let radius = radius ?? metrics.portHitRadius
        for item in spatialIndex.ids(at: point, radius: radius).reversed() {
            if case .node(let id) = item, let port = layout(of: id)?.port(at: point, radius: radius) {
                return port
            }
        }
        return nil
    }

    /// The link whose drawn path passes within `tolerance` graph units of `point`, nearest first
    /// choice when several qualify.
    public func link(at point: GraphPoint, tolerance: Double) -> LinkID? {
        var best: (id: LinkID, distance: Double)?
        for item in spatialIndex.ids(at: point, radius: tolerance) {
            guard case .link(let id) = item, let link = graph.links[id],
                  let distance = linkPath(of: link)?.distance(to: point), distance <= tolerance,
                  distance < (best?.distance ?? .infinity) else { continue }
            best = (id, distance)
        }
        return best?.id
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
        guard let bounds = linkPath(of: link)?.bounds() else { return nil }
        let pad = Self.linkBoundsPadding
        return GraphRect(
            x: bounds.minX - pad, y: bounds.minY - pad,
            width: bounds.size.width + 2 * pad, height: bounds.size.height + 2 * pad)
    }
}

/// Core's `Link`, under a name that SwiftUI's `Link` view cannot shadow in files that import both.
typealias GraphLink = Link
