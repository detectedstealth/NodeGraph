import Foundation
import Testing
@testable import NodeGraphCore

/// Timing guards at 10,000 nodes. Limits are roughly 10x what a debug build takes on a laptop,
/// so they catch an accidental O(n^2) without flaking on a busy machine.
private let nodeCount = 10_000

private struct Rig {
    let nodes: NodeRegistry
    let types: TypeRegistry
    let editor: GraphEditor
    var ids: [NodeID] = []

    init() {
        var registry = NodeRegistry()
        registry.register(NodeDefinition(
            typeID: "add", displayName: "Add",
            ports: [
                PortDefinition(id: "a", direction: .input, defaultValue: 0.0),
                PortDefinition(id: "b", direction: .input, defaultValue: 0.0),
                PortDefinition(id: "out", direction: .output),
            ],
            isPure: true)
        ) { ctx in ["out": .double(try ctx.number("a") + ctx.number("b"))] }
        nodes = registry
        types = TypeRegistry()
        editor = GraphEditor(nodes: registry, types: types)
    }

    /// A chain `0 -> 1 -> ... -> n-1`, built through the editor's single-command path.
    static func chain(editedThroughEditor count: Int) throws -> Rig {
        var rig = Rig()
        for _ in 0..<count {
            let node = Node(typeID: "add")
            try rig.editor.apply(.addNode(node: node))
            rig.ids.append(node.id)
        }
        for i in 1..<count {
            try rig.editor.apply(.addLink(link: Link(
                sourceNode: rig.ids[i - 1], sourcePort: "out", targetNode: rig.ids[i], targetPort: "a")))
        }
        return rig
    }
}

private func measure<T>(_ limit: Duration, _ label: String, _ body: () async throws -> T) async rethrows -> T {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    let took = clock.now - start
    #expect(took < limit * timingScale, "\(label) took \(took); limit \(limit * timingScale)")
    return value
}

@Test func buildingATenThousandNodeGraphOneEditAtATimeIsFast() async throws {
    try await measure(.seconds(15), "10k nodes + 10k links, one command each, fully validated") {
        _ = try Rig.chain(editedThroughEditor: nodeCount)
    }
}

@Test func editsStayCheapOnABigGraph() async throws {
    let rig = try Rig.chain(editedThroughEditor: nodeCount)
    try await measure(.seconds(2), "500 drag edits") {
        for i in 0..<500 {
            try rig.editor.apply(.setNodePositions(placements: [
                NodePlacement(node: rig.ids[5_000], position: GraphPoint(x: Double(i), y: 0))]))
        }
    }
    try await measure(.seconds(2), "100 connect and undo cycles") {
        for _ in 0..<100 {
            let change = try rig.editor.connect(ConnectionProposal(
                source: PortAddress(node: rig.ids[10], port: "out", direction: .output),
                target: PortAddress(node: rig.ids[9_000], port: "b", direction: .input)))
            try rig.editor.revert(change)
        }
    }
}

@Test func aFailedBatchRollsBackWithoutCopyingTheGraph() async throws {
    let rig = try Rig.chain(editedThroughEditor: 2_000)
    let before = rig.editor.graph
    await measure(.seconds(2), "100 failing batches") {
        for _ in 0..<100 {
            #expect(throws: GraphEditError.self) {
                try rig.editor.apply(.batch(commands: [
                    .setNodeAttribute(node: rig.ids[1], attribute: .isPinned(value: true)),
                    .removeNode(id: rig.ids[2]),
                    .removeNode(id: NodeID()),
                ]))
            }
        }
    }
    #expect(rig.editor.graph == before)
}

@Test func compilingAndRunningATenThousandNodeChainIsFast() async throws {
    let rig = try Rig.chain(editedThroughEditor: nodeCount)
    let plan = try await measure(.seconds(3), "compile plan") {
        try ExecutionPlan.compile(rig.editor.graph, nodes: rig.nodes)
    }
    #expect(plan.order == rig.ids)
    let runner = try await measure(.seconds(3), "runner setup") {
        try GraphRunner(graph: rig.editor.graph, registry: rig.nodes)
    }
    let cold = await measure(.seconds(10), "cold pass") { await runner.step() }
    #expect(cold.succeeded && cold.results.count == nodeCount)
    let warm = await measure(.seconds(10), "cached pass") { await runner.step() }
    #expect(warm.cachedNodes.count == nodeCount)
}

@Test func validatingATenThousandNodeGraphIsLinearNotQuadratic() async throws {
    let rig = try Rig.chain(editedThroughEditor: nodeCount)
    let found = await measure(.seconds(10), "validate whole graph") {
        GraphValidator().validate(ValidationContext(graph: rig.editor.graph, nodes: rig.nodes, types: rig.types))
    }
    #expect(found.isEmpty)
}

@Test func aTenThousandNodeRingIsDetectedAsOneCycle() async throws {
    var rig = try Rig.chain(editedThroughEditor: nodeCount)
    // Close the ring behind the editor's back, as a loaded file could.
    var graph = rig.editor.graph
    graph.insert(Link(sourceNode: rig.ids[nodeCount - 1], sourcePort: "out", targetNode: rig.ids[0], targetPort: "b"))
    rig.ids.removeAll()
    let found = await measure(.seconds(10), "validate a ring") {
        GraphValidator().validate(ValidationContext(graph: graph, nodes: rig.nodes, types: rig.types))
    }
    #expect(found.filter { $0.code == .cycle }.count == nodeCount)
}

@Test func savingAndLoadingATenThousandNodeGraphIsFast() async throws {
    let rig = try Rig.chain(editedThroughEditor: nodeCount)
    let data = try await measure(.seconds(5), "encode") { try GraphDocument(graph: rig.editor.graph).encoded() }
    let loaded = try await measure(.seconds(5), "decode") { try GraphDocument.decode(from: data) }
    #expect(loaded.graph == rig.editor.graph)
    #expect(loaded.graph.links(attachedTo: rig.ids[1]).count == 2, "link lookups work after decoding")
}

// MARK: Link index

@Test func linkQueriesStayConsistentThroughEveryKindOfEdit() throws {
    var graph = Graph()
    let a = NodeID(), b = NodeID(), c = NodeID()
    let ab = Link(sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "i")
    let ac = Link(sourceNode: a, sourcePort: "o", targetNode: c, targetPort: "i")
    let cb = Link(sourceNode: c, sourcePort: "o", targetNode: b, targetPort: "i")
    let loop = Link(sourceNode: b, sourcePort: "o", targetNode: b, targetPort: "j")
    for link in [ab, ac, cb, loop] { graph.insert(link) }

    let aOut = PortAddress(node: a, port: "o", direction: .output)
    let bIn = PortAddress(node: b, port: "i", direction: .input)
    #expect(graph.links(from: aOut) == [ab, ac])
    #expect(graph.links(into: bIn) == [ab, cb])
    #expect(graph.links(attachedTo: b) == [ab, cb, loop])
    #expect(graph.outgoingLinks(of: b) == [loop])

    // Re-inserting at a lower index changes storage order, and queries follow it.
    graph.removeLink(cb.id)
    graph.insert(cb, at: 0)
    #expect(graph.links(into: bIn) == [cb, ab])
    #expect(graph.links(attachedTo: b) == [cb, ab, loop])

    // Replacing a link with the same id but new endpoints moves it in the index.
    var moved = ab
    moved.target = PortAddress(node: c, port: "i", direction: .input)
    graph.insert(moved)
    #expect(graph.links(into: bIn) == [cb])
    #expect(graph.links(attachedTo: b) == [cb, loop])
    #expect(graph.links(attachedTo: c).map(\.id) == [cb.id, moved.id, ac.id])

    graph.removeLink(loop.id)
    #expect(graph.links(attachedTo: b) == [cb])
    for link in [cb, moved, ac] { graph.removeLink(link.id) }
    #expect(graph.links(attachedTo: a).isEmpty && graph.links(from: aOut).isEmpty)
}

@Test func graphEqualityIgnoresHowTheIndexWasBuilt() {
    let a = NodeID(), b = NodeID()
    let l1 = Link(sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "i")
    let l2 = Link(sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "j")
    var first = Graph(), second = Graph()
    first.insert(l1); first.insert(l2)
    second.insert(l2); second.insert(l1, at: 0)    // same final order, different history
    #expect(first == second && first.hashValue == second.hashValue)
    second.removeLink(l2.id)
    #expect(first != second)
}

@Test func ignoredLinksAreInvisibleToValidationQueries() {
    var graph = Graph()
    let a = NodeID(), b = NodeID()
    let link = Link(sourceNode: a, sourcePort: "o", targetNode: b, targetPort: "i")
    graph.insert(link)
    var context = ValidationContext(graph: graph, nodes: NodeRegistry(), types: TypeRegistry())
    #expect(context.links(into: link.target) == [link] && context.outgoingLinks(of: a) == [link])
    context.ignoredLink = link.id
    #expect(context.links(into: link.target).isEmpty && context.links(from: link.source).isEmpty)
    #expect(context.outgoingLinks(of: a).isEmpty)
}
