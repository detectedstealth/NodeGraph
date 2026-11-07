import NodeGraphUI
import SwiftUI

struct ContentView: View {
    @State private var controller = GraphInteractionController(model: DemoGraph.makeModel())
    @State private var showsInspector = true

    var body: some View {
        GraphCanvasView(controller: controller)
            .ignoresSafeArea(.container)
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
            .overlay(alignment: .topLeading) {
                GraphBreadcrumbView(controller: controller).padding()
            }
            .inspector(isPresented: $showsInspector) {
                GraphInspectorView(model: controller.model)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }
}

#Preview {
    ContentView()
}
