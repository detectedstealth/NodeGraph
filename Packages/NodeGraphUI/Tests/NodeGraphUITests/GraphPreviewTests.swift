import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct GraphPreviewTests {
    /// A model with a source and a sink, and the graph a change would leave: a relay added, the
    /// sink removed and the source moved.
    private func makeCase() throws -> (model: GraphEditorModel, source: Node, sink: Node, relay: Node, result: Graph) {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        for node in [source, sink] { try model.perform(.addNode(node: node)) }
        let relay = Node(typeID: TestKit.relay, position: GraphPoint(x: 150, y: 100))
        let (nodes, types) = TestKit.registries()
        let scratch = GraphEditor(graph: model.graph, nodes: nodes, types: types)
        try scratch.apply(.addNode(node: relay))
        try scratch.apply(.removeNode(id: sink.id))
        try scratch.apply(.setNodePositions(placements: [NodePlacement(node: source.id, position: GraphPoint(x: 10, y: 0))]))
        return (model, source, sink, relay, scratch.graph)
    }

    @Test func comparesTwoGraphsByIdentity() throws {
        let c = try makeCase()
        let preview = GraphPreview(base: c.model.graph, result: c.result)
        #expect(preview.addedNodes == [c.relay.id])
        #expect(preview.removedNodes == [c.sink.id])
        #expect(preview.changedNodes == [c.source.id])
        #expect(preview.ghostNodes == [c.relay.id, c.source.id])
        #expect(!preview.isEmpty)
        #expect(GraphPreview(base: c.model.graph, result: c.model.graph).isEmpty)
    }

    @Test func ghostLayoutsComeFromTheResultGraph() throws {
        let c = try makeCase()
        c.model.preview = GraphPreview(base: c.model.graph, result: c.result)
        #expect(c.model.layout(of: c.relay.id) == nil)
        #expect(c.model.ghostLayout(of: c.relay.id)?.frame.minX == 150)
        #expect(c.model.ghostLayout(of: c.source.id)?.frame.minX == 10)
        #expect(c.model.layout(of: c.source.id)?.frame.minX == 0)
        #expect(c.model.ghostLayout(of: c.sink.id) == nil)
    }

    @Test func acceptingIsOneUndoStepAndRejectingChangesNothing() throws {
        let c = try makeCase()
        let before = c.model.graph
        c.model.preview = GraphPreview(base: before, result: c.result)
        c.model.preview = nil
        #expect(c.model.graph == before)

        let steps = c.model.history.recordedStepCount
        try c.model.perform(.batch(commands: [
            .addNode(node: c.relay), .removeNode(id: c.sink.id),
            .setNodePositions(placements: [NodePlacement(node: c.source.id, position: GraphPoint(x: 10, y: 0))]),
        ]), name: "Proposal")
        #expect(c.model.history.recordedStepCount == steps + 1)
        #expect(c.model.graph == c.result)
        try c.model.undo()
        #expect(c.model.graph == before)
    }
}
