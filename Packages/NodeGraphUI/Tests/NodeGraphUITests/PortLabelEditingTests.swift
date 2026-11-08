import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct PortLabelEditingTests {
    private func model() throws -> (GraphEditorModel, Node) {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: node))
        return (model, node)
    }

    private func address(_ node: Node, _ port: PortID = "a") -> PortAddress {
        PortAddress(node: node.id, port: port, direction: .input)
    }

    @Test func aLabelShowsOnTheCanvasLayoutAndInTheInspector() throws {
        let (model, node) = try model()
        #expect(model.setPortLabel(address(node), to: "  Elapsed "))
        #expect(model.layout(of: node.id)?.port(address(node))?.definition.displayName == "Elapsed")
        #expect(model.layout(of: node.id)?.port(address(node, "b"))?.definition.displayName == "b")

        model.select(node: node.id)
        guard case .node(let info) = model.inspection() else { Issue.record("expected a node"); return }
        let port = try #require(info.inputs.first { $0.definition.id == "a" })
        #expect(port.definition.displayName == "Elapsed")
        #expect(port.defaultName == "a", "the type's own name stays available")
        #expect(port.isRelabeled)
        #expect(try #require(info.inputs.first { $0.definition.id == "b" }).isRelabeled == false)
    }

    @Test func blankOrTheTypesOwnNameClearsTheLabel() throws {
        let (model, node) = try model()
        #expect(model.setPortLabel(address(node), to: "Elapsed"))
        #expect(model.setPortLabel(address(node), to: "   "))
        #expect(model.graph.nodes[node.id]?.portLabels.isEmpty == true)
        #expect(model.setPortLabel(address(node), to: "Elapsed"))
        #expect(model.setPortLabel(address(node), to: "a"), "typing the original name is a reset")
        #expect(model.graph.nodes[node.id]?.portLabels.isEmpty == true)
        #expect(!model.setPortLabel(address(node), to: nil), "nothing to clear")
    }

    @Test func nothingChangesForUnknownPortsOrTheSameLabel() throws {
        let (model, node) = try model()
        #expect(!model.setPortLabel(address(node, "nope"), to: "x"))
        #expect(!model.setPortLabel(PortAddress(node: node.id, port: "a", direction: .output), to: "x"))
        #expect(model.setPortLabel(address(node), to: "x"))
        #expect(!model.setPortLabel(address(node), to: "x"), "already that")
    }

    @Test func aRenameIsOneUndoStepAndLinksAreKept() throws {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source), sink = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        model.endCoalescing()
        #expect(model.setPortLabel(address(sink), to: "Elapsed"))
        #expect(model.graph.links.count == 1)
        try model.undo()
        #expect(model.graph.nodes[sink.id]?.portLabels.isEmpty == true)
        #expect(model.graph.links.count == 1)
        try model.redo()
        #expect(model.graph.nodes[sink.id]?.portLabels == ["input:a": "Elapsed"])
    }

    @Test func aReadOnlyCanvasRefusesIt() throws {
        let (model, node) = try model()
        model.isEditable = false
        #expect(!model.setPortLabel(address(node), to: "x"))
        #expect(model.graph.nodes[node.id]?.portLabels.isEmpty == true)
    }

    @Test func itWorksInsideASubgraph() throws {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: node))
        model.select(node: node.id)
        #expect(model.beginCreateSubgraph())
        #expect(model.createSubgraph(name: "Inner", open: true))
        let inner = try #require(model.graph.nodes.values.first { $0.typeID == TestKit.sink })
        #expect(model.setPortLabel(PortAddress(node: inner.id, port: "b", direction: .input), to: "Second"))
        #expect(model.graph.nodes[inner.id]?.portLabels == ["input:b": "Second"])
    }
}

@MainActor
@Suite struct PortLabelCanvasEditingTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController
    var node: Node

    init() throws {
        controller = GraphInteractionController(model: model)
        node = Node(typeID: TestKit.sink, position: GraphPoint(x: 100, y: 100))
        try model.perform(.addNode(node: node))
    }

    private var address: PortAddress { PortAddress(node: node.id, port: "a", direction: .input) }
    private var point: CGPoint { CGPoint(model.layout(of: node.id)!.port(address)!.position) }

    private func click(at time: ContinuousClock.Instant) {
        controller.now = { time }
        controller.pointerDown(at: point, kind: .mouse)
        controller.pointerUp(at: point)
    }

    @Test func aDoubleClickOnAPortOpensTheEditorWithItsCurrentName() {
        let start = ContinuousClock.Instant.now
        click(at: start)
        #expect(controller.portLabelEditor == nil, "one click does not")
        click(at: start + .milliseconds(200))
        #expect(controller.portLabelEditor == .init(port: address, draftText: "a"))
    }

    @Test func slowClicksDoNot() {
        let start = ContinuousClock.Instant.now
        click(at: start)
        click(at: start + .seconds(2))
        #expect(controller.portLabelEditor == nil)
    }

    @Test func committingAppliesTheTypedLabelAsOneUndoStep() throws {
        #expect(controller.beginRenamePort(address))
        controller.updatePortLabelDraft("Elapsed")
        controller.closePortLabelEditor(commit: true)
        #expect(controller.portLabelEditor == nil)
        #expect(model.graph.nodes[node.id]?.portLabels == ["input:a": "Elapsed"])
        try model.undo()
        #expect(model.graph.nodes[node.id]?.portLabels.isEmpty == true)
    }

    @Test func escapeAbandonsAndBlankGoesBackToTheTypesName() {
        #expect(controller.beginRenamePort(address))
        controller.updatePortLabelDraft("Nope")
        controller.closeEditor(commit: false)
        #expect(controller.portLabelEditor == nil)
        #expect(model.graph.nodes[node.id]?.portLabels.isEmpty == true)

        model.setPortLabel(address, to: "Elapsed")
        #expect(controller.beginRenamePort(address))
        controller.updatePortLabelDraft("  ")
        controller.closePortLabelEditor(commit: true)
        #expect(model.graph.nodes[node.id]?.portLabels.isEmpty == true)
    }

    @Test func pressingElsewhereCommitsLikeTheWidgetEditors() {
        #expect(controller.beginRenamePort(address))
        controller.updatePortLabelDraft("Level")
        controller.pointerDown(at: CGPoint(x: 900, y: 900), kind: .mouse)
        controller.pointerUp(at: CGPoint(x: 900, y: 900))
        #expect(controller.portLabelEditor == nil)
        #expect(model.graph.nodes[node.id]?.portLabels == ["input:a": "Level"])
    }

    @Test func theContextMenuOffersItAndTheCommandOpensTheEditor() {
        let titles = controller.contextMenu(at: point).map(\.title)
        #expect(titles.contains("Rename Port…"))
        #expect(controller.perform(.renamePort(address)))
        #expect(controller.portLabelEditor?.port == address)
    }

    @Test func aReadOnlyCanvasOrAMissingPortDoesNotOpenIt() {
        #expect(!controller.beginRenamePort(PortAddress(node: node.id, port: "nope", direction: .input)))
        model.isEditable = false
        #expect(!controller.beginRenamePort(address))
        #expect(!controller.perform(.renamePort(address)))
        #expect(controller.portLabelEditor == nil)
    }

    @Test func notWhenLabelsAreNotDrawnAtThisZoom() {
        model.camera.setZoom(0.1, anchoredAtScreen: .zero)
        #expect(!controller.beginRenamePort(address))
    }
}
