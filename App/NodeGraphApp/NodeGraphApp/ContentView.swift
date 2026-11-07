import NodeGraphCore
import NodeGraphUI
import SwiftUI

struct ContentView: View {
    @State private var controller = GraphInteractionController(model: DemoGraph.makeModel())
    @State private var showsInspector = true
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        GraphCanvasView(controller: controller)
            .ignoresSafeArea(.container)
            .overlay(alignment: .topTrailing) {
                HStack {
                    GraphUndoControls(model: controller.model)
                    Button("Run", systemImage: "play.fill") { runOnce() }
                    Button("Add Node", systemImage: "plus") { controller.beginAddNode() }
                    Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .overlay(alignment: .topLeading) {
                GraphBreadcrumbView(controller: controller).padding()
            }
            .overlay(alignment: .bottomTrailing) {
                GraphMiniMapView(model: controller.model).padding()
            }
            .inspector(isPresented: $showsInspector) {
                GraphInspectorView(model: controller.model)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
}

extension ContentView {
    /// Runs the root graph once and shows each node's progress and result on the canvas.
    private func runOnce() {
        let model = controller.model
        runTask?.cancel()
        model.clearExecutionState()
        guard let runner = try? GraphRunner(
            graph: model.editor.graph, registry: model.editor.nodes,
            subgraphs: model.editor.subgraphs.map(\.value))
        else { return }
        model.observeExecution(runner.events())
        runTask = Task { for await _ in runner.run(.once) {} }
    }
}

#Preview {
    ContentView()
}
