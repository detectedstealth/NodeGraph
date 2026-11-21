#if !os(tvOS) && !os(watchOS)
import CoreGraphics
import NodeGraphCore
import SwiftUI

/// Maps between graph space and a mini-map of a given size: `world`, the part of the graph the
/// mini-map shows, is fitted into `size` with equal scale on both axes and centered.
struct MiniMapGeometry: Equatable {
    let world: GraphRect
    let size: CGSize
    let scale: Double
    private let offset: CGPoint

    init(world: GraphRect, size: CGSize, padding: Double = 6) {
        self.world = world
        self.size = size
        let width = max(Double(size.width) - 2 * padding, 1)
        let height = max(Double(size.height) - 2 * padding, 1)
        scale = min(width / max(world.size.width, 1), height / max(world.size.height, 1))
        offset = CGPoint(
            x: (Double(size.width) - world.size.width * scale) / 2 - world.minX * scale,
            y: (Double(size.height) - world.size.height * scale) / 2 - world.minY * scale)
    }

    /// The area to show: everything in the graph and the part the canvas currently shows, so the
    /// viewport rectangle never leaves the mini-map. For an empty graph that is just the viewport.
    static func world(content: GraphRect?, viewport: GraphRect) -> GraphRect {
        guard let content else { return viewport }
        let minX = min(content.minX, viewport.minX), minY = min(content.minY, viewport.minY)
        return GraphRect(
            x: minX, y: minY, width: max(content.maxX, viewport.maxX) - minX,
            height: max(content.maxY, viewport.maxY) - minY)
    }

    func point(forGraph point: GraphPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    func graphPoint(forMiniMap point: CGPoint) -> GraphPoint {
        GraphPoint(x: (Double(point.x) - Double(offset.x)) / scale, y: (Double(point.y) - Double(offset.y)) / scale)
    }

    func rect(forGraph rect: GraphRect) -> CGRect {
        CGRect(
            x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y,
            width: rect.size.width * scale, height: rect.size.height * scale)
    }
}

/// A small overview of the whole graph with a rectangle for the part the canvas shows. Press or
/// drag on it to move the canvas there: a press inside the rectangle drags it, a press elsewhere
/// jumps the view to that spot. Nodes show their run state, so an error off screen is visible.
///
/// Place it as an overlay on the canvas, for example bottom trailing.
public struct GraphMiniMapView: View {
    private let model: GraphEditorModel
    private let size: CGSize

    /// The area shown, frozen for the length of a drag so the map does not rescale under the
    /// pointer as the viewport moves.
    @State private var frozenWorld: GraphRect?
    /// From the pointer to the viewport's center, when a drag grabbed the viewport.
    @State private var grabOffset: GraphPoint?

    public init(model: GraphEditorModel, size: CGSize = CGSize(width: 180, height: 120)) {
        self.model = model
        self.size = size
    }

    public var body: some View {
        if model.graph.nodes.isEmpty && model.graph.groups.isEmpty {
            EmptyView()
        } else {
            map
        }
    }

    private var viewport: GraphRect { model.camera.visibleRect(in: model.viewSize) }

    private var geometry: MiniMapGeometry {
        MiniMapGeometry(
            world: frozenWorld ?? MiniMapGeometry.world(content: model.contentBounds, viewport: viewport), size: size)
    }

    private var map: some View {
        let theme = model.theme
        return Canvas { context, _ in
            MainActor.assumeIsolated { draw(&context, geometry: geometry) }
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(theme.nodeBorder), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in drag(to: value.location, from: value.startLocation) }
                .onEnded { _ in
                    frozenWorld = nil
                    grabOffset = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Mini-map")
        .accessibilityHint("Drag to move the view")
    }

    private func drag(to location: CGPoint, from start: CGPoint) {
        if frozenWorld == nil {
            let geometry = self.geometry
            frozenWorld = geometry.world
            // Grabbing the viewport keeps it from jumping to center on the pointer.
            let grabbed = geometry.graphPoint(forMiniMap: start)
            grabOffset = viewport.contains(grabbed)
                ? GraphPoint(x: viewport.minX + viewport.size.width / 2 - grabbed.x, y: viewport.minY + viewport.size.height / 2 - grabbed.y)
                : nil
        }
        let target = geometry.graphPoint(forMiniMap: location)
        let offset = grabOffset ?? .zero
        model.camera.center(on: GraphPoint(x: target.x + offset.x, y: target.y + offset.y), in: model.viewSize)
    }

    private func draw(_ context: inout GraphicsContext, geometry: MiniMapGeometry) {
        let theme = model.theme
        for group in model.graph.groups.values {
            let rect = geometry.rect(forGraph: group.bounds)
            context.fill(Path(rect), with: .color(Color(group.color?.withAlpha(0.2) ?? theme.groupFill)))
        }
        for id in model.graph.nodes.keys {
            guard let layout = model.layout(of: id), let node = model.graph.nodes[id] else { continue }
            // Keep tiny nodes visible as at least a couple of points.
            var rect = geometry.rect(forGraph: layout.frame)
            rect.size.width = max(rect.width, 2)
            rect.size.height = max(rect.height, 2)
            var color = node.color ?? theme.nodeHeader
            if let decoration = model.runDecoration(of: id), decoration.tintsBorder {
                color = theme.color(for: decoration.badge)
            } else if model.selection.nodes.contains(id) {
                color = theme.selection
            }
            context.fill(Path(rect), with: .color(Color(color)))
        }
        // The viewport, with the area outside it dimmed.
        let view = geometry.rect(forGraph: viewport)
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addRect(view)
        context.fill(outside, with: .color(Color.black.opacity(0.25)), style: FillStyle(eoFill: true))
        context.stroke(Path(view), with: .color(Color(theme.selection)), lineWidth: 1.5)
    }
}
#endif
