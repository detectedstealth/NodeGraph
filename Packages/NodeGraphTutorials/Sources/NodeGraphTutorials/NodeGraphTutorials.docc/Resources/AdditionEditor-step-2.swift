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

    var body: some View {
        GraphCanvasView(controller: controller)
    }
}
