import NodeGraphCore
import NodeGraphSync
import NodeGraphUI
import SwiftUI
import UniformTypeIdentifiers

/// A PNG picture of the graph, for the file exporter.
struct GraphImageDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ContentView: View {
    @State private var controller = GraphInteractionController(model: DemoGraph.makeModel())
    @State private var showsInspector = true
    @State private var runTask: Task<Void, Never>?
    @State private var exportedImage: GraphImageDocument?
    @State private var showsExporter = false

    var body: some View {
        GraphCanvasView(controller: controller)
            // UI tests pass this so XCUIAutomation can see the nodes, links and groups.
            .environment(\.exposesCanvasElements, ProcessInfo.processInfo.arguments.contains("-ExposeCanvasElements"))
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
            .fileExporter(
                isPresented: $showsExporter, document: exportedImage, contentType: .png,
                defaultFilename: "Graph"
            ) { _ in exportedImage = nil }
            .onAppear {
                // Export as Image in the canvas menu hands over the PNG; the user picks where it goes.
                controller.model.onExportImage = { data in
                    exportedImage = GraphImageDocument(data: data)
                    showsExporter = true
                }
                connectLibraries()
            }
    }
}

extension ContentView {
    /// Subgraph libraries live in the app's Application Support folder: loaded now, and each
    /// change the editor makes to one is saved as it happens.
    private func connectLibraries() {
        let model = controller.model
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        let store = FileSubgraphLibraryStore(directory: support.appendingPathComponent("NodeGraph/Libraries"))
        model.onLibraryChange = { library in
            Task { try? await store.save(library) }
        }
        Task {
            let libraries = (try? await store.libraries()) ?? []
            model.setLibraries(libraries.sorted { $0.name < $1.name })
        }
    }

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
        // Ends with the run, and cancelling it stops the run.
        runTask = model.observeResults(runner.run(.once))
    }
}

#Preview {
    ContentView()
}
