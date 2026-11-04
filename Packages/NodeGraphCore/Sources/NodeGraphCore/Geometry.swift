/// A point in graph (canvas) space. Core defines its own geometry so it never imports CoreGraphics.
public struct GraphPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = GraphPoint(x: 0, y: 0)
}

/// A size in graph space.
public struct GraphSize: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// An axis-aligned rectangle in graph space. `origin` is the minimum corner.
public struct GraphRect: Hashable, Sendable, Codable {
    public var origin: GraphPoint
    public var size: GraphSize

    public init(origin: GraphPoint, size: GraphSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: GraphPoint(x: x, y: y), size: GraphSize(width: width, height: height))
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    /// Whether `point` lies inside the rectangle, edges included.
    public func contains(_ point: GraphPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Whether `other` lies entirely inside the rectangle, edges included.
    public func contains(_ other: GraphRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    /// Whether the rectangles overlap. Touching edges count as overlapping.
    public func intersects(_ other: GraphRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }
}
