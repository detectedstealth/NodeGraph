import NodeGraphUI
import SwiftUI

/// Picks the scene set at launch. UI tests pass `-DemoWindow` to get one window with the demo
/// graph, since driving a document browser or open panel from XCUIAutomation is not practical.
@main enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("-DemoWindow") {
            DemoApp.main()
        } else {
            GraphApp.main()
        }
    }
}

/// The app: one window per `.nodegraph` document, with autosave and versions.
struct GraphApp: App {
    var body: some Scene {
        DocumentGroup { document in
            DocumentEditorView(document: document)
        } makeDocument: { _, _ in
            NodeGraphDocument()
        }
    }
}

/// A single window with the demo graph. Nothing is saved.
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoView()
        }
    }
}

private struct DemoView: View {
    @State private var controller = GraphInteractionController(model: DemoGraph.makeModel())

    var body: some View {
        ContentView(controller: controller)
    }
}
