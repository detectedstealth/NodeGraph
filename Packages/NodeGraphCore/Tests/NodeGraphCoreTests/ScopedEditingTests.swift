import Testing
@testable import NodeGraphCore

/// Connecting and moving groups inside a subgraph's inner graph.
@Suite struct ScopedEditingTests {
    private func makeEditor() throws -> (GraphEditor, Adder) {
        let (nodes, types) = registries()
        let editor = GraphEditor(nodes: nodes, types: types)
        let adder = Adder()
        try editor.apply(.addSubgraph(definition: adder.definition))
        return (editor, adder)
    }

    @Test func editedGraphResolvesTheScope() throws {
        let (editor, adder) = try makeEditor()
        #expect(editor.editedGraph(in: nil) == editor.graph)
        #expect(editor.editedGraph(in: adder.definition.id) == adder.definition.graph)
        #expect(editor.editedGraph(in: SubgraphID()) == nil)
        #expect(editor.validationContext(in: SubgraphID()) == nil)
        #expect(editor.validationContext(in: adder.definition.id)?.graph == adder.definition.graph)
    }

    @Test func connectingInsideASubgraphChangesTheInnerGraphOnly() throws {
        let (editor, adder) = try makeEditor()
        let id = adder.definition.id
        let extra = Node(typeID: "const")
        try editor.apply(.inSubgraph(id: id, command: .addNode(node: extra)))
        // The inner constant already feeds b; a is free.
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: extra.id, port: "out", direction: .output),
            target: PortAddress(node: adder.add, port: "a", direction: .input)), in: id)
        let inner = try #require(editor.editedGraph(in: id))
        #expect(inner.links.count == 2)
        #expect(inner.links.values.contains { $0.source.node == extra.id && $0.target.port == "a" })
        #expect(editor.graph.links.isEmpty)
    }

    @Test func aScopedConnectionReplacesAnOccupiedInputAsOneUndoableCommand() throws {
        let (editor, adder) = try makeEditor()
        let id = adder.definition.id
        let extra = Node(typeID: "const")
        try editor.apply(.inSubgraph(id: id, command: .addNode(node: extra)))
        let command = try editor.connectCommand(for: ConnectionProposal(
            source: PortAddress(node: extra.id, port: "out", direction: .output),
            target: PortAddress(node: adder.add, port: "b", direction: .input)), in: id)
        guard case .inSubgraph(let scope, _) = command else {
            Issue.record("expected a scoped command")
            return
        }
        #expect(scope == id)
        let change = try editor.apply(command)
        let inner = try #require(editor.editedGraph(in: id))
        #expect(inner.links.count == 1 && inner.links.values.first?.source.node == extra.id)
        try editor.revert(change)
        #expect(editor.editedGraph(in: id) == adder.definition.graph.inserting(extra))
    }

    @Test func connectionRulesApplyInsideTheScope() throws {
        let (editor, adder) = try makeEditor()
        // A node cannot connect to itself.
        #expect(throws: GraphEditError.self) {
            try editor.connect(ConnectionProposal(
                source: PortAddress(node: adder.add, port: "out", direction: .output),
                target: PortAddress(node: adder.add, port: "a", direction: .input)), in: adder.definition.id)
        }
    }

    @Test func aMissingScopeIsReported() throws {
        let (editor, _) = try makeEditor()
        #expect(throws: GraphEditError.self) {
            try editor.connectCommand(for: ConnectionProposal(
                source: PortAddress(node: NodeID(), port: "out", direction: .output),
                target: PortAddress(node: NodeID(), port: "a", direction: .input)), in: SubgraphID())
        }
    }

    @Test func historyRecordsAScopedConnection() throws {
        let (editor, adder) = try makeEditor()
        let id = adder.definition.id
        let extra = Node(typeID: "const")
        try editor.apply(.inSubgraph(id: id, command: .addNode(node: extra)))
        let history = GraphHistory(editor: editor)
        try history.connect(ConnectionProposal(
            source: PortAddress(node: extra.id, port: "out", direction: .output),
            target: PortAddress(node: adder.add, port: "a", direction: .input)), in: id)
        #expect(editor.editedGraph(in: id)?.links.count == 2)
        try history.undo()
        #expect(editor.editedGraph(in: id)?.links.count == 1)
        try history.redo()
        #expect(editor.editedGraph(in: id)?.links.count == 2)
    }

    @Test func groupMovesWorkInsideAScope() throws {
        let (editor, adder) = try makeEditor()
        let id = adder.definition.id
        let inner = Node(typeID: "const", position: GraphPoint(x: 20, y: 20))
        let group = NodeGroup(title: "G", bounds: GraphRect(x: 0, y: 0, width: 400, height: 300))
        try editor.apply(.inSubgraph(id: id, command: .batch(commands: [.addNode(node: inner), .addGroup(group: group)])))
        let move = try editor.beginGroupMove(group.id, in: id)
        #expect(move.members.map(\.node).contains(inner.id))
        try editor.apply(.inSubgraph(id: id, command: move.command(delta: GraphPoint(x: 50, y: 0))))
        let moved = try #require(editor.editedGraph(in: id))
        #expect(moved.groups[group.id]?.bounds.origin == GraphPoint(x: 50, y: 0))
        #expect(moved.nodes[inner.id]?.position == GraphPoint(x: 70, y: 20))
        #expect(throws: GraphEditError.self) { try editor.beginGroupMove(group.id) }  // not in the root graph
        #expect(throws: GraphEditError.self) { try editor.beginGroupMove(group.id, in: SubgraphID()) }
    }
}

private extension Graph {
    /// A copy with `node` added at the end, for comparing against an editor's graph.
    func inserting(_ node: Node) -> Graph {
        var copy = self
        copy.insert(node)
        return copy
    }
}
