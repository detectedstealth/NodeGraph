import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct SubgraphScopeTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController
    let source: Node
    let instance: Node
    let subgraph: SubgraphID

    /// A source feeding a sink, with the sink converted into a subgraph instance named "Wrapped".
    init() throws {
        controller = GraphInteractionController(model: model)
        source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 400, y: 0))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [sink.id], name: "Wrapped")
        try model.perform(conversion.command)
        subgraph = conversion.subgraph
        instance = try #require(model.graph.nodes[conversion.instance])
    }

    @Test func theInstanceIsRecognizedAsASubgraph() {
        #expect(model.subgraph(of: instance.id) == subgraph)
        #expect(model.subgraph(of: source.id) == nil)
        #expect(model.scopeName(nil) == "Graph" && model.scopeName(subgraph) == "Wrapped")
    }

    @Test func enteringShowsTheInnerGraphAndLeavingShowsTheRoot() throws {
        let rootNodes = Set(model.graph.nodes.keys)
        model.select(node: instance.id)
        #expect(model.enterSubgraph(of: instance.id))
        #expect(model.scopePath == [subgraph] && model.currentScope == subgraph)
        #expect(model.selection.isEmpty)
        #expect(model.graph == model.editor.subgraphs[subgraph]?.graph)
        #expect(Set(model.graph.nodes.keys).isDisjoint(with: rootNodes))
        #expect(model.leaveSubgraph())
        #expect(model.scopePath.isEmpty && Set(model.graph.nodes.keys) == rootNodes)
        #expect(!model.leaveSubgraph())
    }

    @Test func aNodeThatIsNotAnInstanceCannotBeEntered() {
        #expect(!model.enterSubgraph(of: source.id))
        #expect(model.scopePath.isEmpty)
    }

    @Test func editsInsideChangeTheDefinitionAndNotTheRoot() throws {
        let rootBefore = model.editor.graph
        model.enterSubgraph(of: instance.id)
        let extra = Node(typeID: TestKit.source, position: GraphPoint(x: -300, y: 0))
        try model.perform(.addNode(node: extra))
        #expect(model.graph.nodes[extra.id] != nil)
        #expect(model.editor.subgraphs[subgraph]?.graph.nodes[extra.id] != nil)
        #expect(model.editor.graph == rootBefore)
        try model.undo()
        #expect(model.graph.nodes[extra.id] == nil)
        try model.redo()
        #expect(model.graph.nodes[extra.id] != nil)
    }

    @Test func connectingAndMovingInsideWork() throws {
        model.enterSubgraph(of: instance.id)
        let inner = try #require(model.graph.nodes.values.first)
        let extra = Node(typeID: TestKit.source, position: GraphPoint(x: -300, y: 0))
        try model.perform(.addNode(node: extra))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: extra.id, port: "out", direction: .output),
            target: PortAddress(node: inner.id, port: "b", direction: .input)))
        #expect(model.graph.links.values.contains { $0.source.node == extra.id && $0.target.port == "b" })
        // Dragging the new node works through the controller, in the scope. Entering framed the
        // inner graph, so put the camera back to the origin to use plain coordinates.
        model.camera = GraphCamera()
        let start = CGPoint(x: -250, y: 40)
        controller.pointerDown(at: start, kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: start.x + 100, y: start.y))
        controller.pointerUp(at: CGPoint(x: start.x + 100, y: start.y))
        #expect(model.graph.nodes[extra.id]?.position == GraphPoint(x: -200, y: 0))
        #expect(model.editor.subgraphs[subgraph]?.graph.nodes[extra.id]?.position == GraphPoint(x: -200, y: 0))
    }

    @Test func theBreadcrumbNavigatesBackToALevel() throws {
        model.enterSubgraph(of: instance.id)
        #expect(model.scopePath.count == 1)
        controller.navigate(toDepth: 0)
        #expect(model.scopePath.isEmpty)
        controller.navigate(toDepth: 5)  // out of range: nothing happens
        #expect(model.scopePath.isEmpty)
    }

    @Test func eachLevelKeepsItsOwnView() throws {
        model.viewSize = CGSize(width: 800, height: 600)
        model.camera = GraphCamera(origin: GraphPoint(x: 11, y: 22), zoom: 1.5)
        model.enterSubgraph(of: instance.id)
        model.camera.pan(byScreen: CGSize(width: 40, height: 0))
        let inner = model.camera
        model.leaveSubgraph()
        #expect(model.camera == GraphCamera(origin: GraphPoint(x: 11, y: 22), zoom: 1.5))
        model.enterSubgraph(of: instance.id)
        #expect(model.camera == inner)
    }

    @Test func doubleClickingAnInstanceOpensIt() throws {
        var time = ContinuousClock.Instant.now
        controller.now = { time }
        let center = try #require(model.layout(of: instance.id)).frame
        let point = CGPoint(x: center.minX + 60, y: center.minY + 60)
        controller.pointerDown(at: point, kind: .mouse)
        controller.pointerUp(at: point)
        #expect(model.scopePath.isEmpty)
        time += .milliseconds(150)
        controller.pointerDown(at: point, kind: .mouse)
        controller.pointerUp(at: point)
        #expect(model.scopePath == [subgraph])
    }

    @Test func doubleClickingAPlainNodeDoesNothingSpecial() throws {
        var time = ContinuousClock.Instant.now
        controller.now = { time }
        let point = CGPoint(x: 60, y: 40)
        controller.pointerDown(at: point, kind: .mouse)
        controller.pointerUp(at: point)
        time += .milliseconds(150)
        controller.pointerDown(at: point, kind: .mouse)
        controller.pointerUp(at: point)
        #expect(model.scopePath.isEmpty)
    }

    @Test func returnOpensTheSelectedInstanceAndCommandBracketLeaves() throws {
        #expect(!controller.perform(.openSubgraph))  // nothing selected
        model.select(node: source.id)
        #expect(!controller.perform(.openSubgraph))  // not an instance
        model.select(node: instance.id)
        #expect(CanvasKeyMap.command(for: .return, modifiers: []) == .openSubgraph)
        #expect(controller.perform(.openSubgraph))
        #expect(model.currentScope == subgraph)
        #expect(CanvasKeyMap.command(for: .character("["), modifiers: .command) == .leaveSubgraph)
        #expect(controller.perform(.leaveSubgraph))
        #expect(!controller.perform(.leaveSubgraph))
    }

    @Test func menusOfferTheRightActions() throws {
        let frame = try #require(model.layout(of: instance.id)).frame
        let items = controller.contextMenu(at: CGPoint(x: frame.minX + 60, y: frame.minY + 60))
        #expect(items.first?.title == "Open Subgraph")
        let plain = controller.contextMenu(at: CGPoint(x: 60, y: 40))
        #expect(!plain.contains { $0.title == "Open Subgraph" })
        controller.enterSubgraph(of: instance.id)
        let inside = controller.contextMenu(at: CGPoint(x: 5000, y: 5000))
        #expect(inside.first?.title == "Leave Subgraph")
    }

    @Test func navigatingAbandonsHalfDoneWork() throws {
        controller.beginAddNode(at: CGPoint(x: 100, y: 100))
        controller.enterSubgraph(of: instance.id)
        #expect(controller.addNodeRequest == nil)
        controller.pointerDown(at: CGPoint(x: 0, y: 0), kind: .mouse)
        controller.leaveSubgraph()
        #expect(!controller.isDragging && !controller.isPointerDown)
    }

    @Test func theCatalogDropsTheSubgraphBeingEditedAndItsContainers() throws {
        #expect(model.makeNodeCatalog().entries.contains { $0.id == model.editor.subgraphs[subgraph]!.typeID })
        model.enterSubgraph(of: instance.id)
        #expect(!model.makeNodeCatalog().entries.contains { $0.id == model.editor.subgraphs[subgraph]!.typeID })
        #expect(model.makeNodeCatalog().entries.contains { $0.id == TestKit.source })
    }

    @Test func undoingTheCreationWhileInsideStepsOut() throws {
        model.history.clear()
        let extra = Node(typeID: TestKit.source, position: GraphPoint(x: 800, y: 800))
        try model.perform(.addNode(node: extra))
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [extra.id], name: "Temp")
        try model.perform(conversion.command)
        let id = conversion.subgraph
        model.enterSubgraph(of: conversion.instance)
        #expect(model.currentScope == id)
        try model.undo()  // removes the subgraph the view is inside
        #expect(model.scopePath.isEmpty)
        #expect(model.graph == model.editor.graph)
    }

    @Test func anUnknownNodeCannotBeEnteredFromInside() throws {
        model.enterSubgraph(of: instance.id)
        #expect(!model.enterSubgraph(of: NodeID()))
        #expect(model.scopePath.count == 1)
    }
}
