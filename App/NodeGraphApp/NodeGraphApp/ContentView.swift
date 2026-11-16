import NodeGraphCore
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
    let controller: GraphInteractionController
    @State private var showsInspector = true
    @State private var runTask: Task<Void, Never>?
    @State private var isRunning = false
    @State private var showsRunOptions = false
    @State private var assistant: AssistantPanelModel
    @State private var inspectorTab = InspectorTab.node
    @State private var console = ConsoleModel()
    @AppStorage("showsConsole") private var showsConsole = true
    @AppStorage("consoleHeight") private var consoleHeight = ConsolePanel.defaultHeight
    @AppStorage("showsMiniMap") private var showsMiniMap = true
    @State private var exportedImage: GraphImageDocument?
    @State private var showsExporter = false

    private enum InspectorTab: String, CaseIterable {
        case node = "Inspector"
        case assistant = "Assistant"
    }

    init(controller: GraphInteractionController) {
        self.controller = controller
        _assistant = State(initialValue: AssistantPanelModel(model: controller.model))
    }

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                canvas
                if showsConsole {
                    ConsolePanel(
                        console: console, model: controller.model, height: $consoleHeight,
                        maximumHeight: window.size.height * 0.8)
                }
            }
        }
        .inspector(isPresented: $showsInspector) {
            VStack(spacing: 0) {
                Picker("Panel", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                switch inspectorTab {
                case .node: GraphInspectorView(model: controller.model)
                case .assistant: AssistantPanel(assistant: assistant)
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
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
        }
    }

    /// The graph with its controls laid over it. The console sits below, not over it, so neither
    /// the mini-map nor the toolbar can cover a log line.
    private var canvas: some View {
        GraphCanvasView(controller: controller)
            // UI tests pass this so XCUIAutomation can see the nodes, links and groups.
            .environment(\.exposesCanvasElements, ProcessInfo.processInfo.arguments.contains("-ExposeCanvasElements"))
            .ignoresSafeArea(.container)
            .overlay(alignment: .topTrailing) {
                HStack {
                    GraphUndoControls(model: controller.model)
                    // Two buttons rather than a Menu with a primary action: macOS draws that as a
                    // system split control that ignores the button style, so it had no fill.
                    Button(isRunning ? "Stop" : "Run", systemImage: isRunning ? "stop.fill" : "play.fill") {
                        if isRunning { stopRun() } else { startRun(.once) }
                    }
                    // A popover from a plain Button, since a Menu draws itself without the fill.
                    Button("Run Options", systemImage: "chevron.down") { showsRunOptions.toggle() }
                        .popover(isPresented: $showsRunOptions) {
                            VStack(alignment: .leading, spacing: 4) {
                                Button("Run Once", systemImage: "play.fill") {
                                    showsRunOptions = false
                                    startRun(.once)
                                }
                                Button("Run Continuously", systemImage: "repeat") {
                                    showsRunOptions = false
                                    startRun(.continuous(interval: .milliseconds(500)))
                                }
                                if isRunning {
                                    Button("Stop", systemImage: "stop.fill") {
                                        showsRunOptions = false
                                        stopRun()
                                    }
                                }
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonStyle(.borderless)
                            .padding(12)
                        }
                    Button("Console", systemImage: showsConsole ? "terminal.fill" : "terminal") { showsConsole.toggle() }
                    Button("Mini-map", systemImage: showsMiniMap ? "map.fill" : "map") { showsMiniMap.toggle() }
                    Button("Add Node", systemImage: "plus") { controller.beginAddNode() }
                    Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .padding()
                #if os(iOS)
                // On iPad the overlay is also inset by the top safe area, which left a gap above
                // the buttons. Sit them close to the top edge, as on the Mac.
                .padding(.top, -8)
                .ignoresSafeArea(.container, edges: .top)
                #endif
            }
            .overlay(alignment: .topLeading) {
                GraphBreadcrumbView(controller: controller).padding()
            }
            .overlay(alignment: .bottomTrailing) {
                if showsMiniMap { GraphMiniMapView(model: controller.model).padding() }
            }
    }
}

extension ContentView {
    /// Runs the root graph and shows each node's progress and result on the canvas, what nodes
    /// log and what fails in the console. Edits made while it runs take effect on the next run.
    private func startRun(_ mode: RunMode) {
        let model = controller.model
        stopRun()
        model.clearExecutionState()
        let name = model.consoleName(of:)
        console.beginRun(mode.isOnce ? "Run once" : "Run continuously")
        console.record(GraphValidator(connections: model.editor.connectionValidator).validate(model.editor.validationContext), name: name)
        let runner: GraphRunner
        do {
            runner = try GraphRunner(
                graph: model.editor.graph, registry: model.editor.nodes,
                subgraphs: model.editor.subgraphs.map(\.value), logger: console.logger)
        } catch {
            console.append(.error, "The graph cannot run: \(error)", source: .run)
            return
        }
        isRunning = true
        let events = model.observeExecution(runner.events())
        let summarize = mode.isOnce
        // Ends with the run, and cancelling it stops the run.
        runTask = Task {
            for await result in runner.run(mode) {
                model.apply(result)
                console.record(result, summarize: summarize, name: name)
            }
            events.cancel()
            if !Task.isCancelled { isRunning = false }
        }
    }

    private func stopRun() {
        guard isRunning else { return }
        runTask?.cancel()
        isRunning = false
        console.append(.info, "Stopped", source: .run)
    }
}

private extension RunMode {
    var isOnce: Bool { if case .once = self { true } else { false } }
}

#Preview {
    ContentView(controller: GraphInteractionController(model: DemoGraph.makeModel()))
}
