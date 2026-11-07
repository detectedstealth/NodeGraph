import NodeGraphCore
import SwiftUI

/// The node graph editor's canvas: grid, groups, links and nodes drawn with SwiftUI `Canvas`,
/// culled to what is on screen, with drag and pinch input routed to a
/// ``GraphInteractionController``.
public struct GraphCanvasView: View {
    private let model: GraphEditorModel
    @State private var controller: GraphInteractionController
    @State private var hasFramed = false
    @State private var isPressing = false
    @State private var viewSize = CGSize.zero

    public init(model: GraphEditorModel) {
        self.model = model
        _controller = State(initialValue: GraphInteractionController(model: model))
    }

    public var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            var context = context
            MainActor.assumeIsolated {
                GraphCanvasRenderer(model: model, controller: controller).draw(&context, size: size)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            viewSize = size
            model.viewSize = size
            // Show the whole graph the first time the view has a real size.
            if !hasFramed, size.width > 0, size.height > 0 {
                hasFramed = true
                model.zoomToFit()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressing {
                        isPressing = true
                        controller.pointerDown(at: value.startLocation, modifiers: PlatformInput.modifiers)
                    }
                    controller.pointerMoved(to: value.location, modifiers: PlatformInput.modifiers)
                }
                .onEnded { value in
                    controller.pointerUp(at: value.location)
                    isPressing = false
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    controller.magnify(
                        totalScale: value.magnification,
                        anchor: CGPoint(x: value.startAnchor.x * viewSize.width, y: value.startAnchor.y * viewSize.height))
                }
                .onEnded { _ in controller.endMagnify() }
        )
    }
}
