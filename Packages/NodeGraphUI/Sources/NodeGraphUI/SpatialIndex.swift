import NodeGraphCore

/// A uniform-grid index of rectangles in graph space, for finding what is under a point or
/// inside a region without scanning everything.
///
/// Each item is registered in every grid cell its rectangle touches. Items that touch more than
/// ``largeItemCellLimit`` cells (a group around half the graph, say) go in a short separate list
/// instead, which every query checks. Results come back sorted by the `order` given at insertion,
/// so callers can use draw order as z-order: the last result is the topmost.
public struct SpatialIndex<ID: Hashable & Sendable>: Sendable {
    /// Items touching more cells than this are kept out of the grid.
    public static var largeItemCellLimit: Int { 64 }

    private struct Cell: Hashable, Sendable {
        var x: Int
        var y: Int
    }

    private struct Entry: Sendable {
        var rect: GraphRect
        var order: Int
    }

    private struct CellRange {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var count: Int { (maxX - minX + 1) * (maxY - minY + 1) }
    }

    public let cellSize: Double
    private var entries: [ID: Entry] = [:]
    private var cells: [Cell: [ID]] = [:]
    private var large: [ID] = []

    public init(cellSize: Double = 256) {
        self.cellSize = max(cellSize, 1)
    }

    public var count: Int { entries.count }

    /// Adds an item, or moves it if `id` is already present.
    public mutating func insert(_ id: ID, rect: GraphRect, order: Int) {
        remove(id)
        entries[id] = Entry(rect: rect, order: order)
        guard let range = cellRange(of: rect), range.count <= Self.largeItemCellLimit else {
            large.append(id)
            return
        }
        for x in range.minX...range.maxX {
            for y in range.minY...range.maxY {
                cells[Cell(x: x, y: y), default: []].append(id)
            }
        }
    }

    public mutating func remove(_ id: ID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        guard let range = cellRange(of: entry.rect), range.count <= Self.largeItemCellLimit else {
            large.removeAll { $0 == id }
            return
        }
        for x in range.minX...range.maxX {
            for y in range.minY...range.maxY {
                let cell = Cell(x: x, y: y)
                guard var ids = cells[cell], let at = ids.firstIndex(of: id) else { continue }
                ids.remove(at: at)
                cells[cell] = ids.isEmpty ? nil : ids
            }
        }
    }

    /// Items whose rectangle intersects `rect` (touching edges count), lowest order first.
    public func ids(in rect: GraphRect) -> [ID] {
        var found: [(id: ID, order: Int)] = []
        let range = cellRange(of: rect)
        if let range, range.count <= entries.count {
            var seen = Set<ID>()
            for x in range.minX...range.maxX {
                for y in range.minY...range.maxY {
                    for id in cells[Cell(x: x, y: y)] ?? [] where seen.insert(id).inserted {
                        if let entry = entries[id], entry.rect.intersects(rect) { found.append((id, entry.order)) }
                    }
                }
            }
            for id in large {
                if let entry = entries[id], entry.rect.intersects(rect) { found.append((id, entry.order)) }
            }
        } else {
            // A region covering more cells than there are items: scanning the items is cheaper.
            for (id, entry) in entries where entry.rect.intersects(rect) { found.append((id, entry.order)) }
        }
        return found.sorted { $0.order < $1.order }.map(\.id)
    }

    /// Items whose rectangle lies within `radius` of `point` (rectangle grown by `radius`),
    /// lowest order first.
    public func ids(at point: GraphPoint, radius: Double = 0) -> [ID] {
        ids(in: GraphRect(
            x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
    }

    private func cellRange(of rect: GraphRect) -> CellRange? {
        let values = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        guard values.allSatisfy({ $0.isFinite && abs($0 / cellSize) < 1e9 }) else { return nil }
        return CellRange(
            minX: Int((rect.minX / cellSize).rounded(.down)), maxX: Int((rect.maxX / cellSize).rounded(.down)),
            minY: Int((rect.minY / cellSize).rounded(.down)), maxY: Int((rect.maxY / cellSize).rounded(.down)))
    }
}
