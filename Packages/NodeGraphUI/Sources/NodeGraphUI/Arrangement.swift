#if !os(tvOS) && !os(watchOS)
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

    /// A link between two items, for ``layered(_:links:spacing:)``.
    public struct Edge: Hashable, Sendable {
        public var from: NodeID
        public var to: NodeID

        public init(from: NodeID, to: NodeID) {
            self.from = from
            self.to = to
        }
    }

    /// Positions for a left-to-right layered layout: a node sits one column right of the furthest
    /// node feeding it, and nodes in a column are ordered to keep links short. The box around the
    /// items keeps its top-left corner. Links that close a loop are ignored for layering, and links
    /// to nodes outside `items` are skipped. Pinned nodes are placed in the layout but never moved.
    public static func layered(
        _ items: [Item], links: [Edge], spacing: GraphSize = GraphSize(width: 80, height: 40)
    ) -> [NodePlacement] {
        guard items.count >= 2 else { return [] }
        // A stable starting order, so the same graph always gives the same layout.
        let sorted = items.sorted {
            ($0.frame.minX, $0.frame.minY, $0.node) < ($1.frame.minX, $1.frame.minY, $1.node)
        }
        var index: [NodeID: Int] = [:]
        for (i, item) in sorted.enumerated() { index[item.node] = i }
        var successors = [[Int]](repeating: [], count: sorted.count)
        var seen = Set<Edge>()
        for link in links where link.from != link.to && seen.insert(link).inserted {
            if let from = index[link.from], let to = index[link.to] { successors[from].append(to) }
        }

        let layer = layers(successors)
        var columns = [[Int]](repeating: [], count: (layer.max() ?? 0) + 1)
        for i in sorted.indices { columns[layer[i]].append(i) }  // already ordered by current y within x
        orderColumns(&columns, successors: successors)

        let minX = sorted.map(\.frame.minX).min()!, minY = sorted.map(\.frame.minY).min()!
        let heights = columns.map { column in
            column.reduce(0) { $0 + sorted[$1].frame.size.height } + spacing.height * Double(max(column.count - 1, 0))
        }
        let tallest = heights.max() ?? 0
        var placements: [NodePlacement] = []
        var x = minX
        for (c, column) in columns.enumerated() {
            var y = minY + (tallest - heights[c]) / 2
            for i in column {
                let item = sorted[i]
                if !item.isPinned, let placement = moved(item, to: GraphPoint(x: x, y: y)) { placements.append(placement) }
                y += item.frame.size.height + spacing.height
            }
            x += column.map { sorted[$0].frame.size.width }.max()! + spacing.width
        }
        return placements
    }

    /// Longest-path layer of every node. Back edges found by a depth-first walk are dropped first,
    /// so a loop still gets a layer for each of its nodes.
    private static func layers(_ successors: [[Int]]) -> [Int] {
        let count = successors.count
        var acyclic = [[Int]](repeating: [], count: count)
        var state = [UInt8](repeating: 0, count: count)  // 0 new, 1 on the walk, 2 done
        for root in 0..<count where state[root] == 0 {
            var work: [(node: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let (node, next) = work.last {
                if next < successors[node].count {
                    work[work.count - 1].next += 1
                    let target = successors[node][next]
                    if state[target] == 1 { continue }  // closes a loop
                    acyclic[node].append(target)
                    if state[target] == 0 {
                        state[target] = 1
                        work.append((target, 0))
                    }
                } else {
                    state[node] = 2
                    work.removeLast()
                }
            }
        }
        var incoming = [Int](repeating: 0, count: count)
        for targets in acyclic { for target in targets { incoming[target] += 1 } }
        var layer = [Int](repeating: 0, count: count)
        var ready = (0..<count).filter { incoming[$0] == 0 }
        while let node = ready.popLast() {
            for target in acyclic[node] {
                layer[target] = max(layer[target], layer[node] + 1)
                incoming[target] -= 1
                if incoming[target] == 0 { ready.append(target) }
            }
        }
        return layer
    }

    /// Reorders each column by the average row of its neighbours in the column before (then
    /// after), a few sweeps, which removes most crossings. Nodes with no neighbours stay put.
    private static func orderColumns(_ columns: inout [[Int]], successors: [[Int]]) {
        var predecessors = [[Int]](repeating: [], count: successors.count)
        for (from, targets) in successors.enumerated() { for to in targets { predecessors[to].append(from) } }
        func sweep(_ order: [Int], neighbours: [[Int]]) {
            var row: [Int: Double] = [:]
            for column in columns { for (r, node) in column.enumerated() { row[node] = Double(r) } }
            for c in order {
                var keys: [Int: Double] = [:]
                for node in columns[c] {
                    let rows = neighbours[node].compactMap { row[$0] }
                    keys[node] = rows.isEmpty ? row[node] : rows.reduce(0, +) / Double(rows.count)
                }
                columns[c].sort { (keys[$0] ?? 0, row[$0] ?? 0) < (keys[$1] ?? 0, row[$1] ?? 0) }
                for (r, node) in columns[c].enumerated() { row[node] = Double(r) }
            }
        }
        for _ in 0..<4 {
            sweep(Array(columns.indices.dropFirst()), neighbours: predecessors)
            sweep(Array(columns.indices.dropLast().reversed()), neighbours: successors)
        }
    }

    private static func moved(_ item: Item, to origin: GraphPoint) -> NodePlacement? {
        let old = item.frame.origin
        guard abs(old.x - origin.x) > 1e-9 || abs(old.y - origin.y) > 1e-9 else { return nil }
        return NodePlacement(node: item.node, position: origin)
    }
}
#endif
