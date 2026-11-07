import NodeGraphCore

/// Which edge or center nodes line up on.
public enum AlignEdge: String, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom
    /// Middles on one vertical line.
    case centerX
    /// Middles on one horizontal line.
    case centerY

    public var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        case .centerX: "Center Horizontally"
        case .centerY: "Center Vertically"
        }
    }
}

public enum DistributeAxis: String, Hashable, Sendable, CaseIterable {
    case horizontal, vertical

    public var title: String { self == .horizontal ? "Horizontally" : "Vertically" }
}

/// Where nodes should go to line up or to be evenly spaced. Pure geometry: it takes frames and
/// returns the new positions, so it is tested without any editor.
public enum Arrangement {
    public struct Item: Hashable, Sendable {
        public var node: NodeID
        public var frame: GraphRect
        /// A pinned node is measured but never moved.
        public var isPinned: Bool

        public init(node: NodeID, frame: GraphRect, isPinned: Bool = false) {
            self.node = node
            self.frame = frame
            self.isPinned = isPinned
        }
    }

    /// Positions that line the items up on `edge` of the rectangle holding all of them. Only
    /// nodes that actually move are returned. Needs at least two items.
    public static func aligned(_ items: [Item], to edge: AlignEdge) -> [NodePlacement] {
        guard items.count >= 2 else { return [] }
        let minX = items.map(\.frame.minX).min()!, maxX = items.map(\.frame.maxX).max()!
        let minY = items.map(\.frame.minY).min()!, maxY = items.map(\.frame.maxY).max()!
        return items.compactMap { item in
            guard !item.isPinned else { return nil }
            var origin = item.frame.origin
            switch edge {
            case .left: origin.x = minX
            case .right: origin.x = maxX - item.frame.size.width
            case .top: origin.y = minY
            case .bottom: origin.y = maxY - item.frame.size.height
            case .centerX: origin.x = (minX + maxX) / 2 - item.frame.size.width / 2
            case .centerY: origin.y = (minY + maxY) / 2 - item.frame.size.height / 2
            }
            return moved(item, to: origin)
        }
    }

    /// Positions that space the items evenly along `axis`: the outermost two stay where they are
    /// and the gaps between neighbours become equal. Needs at least three items. A pinned node
    /// does not move, so it can leave its gap uneven.
    public static func distributed(_ items: [Item], along axis: DistributeAxis) -> [NodePlacement] {
        guard items.count >= 3 else { return [] }
        let horizontal = axis == .horizontal
        func start(_ rect: GraphRect) -> Double { horizontal ? rect.minX : rect.minY }
        func end(_ rect: GraphRect) -> Double { horizontal ? rect.maxX : rect.maxY }
        func length(_ rect: GraphRect) -> Double { horizontal ? rect.size.width : rect.size.height }

        let ordered = items.sorted { start($0.frame) < start($1.frame) }
        let span = ordered.map { end($0.frame) }.max()! - start(ordered[0].frame)
        let gap = (span - ordered.reduce(0) { $0 + length($1.frame) }) / Double(ordered.count - 1)
        var cursor = start(ordered[0].frame)
        var placements: [NodePlacement] = []
        for item in ordered {
            if !item.isPinned {
                var origin = item.frame.origin
                if horizontal { origin.x = cursor } else { origin.y = cursor }
                if let placement = moved(item, to: origin) { placements.append(placement) }
            }
            cursor += length(item.frame) + gap
        }
        return placements
    }

    private static func moved(_ item: Item, to origin: GraphPoint) -> NodePlacement? {
        let old = item.frame.origin
        guard abs(old.x - origin.x) > 1e-9 || abs(old.y - origin.y) > 1e-9 else { return nil }
        return NodePlacement(node: item.node, position: origin)
    }
}
