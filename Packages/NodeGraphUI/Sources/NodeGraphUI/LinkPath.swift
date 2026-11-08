import Foundation
import NodeGraphCore

/// How links are drawn.
public enum LinkStyle: String, Hashable, Sendable, Codable, CaseIterable {
    /// Smooth curves leaving and entering ports horizontally.
    case spline
    /// Straight segments, with a short horizontal stub at each port.
    case linear
    /// Horizontal and vertical segments only.
    case orthogonal
}

/// The route of one link in graph space: a start point and the segments that follow. Pure
/// geometry, so drawing, picking and bounds all use the same path.
public struct LinkPath: Hashable, Sendable {
    public enum Segment: Hashable, Sendable {
        case line(to: GraphPoint)
        case cubic(control1: GraphPoint, control2: GraphPoint, to: GraphPoint)

        public var end: GraphPoint {
            switch self {
            case .line(let to), .cubic(_, _, let to): to
            }
        }
    }

    /// Length of the horizontal run at a port for ``LinkStyle/linear``.
    public static let stubLength = 16.0

    public var start: GraphPoint
    public var segments: [Segment]

    /// The route from `start` (an output port) to `end` (an input port) through `waypoints`.
    public init(from start: GraphPoint, to end: GraphPoint, waypoints: [GraphPoint] = [], style: LinkStyle) {
        self.start = start
        let stops = [start] + waypoints + [end]
        switch style {
        case .spline:
            segments = zip(stops, stops.dropFirst()).map { a, b in
                // The handle grows with the gap so short links stay tight and long ones sweep.
                let reach = min(max(a.distance(to: b) * 0.4, 30), 200)
                return .cubic(
                    control1: GraphPoint(x: a.x + reach, y: a.y),
                    control2: GraphPoint(x: b.x - reach, y: b.y), to: b)
            }
        case .linear:
            let stub = Self.stubLength
            var route = [GraphPoint(x: start.x + stub, y: start.y)]
            route += waypoints
            route.append(GraphPoint(x: end.x - stub, y: end.y))
            segments = (route + [end]).map { .line(to: $0) }
        case .orthogonal:
            segments = zip(stops, stops.dropFirst()).flatMap { a, b -> [Segment] in
                let middle = (a.x + b.x) / 2
                return [
                    .line(to: GraphPoint(x: middle, y: a.y)),
                    .line(to: GraphPoint(x: middle, y: b.y)),
                    .line(to: b),
                ]
            }
        }
    }

    public var end: GraphPoint { segments.last?.end ?? start }

    /// The path as a polyline, each curve cut into `curveSteps` straight pieces.
    public func polyline(curveSteps: Int = 16) -> [GraphPoint] {
        var points = [start]
        var current = start
        for segment in segments {
            switch segment {
            case .line(let to):
                points.append(to)
            case .cubic(let c1, let c2, let to):
                let steps = max(curveSteps, 1)
                for step in 1...steps {
                    let t = Double(step) / Double(steps), u = 1 - t
                    points.append(GraphPoint(
                        x: u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * to.x,
                        y: u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * to.y))
                }
            }
            current = segment.end
        }
        return points
    }

    /// The point halfway along the path, by length, for labels that sit on a link.
    public func midpoint(curveSteps: Int = 16) -> GraphPoint {
        midpointWithDirection(curveSteps: curveSteps).point
    }

    /// The point halfway along the path and the way the path is heading there, in radians
    /// (0 is toward +x, as in graph space where y grows downward), for arrowheads.
    public func midpointWithDirection(curveSteps: Int = 16) -> (point: GraphPoint, angle: Double) {
        let points = polyline(curveSteps: curveSteps)
        let pieces = zip(points, points.dropFirst()).map { ($0, $1, $0.distance(to: $1)) }
        var remaining = pieces.reduce(0) { $0 + $1.2 } / 2
        for (a, b, length) in pieces {
            if remaining <= length, length > 0 {
                let t = remaining / length
                return (GraphPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
            }
            remaining -= length
        }
        return (points[points.count - 1], 0)
    }

    /// Shortest distance from `point` to the path.
    public func distance(to point: GraphPoint, curveSteps: Int = 16) -> Double {
        let points = polyline(curveSteps: curveSteps)
        guard points.count > 1 else { return points[0].distance(to: point) }
        return zip(points, points.dropFirst()).map { Self.distance(from: point, toSegment: $0, $1) }.min() ?? 0
    }

    /// A box that contains the whole path, curves included.
    public func bounds(curveSteps: Int = 16) -> GraphRect {
        let points = polyline(curveSteps: curveSteps)
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? start.x, minY = ys.min() ?? start.y
        return GraphRect(x: minX, y: minY, width: (xs.max() ?? minX) - minX, height: (ys.max() ?? minY) - minY)
    }

    private static func distance(from p: GraphPoint, toSegment a: GraphPoint, _ b: GraphPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return p.distance(to: GraphPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
