import NodeGraphUI
import SwiftUI

struct ContentView: View {
    @State private var model = DemoGraph.makeModel()

    var body: some View {
        GraphCanvasView(model: model)
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
