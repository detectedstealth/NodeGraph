import CoreGraphics
import Logging
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct ConsoleTests {
    /// Waits for lines that travel through the console's stream to arrive.
    private func settle(_ console: ConsoleModel, count: Int) async {
        for _ in 0..<200 where console.entries.count < count { await Task.yield() }
    }

    /// A source that logs and a sink that fails, linked, running in a runner that reports to `console`.
    private func rig(console: ConsoleModel) throws -> (model: GraphEditorModel, source: Node, sink: Node, runner: GraphRunner) {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0), title: "Sensor")
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.perform(.addLink(link: GraphLink(sourceNode: source.id, sourcePort: "out", targetNode: sink.id, targetPort: "a")))
        var nodes = model.editor.nodes
        nodes.register(NodeDefinition(
            typeID: TestKit.source, displayName: "Source",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")])
        ) { ctx in
            ctx.logger.info("reading 4")
            ctx.logger.debug("detail")
            ctx.logger.warning("noisy")
            return ["out": .double(4)]
        }
        nodes.register(NodeDefinition(
            typeID: TestKit.sink, displayName: "Sink",
            ports: [
                PortDefinition(id: "a", direction: .input, type: "number"),
                PortDefinition(id: "b", direction: .input, type: "number"),
            ])
        ) { _ in throw NodeExecutionError.failed("boom") }
        let runner = try GraphRunner(graph: model.editor.graph, registry: nodes, logger: console.logger)
        return (model, source, sink, runner)
    }

    @Test func nodeLogsReachTheConsoleWithTheirLevelAndNode() async throws {
        let console = ConsoleModel()
        let (_, source, _, runner) = try rig(console: console)
        _ = await runner.step()
        await settle(console, count: 3)
        #expect(console.entries.map(\.text) == ["reading 4", "detail", "noisy"])
        #expect(console.entries.map(\.level) == [.info, .debug, .warning])
        #expect(console.entries.allSatisfy { $0.node == source.id && $0.source == .node })
    }

    @Test func aRecordedPassNamesFailuresAndSummarisesTheRun() async throws {
        let console = ConsoleModel()
        let (model, source, sink, runner) = try rig(console: console)
        let result = await runner.step()
        console.record(result, name: model.consoleName(of:))
        let errors = console.entries.filter { $0.level == .error }
        #expect(errors.map(\.text) == ["Sink failed: boom"])
        #expect(errors.first?.node == sink.id && errors.first?.source == .run)
        let summary = try #require(console.entries.last)
        #expect(summary.level == .warning && summary.text.hasPrefix("Pass 0: 2 nodes, 1 failed, "))
        #expect(model.consoleName(of: source.id) == "Sensor")  // the title, else the type's name
        #expect(model.consoleName(of: sink.id) == "Sink")
        #expect(model.consoleName(of: NodeID()) == "A removed node")
    }

    @Test func aCleanPassIsAnInfoLine() async throws {
        let console = ConsoleModel()
        let model = TestKit.makeModel()
        var nodes = model.editor.nodes
        nodes.register(NodeDefinition(
            typeID: TestKit.source, displayName: "Source",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")])
        ) { _ in ["out": 1.0] }
        try model.perform(.addNode(node: Node(typeID: TestKit.source)))
        let result = await (try GraphRunner(graph: model.editor.graph, registry: nodes)).step()
        console.record(result, name: model.consoleName(of:))
        #expect(console.entries.map(\.level) == [.info])
    }

    @Test func validationProblemsBecomeLinesAboutTheirNode() throws {
        let console = ConsoleModel()
        let node = NodeID()
        console.record([
            GraphDiagnostic(code: "x", message: "Value is invalid.", node: node),
            GraphDiagnostic(severity: .warning, code: "y", message: "Check this."),
        ], name: { _ in "Sensor" })
        #expect(console.entries.map(\.text) == ["Sensor: Value is invalid.", "Check this."])
        #expect(console.entries.map(\.level) == [.error, .warning])
        #expect(console.entries.allSatisfy { $0.source == .validation } && console.entries[0].node == node)
    }

    @Test func eachLevelIsItsOwnSwitchAndHiddenLinesAreKept() {
        let console = ConsoleModel()
        console.append(.debug, "d")
        console.append(.info, "i")
        console.append(.warning, "w")
        console.append(.error, "e")
        #expect(console.visibleEntries.map(\.text) == ["i", "w", "e"])  // debug is off at first
        console.visibleLevels = [.warning]
        #expect(console.visibleEntries.map(\.text) == ["w"])  // errors are not included with warnings
        console.visibleLevels = [.debug, .error]
        #expect(console.visibleEntries.map(\.text) == ["d", "e"])
        console.visibleLevels = Set(ConsoleLevel.allCases)
        #expect(console.visibleEntries.count == 4 && console.count(of: .error) == 1)
        console.visibleLevels = []
        #expect(console.visibleEntries.isEmpty && console.entries.count == 4)
        console.clear()
        #expect(console.entries.isEmpty)
    }

    @Test func theOldestLinesAreDroppedBeyondTheCapacity() {
        let console = ConsoleModel(capacity: 3)
        for index in 0..<5 { console.append(.info, "line \(index)") }
        #expect(console.entries.map(\.text) == ["line 2", "line 3", "line 4"])
        #expect(console.entries.map(\.id) == [2, 3, 4])  // ids keep counting, so rows stay stable
    }

    @Test func revealingANodeSelectsItAndCentersTheView() throws {
        let model = TestKit.makeModel()
        let far = Node(typeID: TestKit.source, position: GraphPoint(x: 5000, y: 3000))
        try model.perform(.addNode(node: far))
        model.viewSizeChanged(to: CGSize(width: 800, height: 600))
        model.reveal(node: far.id)
        #expect(model.selection.nodes == [far.id])
        let frame = model.editor.nodes.frame(of: far)
        let center = model.camera.screenPoint(for: GraphPoint(x: (frame.minX + frame.maxX) / 2, y: (frame.minY + frame.maxY) / 2))
        #expect(abs(center.x - 400) < 1 && abs(center.y - 300) < 1)
        model.reveal(node: NodeID())  // a node that is gone changes nothing
        #expect(model.selection.nodes == [far.id])
    }
}

@Suite struct ConsolePanelTests {
    @Test func draggingUpGrowsThePanelAndDownShrinksIt() {
        #expect(ConsolePanel.height(from: 200, dragged: -100, maximum: 600) == 300)
        #expect(ConsolePanel.height(from: 200, dragged: 60, maximum: 600) == 140)
    }

    @Test func theHeightStaysBetweenTheMinimumAndTheMaximum() {
        #expect(ConsolePanel.height(from: 200, dragged: 500, maximum: 600) == ConsolePanel.minimumHeight)
        #expect(ConsolePanel.height(from: 200, dragged: -900, maximum: 600) == 600)
        // A window too small for the minimum still gets the minimum.
        #expect(ConsolePanel.height(from: 200, dragged: -50, maximum: 40) == ConsolePanel.minimumHeight)
    }
}
