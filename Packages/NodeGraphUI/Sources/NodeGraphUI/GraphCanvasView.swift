import NodeGraphCore
import SwiftUI

/// The node graph editor's canvas: grid, groups, links and nodes drawn with SwiftUI `Canvas`,
/// culled to what is on screen. Display only for now; gestures come with the interaction layer.
public struct GraphCanvasView: View {
    private let model: GraphEditorModel
    @State private var hasFramed = false

    public init(model: GraphEditorModel) {
        self.model = model
    }

    public var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            var context = context
            MainActor.assumeIsolated {
                GraphCanvasRenderer(model: model).draw(&context, size: size)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            model.viewSize = size
            // Show the whole graph the first time the view has a real size.
            if !hasFramed, size.width > 0, size.height > 0 {
                hasFramed = true
                model.zoomToFit()
            }
        }
    }
}
