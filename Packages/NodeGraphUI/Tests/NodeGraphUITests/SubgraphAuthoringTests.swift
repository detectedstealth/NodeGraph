import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct SubgraphAuthoringTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @discardableResult
    private func add(_ type: NodeTypeID, x: Double, y: Double = 0) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y))
        try model.perform(.addNode(node: node))
        return node
    }

    private func link(_ source: Node, _ sink: Node, port: String = "a") throws {
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: PortID(port), direction: .input)))
    }

    /// A source feeding a sink, with only the sink selected.
    private func sourceAndSelectedSink() throws -> (Node, Node) {
        let source = try add(TestKit.source, x: 0)
        let sink = try add(TestKit.sink, x: 400)
        try link(source, sink)
        model.select(node: sink.id)
        return (source, sink)
    }

    @Test func theFormNeedsASelection() {
        #expect(!controller.perform(.createSubgraph))
        #expect(model.createSubgraphRequest == nil)
    }

    @Test func theFormOffersTheSelectedNodesPropertiesAndAFreshName() throws {
        let node = try add(TestKit.widgets, x: 0)
        model.select(node: node.id)
        #expect(controller.perform(.createSubgraph))
        let request = try #require(model.createSubgraphRequest)
        #expect(request.nodes == [node.id] && request.suggestedName == "Subgraph" && request.error == nil)
        #expect(request.candidates.map(\.title) == ["Flag", "Gain", "Count", "Label", "Mode", "Tint", "Notes"])
        #expect(request.candidates.first { $0.title == "Gain" }?.valueText == "0.5")
        #expect(request.candidates.allSatisfy { $0.nodeTitle == "Widgets" })
    }

    @Test func theSuggestedNameAvoidsExistingSubgraphs() throws {
        let (_, sink) = try sourceAndSelectedSink()
        controller.perform(.createSubgraph)
        model.createSubgraph(name: "Subgraph")
        let other = try add(TestKit.source, x: 900)
        model.select(node: other.id)
        controller.perform(.createSubgraph)
        #expect(model.createSubgraphRequest?.suggestedName == "Subgraph 2")
        _ = sink
    }

    @Test func creatingWrapsTheSelectionAsOneUndoStepAndSelectsTheInstance() throws {
        let (source, sink) = try sourceAndSelectedSink()
        let before = model.history.undoStack.count
        controller.perform(.createSubgraph)
        #expect(model.createSubgraph(name: "  Wrapped  "))
        #expect(model.createSubgraphRequest == nil)
        #expect(model.graph.nodes[sink.id] == nil && model.graph.nodes[source.id] != nil)
        let instance = try #require(model.graph.nodes.values.last)
        #expect(model.subgraph(of: instance.id) != nil && model.selection.nodes == [instance.id])
        #expect(model.editor.subgraphs.values.first?.interface.name == "Wrapped")
        #expect(model.graph.links.count == 1)  // the source still feeds the wrapped sink
        #expect(model.history.undoStack.count == before + 1)
        #expect(model.scopePath.isEmpty)
        try model.undo()
        #expect(model.graph.nodes[sink.id] != nil && model.editor.subgraphs.isEmpty)
    }

    @Test func openingAfterwardsGoesInside() throws {
        _ = try sourceAndSelectedSink()
        controller.perform(.createSubgraph)
        #expect(model.createSubgraph(name: "Wrapped", open: true))
        #expect(model.scopePath.count == 1 && model.graph.nodes.count == 1)
    }

    @Test func chosenPropertiesAreExposedWithTheirCurrentValues() throws {
        let node = try add(TestKit.widgets, x: 0)
        try model.perform(.setNodeProperty(node: node.id, property: "gain", value: .double(0.8)))
        model.select(node: node.id)
        controller.perform(.createSubgraph)
        let request = try #require(model.createSubgraphRequest)
        let gain = try #require(request.candidates.first { $0.title == "Gain" })
        #expect(model.createSubgraph(name: "Gainer", promoting: [gain.target]))
        let definition = try #require(model.editor.subgraphs.values.first)
        #expect(definition.interface.properties.map(\.id.rawValue) == ["gain"])
        #expect(definition.interface.properties.first?.defaultValue == .double(0.8))
        let instance = try #require(model.graph.nodes.values.first)
        #expect(model.definition(of: instance)?.property("gain") != nil)
    }

    @Test func aBlankNameIsRefusedAndTheFormStaysOpen() throws {
        _ = try sourceAndSelectedSink()
        controller.perform(.createSubgraph)
        #expect(!model.createSubgraph(name: "   "))
        #expect(model.createSubgraphRequest?.error == "Give the subgraph a name.")
        #expect(model.editor.subgraphs.isEmpty)
    }

    @Test func aRefusalByTheRulesIsShownAndChangesNothing() throws {
        // Two links into one multi-link input cannot become a single exposed input.
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.source, x: 0, y: 200)
        let sink = try add(TestKit.sink, x: 400)
        try link(a, sink)
        try model.perform(.setNodeAttribute(node: sink.id, attribute: .title(value: "Sink")))
        model.select(node: sink.id)
        controller.perform(.createSubgraph)
        // Select a node that does not exist any more, so the conversion is refused.
        try model.perform(.removeNode(id: sink.id))
        let graphBefore = model.graph
        #expect(!model.createSubgraph(name: "Nope"))
        #expect(model.createSubgraphRequest?.error != nil)
        #expect(model.graph == graphBefore && model.editor.subgraphs.isEmpty)
        _ = b
    }

    @Test func cancellingClosesTheForm() throws {
        _ = try sourceAndSelectedSink()
        controller.perform(.createSubgraph)
        model.cancelCreateSubgraph()
        #expect(model.createSubgraphRequest == nil)
        #expect(!model.createSubgraph(name: "Late"))  // nothing open to confirm
    }

    @Test func unpackingPutsTheNodesBackAndKeepsTheLinks() throws {
        let (source, sink) = try sourceAndSelectedSink()
        controller.perform(.createSubgraph)
        model.createSubgraph(name: "Wrapped")
        let instance = try #require(model.graph.nodes.values.last)
        model.select(node: instance.id)
        let before = model.history.undoStack.count
        #expect(controller.perform(.unpackSubgraph))
        #expect(model.graph.nodes.values.contains { $0.typeID == TestKit.sink })
        #expect(model.graph.nodes[instance.id] == nil)
        #expect(model.graph.links.count == 1)
        #expect(model.graph.links.values.first?.source.node == source.id)
        #expect(model.selection.nodes.count == 1)
        #expect(model.history.undoStack.count == before + 1)
        try model.undo()
        #expect(model.graph.nodes[instance.id] != nil)
        _ = sink
    }

    @Test func unpackingRequiresASingleInstance() throws {
        let node = try add(TestKit.source, x: 0)
        model.select(node: node.id)
        #expect(!controller.perform(.unpackSubgraph))
        model.clearSelection()
        #expect(!controller.perform(.unpackSubgraph))
    }

    @Test func creatingInsideASubgraphNestsANewOne() throws {
        let source = try add(TestKit.source, x: 0)
        let sink = try add(TestKit.sink, x: 400)
        try link(source, sink)
        model.selection = GraphSelection(nodes: [source.id, sink.id])
        controller.perform(.createSubgraph)
        model.createSubgraph(name: "Outer", open: true)
        let inner = try #require(model.graph.nodes.values.first { $0.typeID == TestKit.sink })
        model.select(node: inner.id)
        controller.perform(.createSubgraph)
        #expect(model.createSubgraph(name: "Inner"))
        #expect(model.editor.subgraphs.count == 2)
        #expect(model.scopePath.count == 1)
        #expect(model.graph.nodes.values.contains { model.subgraph(of: $0.id) != nil })
        try model.undo()
        #expect(model.editor.subgraphs.count == 1)
    }

    @Test func keysAndMenusReachIt() throws {
        #expect(CanvasKeyMap.command(for: .character("g"), modifiers: .command) == .createSubgraph)
        #expect(CanvasKeyMap.command(for: .character("G"), modifiers: [.command, .shift]) == .unpackSubgraph)
        let (_, sink) = try sourceAndSelectedSink()
        let frame = try #require(model.layout(of: sink.id)).frame
        let items = controller.contextMenu(at: CGPoint(x: frame.minX + 60, y: frame.minY + 40))
        #expect(items.contains { $0.title == "Create Subgraph…" })
        #expect(!items.contains { $0.title == "Unpack Subgraph" })
        controller.perform(.createSubgraph)
        model.createSubgraph(name: "Wrapped")
        let instance = try #require(model.graph.nodes.values.last)
        let instanceFrame = try #require(model.layout(of: instance.id)).frame
        let instanceMenu = controller.contextMenu(at: CGPoint(x: instanceFrame.minX + 60, y: instanceFrame.minY + 40))
        #expect(instanceMenu.contains { $0.title == "Unpack Subgraph" })
        #expect(instanceMenu.contains { $0.title == "Open Subgraph" })
    }
}
