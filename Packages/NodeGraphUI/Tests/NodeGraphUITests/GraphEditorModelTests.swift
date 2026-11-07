import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct GraphEditorModelTests {
    private func addedNode(_ model: GraphEditorModel, _ type: NodeTypeID, at x: Double = 0) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: 0))
        try model.perform(.addNode(node: node))
        return node
    }

    @Test func performUpdatesTheObservedGraph() throws {
        let model = TestKit.makeModel()
        let node = try addedNode(model, TestKit.source)
        #expect(model.graph.nodes[node.id] != nil)
        #expect(model.revision == 1)
    }

    @Test func failedEditChangesNothing() throws {
        let model = TestKit.makeModel()
        let bad = Node(typeID: NodeTypeID("not.registered"))
        #expect(throws: GraphEditError.self) { try model.perform(.addNode(node: bad)) }
        #expect(model.graph.nodes.isEmpty)
        #expect(model.revision == 0)
        #expect(!model.canUndo)
    }

    @Test func undoAndRedoRestoreTheGraph() throws {
        let model = TestKit.makeModel()
        let node = try addedNode(model, TestKit.source)
        try model.undo()
        #expect(model.graph.nodes.isEmpty)
        #expect(model.canRedo)
        try model.redo()
        #expect(model.graph.nodes[node.id] != nil)
    }

    @Test func dragWithCoalescingIsOneUndoStep() throws {
        let model = TestKit.makeModel()
        let node = try addedNode(model, TestKit.source)
        for x in stride(from: 10.0, through: 50, by: 10) {
            try model.perform(
                .setNodePositions(placements: [NodePlacement(node: node.id, position: GraphPoint(x: x, y: 0))]),
                name: "Move", coalescing: true)
        }
        model.endCoalescing()
        #expect(model.graph.nodes[node.id]?.position.x == 50)
        try model.undo()
        #expect(model.graph.nodes[node.id]?.position.x == 0)
        #expect(model.undoName == nil)  // only the add remains
    }

    @Test func removingANodeDropsItFromTheSelection() throws {
        let model = TestKit.makeModel()
        let kept = try addedNode(model, TestKit.source)
        let removed = try addedNode(model, TestKit.sink, at: 200)
        model.selection = GraphSelection(nodes: [kept.id, removed.id])
        try model.perform(.removeNode(id: removed.id))
        #expect(model.selection.nodes == [kept.id])
    }

    @Test func selectingReplacesAndClearing() throws {
        let model = TestKit.makeModel()
        let a = try addedNode(model, TestKit.source)
        let b = try addedNode(model, TestKit.sink, at: 200)
        model.select(node: a.id)
        model.select(node: b.id)
        #expect(model.selection.nodes == [b.id])
        model.clearSelection()
        #expect(model.selection.isEmpty)
    }

    @Test func layoutFollowsEditsAndIsReusedWhenUnchanged() throws {
        let model = TestKit.makeModel()
        let node = try addedNode(model, TestKit.sink)
        let first = try #require(model.layout(of: node.id))
        #expect(model.layout(of: node.id) == first)
        try model.perform(.setNodePositions(placements: [NodePlacement(node: node.id, position: GraphPoint(x: 70, y: 30))]))
        let moved = try #require(model.layout(of: node.id))
        #expect(moved.frame.origin == GraphPoint(x: 70, y: 30))
        #expect(moved.inputs[0].position.x == 70)
    }

    @Test func layoutIsNilForAMissingNode() {
        let model = TestKit.makeModel()
        #expect(model.layout(of: NodeID()) == nil)
    }

    @Test func dynamicPortsGrowWhenAnInputIsConnected() throws {
        let model = TestKit.makeModel()
        let source = try addedNode(model, TestKit.source)
        let merge = try addedNode(model, TestKit.merge, at: 300)
        let before = try #require(model.layout(of: merge.id))
        #expect(before.inputs.count == 1)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: merge.id, port: "in_1", direction: .input)))
        let after = try #require(model.layout(of: merge.id))
        #expect(after.inputs.count == 2)
    }

    @Test func linkEndpointsMatchThePortPositions() throws {
        let model = TestKit.makeModel()
        let source = try addedNode(model, TestKit.source)
        let sink = try addedNode(model, TestKit.sink, at: 300)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "b", direction: .input)))
        let link = try #require(model.graph.links.values.first)
        let ends = try #require(model.endpoints(of: link))
        #expect(ends.source == model.layout(of: source.id)?.outputs[0].position)
        #expect(ends.target == model.layout(of: sink.id)?.inputs[1].position)
    }

    @Test func groupedEditsUndoTogether() throws {
        let model = TestKit.makeModel()
        try model.group(name: "Add two") {
            _ = try addedNode(model, TestKit.source)
            _ = try addedNode(model, TestKit.sink, at: 200)
        }
        #expect(model.graph.nodes.count == 2)
        try model.undo()
        #expect(model.graph.nodes.isEmpty)
    }

    @Test func refreshPicksUpEditsMadeDirectlyOnTheEditor() throws {
        let model = TestKit.makeModel()
        try model.editor.apply(.addNode(node: Node(typeID: TestKit.source)))
        #expect(model.graph.nodes.isEmpty)
        model.refresh()
        #expect(model.graph.nodes.count == 1)
    }

    @Test func portColorsComeFromTheTypeRegistry() throws {
        let model = TestKit.makeModel()
        let node = try addedNode(model, TestKit.source)
        let port = try #require(model.layout(of: node.id)?.outputs.first?.definition)
        #expect(model.color(of: port) == RGBAColor(red: 0.2, green: 0.4, blue: 0.9))
        let unknown = PortDefinition(id: "x", direction: .output, type: "unregistered")
        #expect(model.color(of: unknown) == model.theme.unknownPortColor)
        let trigger = PortDefinition(id: "t", direction: .output, kind: .trigger)
        #expect(model.color(of: trigger) == model.theme.triggerPortColor)
    }
}

@MainActor
@Suite struct ZoomToFitTests {
    @Test func emptyGraphLeavesTheCameraAlone() {
        let model = TestKit.makeModel()
        model.zoomToFit()
        #expect(model.camera == GraphCamera())
        #expect(model.contentBounds == nil)
    }

    @Test func fitShowsEveryNodeAndGroup() throws {
        let model = TestKit.makeModel()
        model.viewSize = CGSize(width: 600, height: 400)
        try model.perform(.addNode(node: Node(typeID: TestKit.source, position: GraphPoint(x: -2000, y: 500))))
        try model.perform(.addNode(node: Node(typeID: TestKit.sink, position: GraphPoint(x: 3000, y: -800))))
        try model.perform(.addGroup(group: NodeGroup(title: "G", bounds: GraphRect(x: 100, y: 1500, width: 200, height: 200))))
        model.zoomToFit()
        let visible = model.camera.visibleRect(in: model.viewSize)
        let bounds = try #require(model.contentBounds)
        #expect(visible.contains(bounds))
        #expect(model.camera.zoom < 1)
    }
}
