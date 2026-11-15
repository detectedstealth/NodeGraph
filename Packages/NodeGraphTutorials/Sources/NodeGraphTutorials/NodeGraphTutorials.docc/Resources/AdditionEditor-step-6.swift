import NodeGraphCore
import NodeGraphUI
import SwiftUI

/// The addition graph from chapter 1, ready for the canvas.
@MainActor
func makeAdditionModel(theme: GraphTheme = .dark) throws -> GraphEditorModel {
    GraphEditorModel(editor: try makeAdditionGraph(), theme: theme)
}

/// A screen that shows the graph and lets the user edit it with mouse, keyboard or touch.
struct AdditionEditorView: View {
    let controller: GraphInteractionController
    @State private var showsInspector = true

    var body: some View {
        GraphCanvasView(controller: controller)
            .inspector(isPresented: $showsInspector) {
                GraphInspectorView(model: controller.model)
            }
            .overlay(alignment: .topTrailing) {
                HStack {
                    GraphUndoControls(model: controller.model)
                    Button("Add Node", systemImage: "plus") { controller.beginAddNode() }
                    Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .overlay(alignment: .bottomTrailing) {
                GraphMiniMapView(model: controller.model).padding()
            }
    }
}

/// A PNG of the whole graph, for a thumbnail or for documentation.
@MainActor
func picture(of model: GraphEditorModel) -> Data? {
    model.pngData()
}
