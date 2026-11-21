#if !os(tvOS) && !os(watchOS)
import CoreGraphics
import NodeGraphCore

/// The view onto the graph: which graph point is at the view's top-left corner, and the scale.
///
/// Screen points are in the canvas view's own coordinates (points, origin top-left).
/// `screen = (graph - origin) * zoom`.
public struct GraphCamera: Hashable, Sendable {
    /// Zoom limits, so a pinch cannot lose the graph.
    public static let zoomRange: ClosedRange<Double> = 0.1...4

    /// The graph point shown at the top-left corner of the view.
    public var origin: GraphPoint
    public private(set) var zoom: Double

    public init(origin: GraphPoint = .zero, zoom: Double = 1) {
        self.origin = origin
        self.zoom = zoom.clamped(to: Self.zoomRange)
    }

    public func graphPoint(forScreen point: CGPoint) -> GraphPoint {
        GraphPoint(x: origin.x + Double(point.x) / zoom, y: origin.y + Double(point.y) / zoom)
    }

    public func screenPoint(for point: GraphPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * zoom, y: (point.y - origin.y) * zoom)
    }

    /// The part of the graph a view of `size` shows.
    public func visibleRect(in size: CGSize) -> GraphRect {
        GraphRect(
            x: origin.x, y: origin.y,
            width: Double(size.width) / zoom, height: Double(size.height) / zoom)
    }

    /// Moves the view by a drag of `delta` screen points, so the graph follows the pointer.
    public mutating func pan(byScreen delta: CGSize) {
        origin.x -= Double(delta.width) / zoom
        origin.y -= Double(delta.height) / zoom
    }

    /// Moves the view so `point` is at the center of a view of `size`, keeping the zoom.
    public mutating func center(on point: GraphPoint, in size: CGSize) {
        origin = GraphPoint(x: point.x - Double(size.width) / 2 / zoom, y: point.y - Double(size.height) / 2 / zoom)
    }

    /// Sets the zoom (clamped to ``zoomRange``) keeping the graph point under `anchor` still.
    ///
    /// Takes an absolute zoom on purpose. A pinch should apply its total magnification to the
    /// zoom the gesture started with, not to the current one, or the zoom compounds.
    public mutating func setZoom(_ newZoom: Double, anchoredAtScreen anchor: CGPoint) {
        let fixed = graphPoint(forScreen: anchor)
        zoom = newZoom.clamped(to: Self.zoomRange)
        origin = GraphPoint(x: fixed.x - Double(anchor.x) / zoom, y: fixed.y - Double(anchor.y) / zoom)
    }

    /// A camera that shows all of `rect` centered in a view of `size`, with `padding` screen
    /// points around it. The zoom does not exceed 1, so a small graph is not blown up.
    public static func framing(_ rect: GraphRect, in size: CGSize, padding: Double = 40) -> GraphCamera {
        let availableWidth = max(Double(size.width) - 2 * padding, 1)
        let availableHeight = max(Double(size.height) - 2 * padding, 1)
        let fit = min(
            availableWidth / max(rect.size.width, 1), availableHeight / max(rect.size.height, 1), 1)
        let zoom = fit.clamped(to: zoomRange)
        return GraphCamera(
            origin: GraphPoint(
                x: rect.minX + rect.size.width / 2 - Double(size.width) / 2 / zoom,
                y: rect.minY + rect.size.height / 2 - Double(size.height) / 2 / zoom),
            zoom: zoom)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
