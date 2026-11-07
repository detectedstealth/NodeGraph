import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct HitTestingTests {
    private func add(_ model: GraphEditorModel, _ type: NodeTypeID, x: Double, y: Double = 0) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y))
        try model.perform(.addNode(node: node))
        return node
    }

    @Test func nodeAtPointFindsTheNodeUnderIt() throws {
        let model = TestKit.makeModel()
        let a = try add(model, TestKit.source, x: 0)
        let b = try add(model, TestKit.sink, x: 500)
        #expect(model.node(at: GraphPoint(x: 10, y: 10)) == a.id)
        #expect(model.node(at: GraphPoint(x: 510, y: 10)) == b.id)
        #expect(model.node(at: GraphPoint(x: 300, y: 10)) == nil)
    }

    @Test func overlappingNodesHitTheLaterOne() throws {
        let model = TestKit.makeModel()
        _ = try add(model, TestKit.source, x: 0)
        let top = try add(model, TestKit.source, x: 20)
        #expect(model.node(at: GraphPoint(x: 30, y: 10)) == top.id)
    }

    @Test func hitTestFollowsMovesAndUndo() throws {
        let model = TestKit.makeModel()
        let a = try add(model, TestKit.source, x: 0)
        #expect(model.node(at: GraphPoint(x: 10, y: 10)) == a.id)
        try model.perform(.setNodePositions(placements: [NodePlacement(node: a.id, position: GraphPoint(x: 800, y: 0))]))
        #expect(model.node(at: GraphPoint(x: 10, y: 10)) == nil)
        #expect(model.node(at: GraphPoint(x: 810, y: 10)) == a.id)
        try model.undo()
        #expect(model.node(at: GraphPoint(x: 10, y: 10)) == a.id)
    }

    @Test func portHitIncludesTheHalfOutsideTheFrame() throws {
        let model = TestKit.makeModel()
        let sink = try add(model, TestKit.sink, x: 100, y: 100)
        let port = try #require(model.layout(of: sink.id)?.inputs[0])
        // Just left of the node, outside its frame but inside the port's hit radius.
        let hit = model.port(at: GraphPoint(x: port.position.x - 4, y: port.position.y))
        #expect(hit?.address == port.address)
        #expect(model.node(at: GraphPoint(x: port.position.x - 4, y: port.position.y)) == nil)
        #expect(model.port(at: GraphPoint(x: port.position.x - 60, y: port.position.y)) == nil)
    }

    @Test func groupsSitBelowNodes() throws {
        let model = TestKit.makeModel()
        let group = NodeGroup(title: "G", bounds: GraphRect(x: -50, y: -50, width: 600, height: 400))
        try model.perform(.addGroup(group: group))
        let node = try add(model, TestKit.source, x: 0)
        #expect(model.group(at: GraphPoint(x: 300, y: 300)) == group.id)
        #expect(model.node(at: GraphPoint(x: 300, y: 300)) == nil)
        let items = model.items(in: GraphRect(x: 0, y: 0, width: 10, height: 10))
        #expect(items == [.group(group.id), .node(node.id)])
    }

    @Test func linksAreIndexedAndCulled() throws {
        let model = TestKit.makeModel()
        let source = try add(model, TestKit.source, x: 0)
        let sink = try add(model, TestKit.sink, x: 1000)
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let link = try #require(model.graph.links.keys.first)
        let middle = model.items(in: GraphRect(x: 500, y: 0, width: 20, height: 100))
        #expect(middle == [.link(link)])
        #expect(model.items(in: GraphRect(x: 500, y: 3000, width: 20, height: 20)).isEmpty)
    }

    @Test func marqueeSelectsIntersectingOrFullyContainedNodes() throws {
        let model = TestKit.makeModel()
        let a = try add(model, TestKit.source, x: 0)
        let b = try add(model, TestKit.source, x: 300)
        let marquee = GraphRect(x: -10, y: -10, width: 400, height: 120)
        #expect(model.nodes(in: marquee) == [a.id, b.id])
        #expect(model.nodes(in: marquee, fullyInside: true) == [a.id])
    }

    @Test func tenThousandNodesBuildAndQueryQuickly() throws {
        var graph = Graph()
        let columns = 100
        var commands: [GraphCommand] = []
        for i in 0..<10_000 {
            let node = Node(
                typeID: TestKit.sink,
                position: GraphPoint(x: Double(i % columns) * 220, y: Double(i / columns) * 120))
            commands.append(.addNode(node: node))
        }
        let (nodes, types) = TestKit.registries()
        let editor = GraphEditor(graph: graph, nodes: nodes, types: types)
        try editor.apply(.batch(commands: commands), validation: .structural)
        graph = editor.graph
        let model = GraphEditorModel(editor: editor)

        let clock = ContinuousClock()
        let build = clock.measure {
            // First query builds layouts and the index for all 10k nodes.
            #expect(model.node(at: GraphPoint(x: 5, y: 5)) != nil)
        }
        let queries = clock.measure {
            for i in 0..<1000 {
                _ = model.items(in: GraphRect(x: Double(i % 50) * 220, y: Double(i % 40) * 120, width: 1200, height: 800))
            }
        }
        #expect(build < .seconds(2))
        #expect(queries < .seconds(1))
    }
}

@MainActor
@Suite struct LinkPickingTests {
    @Test func picksTheLinkNearThePointAndIgnoresFarOnes() throws {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 600, y: 300))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let link = try #require(model.graph.links.values.first)
        let path = try #require(model.linkPath(of: link))
        let onPath = path.polyline(curveSteps: 32)[16]
        #expect(model.link(at: GraphPoint(x: onPath.x + 2, y: onPath.y), tolerance: 6) == link.id)
        #expect(model.link(at: GraphPoint(x: onPath.x, y: onPath.y + 200), tolerance: 6) == nil)
    }

    @Test func changingTheStyleReroutesPicking() throws {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 600, y: 300))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let link = try #require(model.graph.links.values.first)
        let splineMiddle = try #require(model.linkPath(of: link)).polyline(curveSteps: 32)[6]
        model.linkStyle = .orthogonal
        let orthogonalPath = try #require(model.linkPath(of: link))
        #expect(orthogonalPath.distance(to: splineMiddle) != 0)
        #expect(model.link(at: orthogonalPath.polyline()[1], tolerance: 2) == link.id)
    }
}
