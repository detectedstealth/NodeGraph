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
    @State private var console = ConsoleModel()
    @State private var consoleHeight = ConsolePanel.defaultHeight

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
                    Button("Run", systemImage: "play.fill") {
                        Task { await run(controller.model, console: console) }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .overlay(alignment: .bottomTrailing) {
                GraphMiniMapView(model: controller.model).padding()
            }
            // Below the canvas, not over it, so nothing covers a line of the log.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GeometryReader { window in
                    ConsolePanel(
                        console: console, model: controller.model, height: $consoleHeight,
                        maximumHeight: window.size.height * 0.8)
                }
                .frame(height: consoleHeight)
            }
    }
}

/// A PNG of the whole graph, for a thumbnail or for documentation.
@MainActor
func picture(of model: GraphEditorModel) -> Data? {
    model.pngData()
}

/// Runs the graph once. Each node shows its result on the canvas, and what nodes log and what
/// fails goes to the console.
@MainActor
func run(_ model: GraphEditorModel, console: ConsoleModel) async {
    let name = model.consoleName(of:)
    model.clearExecutionState()
    console.beginRun("Run once")

    let runner: GraphRunner
    do {
        runner = try GraphRunner(
            graph: model.editor.graph, registry: model.editor.nodes,
            subgraphs: model.editor.subgraphs.map(\.value), logger: console.logger)
    } catch {
        console.append(.error, "The graph cannot run: \(error)", source: .run)
        return
    }

    // Events drive the badges on the nodes; results drive the values shown on links and watches.
    let events = model.observeExecution(runner.events())
    for await result in runner.run(.once) {
        model.apply(result)
        console.record(result, name: name)
    }
    events.cancel()
}
