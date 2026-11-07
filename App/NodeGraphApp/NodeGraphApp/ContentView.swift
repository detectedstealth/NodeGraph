import NodeGraphUI
import SwiftUI

struct ContentView: View {
    @State private var controller = GraphInteractionController(model: DemoGraph.makeModel())

    var body: some View {
        GraphCanvasView(controller: controller)
            .ignoresSafeArea(.container)
            .overlay(alignment: .topTrailing) {
                Button("Add Node", systemImage: "plus") { controller.beginAddNode() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
    }
}

#Preview {
    ContentView()
}
