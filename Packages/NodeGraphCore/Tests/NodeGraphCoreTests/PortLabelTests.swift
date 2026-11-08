import Foundation
import Testing
@testable import NodeGraphCore

private func registry() -> NodeRegistry {
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "gain", displayName: "Gain",
        ports: [
            PortDefinition(id: "in", displayName: "Input", direction: .input),
            PortDefinition(id: "value", displayName: "Value", direction: .output),
        ],
        isPure: true)
    ) { ctx in ["value": try ctx.input("in")] }
    nodes.register(NodeDefinition(
        typeID: "sum", displayName: "Sum",
        ports: [PortDefinition(id: "out", direction: .output)],
        dynamicPorts: [DynamicPortGroup(id: "in", displayName: "Input", direction: .input, minimum: 1)])
    ) { _ in .empty }
    return nodes
}

@Suite struct PortLabelTests {
    private func editor() -> GraphEditor { GraphEditor(nodes: registry(), types: TypeRegistry()) }

    @Test func aLabelReplacesTheShownNameInTheResolvedDefinitionOnly() throws {
        let editor = editor()
        let node = Node(typeID: "gain")
        try editor.apply(.addNode(node: node))
        try editor.apply(.setPortLabel(node: node.id, port: "value", direction: .output, label: "Elapsed"))

        let resolved = try #require(editor.nodes.definition(for: editor.graph.nodes[node.id]!))
        #expect(resolved.port("value", direction: .output)?.displayName == "Elapsed")
        #expect(resolved.port("in", direction: .input)?.displayName == "Input", "other ports keep their names")
        #expect(editor.nodes.definition(for: "gain")?.port("value", direction: .output)?.displayName == "Value",
                "the type itself is unchanged, so other nodes are unaffected")
    }

    @Test func linksSurviveBecauseThePortIdNeverChanges() throws {
        let editor = editor()
        let a = Node(typeID: "gain"), b = Node(typeID: "gain")
        try editor.apply(.addNode(node: a))
        try editor.apply(.addNode(node: b))
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: a.id, port: "value", direction: .output),
            target: PortAddress(node: b.id, port: "in", direction: .input)))
        try editor.apply(.setPortLabel(node: a.id, port: "value", direction: .output, label: "Level"))
        try editor.apply(.setPortLabel(node: b.id, port: "in", direction: .input, label: "Level"))
        #expect(editor.graph.links.count == 1)
        #expect(GraphValidator(connections: editor.connectionValidator).validate(editor.validationContext).isEmpty)
    }

    @Test func inputAndOutputWithTheSameIdAreLabeledSeparately() throws {
        var nodes = NodeRegistry()
        nodes.register(NodeDefinition(
            typeID: "same", displayName: "Same",
            ports: [
                PortDefinition(id: "value", direction: .input),
                PortDefinition(id: "value", direction: .output),
            ])
        ) { _ in .empty }
        let editor = GraphEditor(nodes: nodes, types: TypeRegistry())
        let node = Node(typeID: "same")
        try editor.apply(.addNode(node: node))
        try editor.apply(.setPortLabel(node: node.id, port: "value", direction: .output, label: "Out"))
        let resolved = try #require(nodes.definition(for: editor.graph.nodes[node.id]!))
        #expect(resolved.port("value", direction: .input)?.displayName == "value")
        #expect(resolved.port("value", direction: .output)?.displayName == "Out")
    }

    @Test func clearingGoesBackToTheTypesNameAndWhitespaceIsTrimmed() throws {
        let editor = editor()
        let node = Node(typeID: "gain")
        try editor.apply(.addNode(node: node))
        try editor.apply(.setPortLabel(node: node.id, port: "in", direction: .input, label: "  Level  "))
        #expect(editor.graph.nodes[node.id]?.portLabels == ["input:in": "Level"])
        try editor.apply(.setPortLabel(node: node.id, port: "in", direction: .input, label: "   "))
        #expect(editor.graph.nodes[node.id]?.portLabels.isEmpty == true, "blank clears, and the map stays canonical")
        try editor.apply(.setPortLabel(node: node.id, port: "in", direction: .input, label: "x"))
        try editor.apply(.setPortLabel(node: node.id, port: "in", direction: .input, label: nil))
        #expect(editor.graph.nodes[node.id]?.portLabels.isEmpty == true)
    }

    @Test func undoRedoAndCoalescingThroughHistory() throws {
        let editor = editor()
        let history = GraphHistory(editor: editor)
        let node = Node(typeID: "gain")
        try history.perform(.addNode(node: node))
        history.endCoalescing()
        for text in ["L", "Le", "Lev"] {
            try history.perform(.setPortLabel(node: node.id, port: "in", direction: .input, label: text), coalescing: true)
        }
        #expect(editor.graph.nodes[node.id]?.portLabels["input:in"] == "Lev")
        try history.undo()
        #expect(editor.graph.nodes[node.id]?.portLabels.isEmpty == true, "typing is one undo step")
        try history.redo()
        #expect(editor.graph.nodes[node.id]?.portLabels["input:in"] == "Lev")
    }

    @Test func badTargetsAreRefused() throws {
        let editor = editor()
        let node = Node(typeID: "gain")
        try editor.apply(.addNode(node: node))
        #expect(throws: GraphEditError.portNotFound(node: node.id, port: "nope", direction: .input)) {
            try editor.apply(.setPortLabel(node: node.id, port: "nope", direction: .input, label: "x"))
        }
        #expect(throws: GraphEditError.portNotFound(node: node.id, port: "in", direction: .output)) {
            try editor.apply(.setPortLabel(node: node.id, port: "in", direction: .output, label: "x"))
        }
        let missing = NodeID()
        #expect(throws: GraphEditError.nodeNotFound(missing)) {
            try editor.apply(.setPortLabel(node: missing, port: "in", direction: .input, label: "x"))
        }
    }

    @Test func aDynamicPortKeepsItsLabelWhileTheGroupShrinksAndGrows() throws {
        let editor = editor()
        let node = Node(typeID: "sum", portCounts: ["in": 3])
        try editor.apply(.addNode(node: node))
        try editor.apply(.setPortLabel(node: node.id, port: "in_3", direction: .input, label: "Third"))
        try editor.apply(.setPortCount(node: node.id, group: "in", count: 2))
        let shrunk = try #require(editor.nodes.definition(for: editor.graph.nodes[node.id]!))
        #expect(shrunk.inputs.map(\.displayName) == ["Input 1", "Input 2"])
        try editor.apply(.setPortCount(node: node.id, group: "in", count: 3))
        let grown = try #require(editor.nodes.definition(for: editor.graph.nodes[node.id]!))
        #expect(grown.inputs.map(\.displayName) == ["Input 1", "Input 2", "Third"])
    }

    @Test func labelsWorkInsideASubgraph() throws {
        let editor = editor()
        let inner = Node(typeID: "gain")
        let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Inner"), graph: Graph())
        try editor.apply(.addSubgraph(definition: definition))
        try editor.apply(.inSubgraph(id: definition.id, command: .addNode(node: inner)))
        try editor.apply(.inSubgraph(
            id: definition.id, command: .setPortLabel(node: inner.id, port: "value", direction: .output, label: "Result")))
        #expect(editor.subgraphs[definition.id]?.graph.nodes[inner.id]?.portLabels["output:value"] == "Result")
    }

    @Test func labelsRoundTripThroughTheDocumentAndAreOmittedWhenThereAreNone() throws {
        let editor = editor()
        let node = Node(typeID: "gain")
        try editor.apply(.addNode(node: node))
        let bare = try GraphDocument(graph: editor.graph).encoded()
        #expect(!String(decoding: bare, as: UTF8.self).contains("portLabels"), "old files and the golden file are unchanged")

        try editor.apply(.setPortLabel(node: node.id, port: "value", direction: .output, label: "Elapsed"))
        let data = try GraphDocument(graph: editor.graph).encoded()
        let loaded = try GraphDocument.decode(from: data)
        #expect(loaded.graph == editor.graph)
        #expect(loaded.graph.nodes[node.id]?.portLabels == ["output:value": "Elapsed"])
        #expect(try GraphDocument(graph: loaded.graph).encoded() == data)
    }

    @Test func copiedNodesKeepTheirLabels() throws {
        let editor = editor()
        let node = Node(typeID: "gain")
        try editor.apply(.addNode(node: node))
        try editor.apply(.setPortLabel(node: node.id, port: "in", direction: .input, label: "Level"))
        let fragment = try editor.fragment(nodes: [node.id])
        #expect(fragment.nodes.first?.portLabels == ["input:in": "Level"])
        let paste = try editor.pasteCommand(fragment, translatedBy: GraphPoint(x: 0, y: 100))
        try editor.apply(paste.command)
        let copy = try #require(editor.graph.nodes.values.first { $0.id != node.id })
        #expect(copy.portLabels == ["input:in": "Level"], "a pasted node keeps its labels")
    }
}
