import Foundation
import Testing
@testable import NodeGraphCore

private func registry() -> NodeRegistry {
    var nodes = NodeRegistry()
    // Reads the variable named by its `name` property.
    nodes.register(NodeDefinition(
        typeID: "read", displayName: "Read",
        ports: [PortDefinition(id: "out", direction: .output)],
        properties: [PropertyDefinition(id: "name", displayName: "Name", kind: .string(), defaultValue: "x")])
    ) { ctx in ["out": try ctx.variable(try ctx.property("name").stringValue ?? "")] }
    return nodes
}

private let gain = GraphVariable(name: "gain", type: "number", value: .double(2), summary: "Output gain")

@Suite struct GraphVariableEditingTests {
    private func editor() -> GraphEditor { GraphEditor(nodes: registry(), types: TypeRegistry()) }

    @Test func addUpdateRemoveAndUndoThroughHistory() throws {
        let editor = editor()
        let history = GraphHistory(editor: editor)
        try history.perform(.addVariable(variable: gain))
        try history.perform(.addVariable(variable: GraphVariable(name: "label", value: .string("a"))))
        #expect(Array(editor.graph.variables.keys) == ["gain", "label"])

        var louder = gain
        louder.value = .double(5)
        try history.perform(.updateVariable(variable: louder))
        #expect(editor.graph.variables["gain"]?.value == .double(5))
        try history.undo()
        #expect(editor.graph.variables["gain"]?.value == .double(2))

        try history.perform(.removeVariable(name: "gain"))
        #expect(Array(editor.graph.variables.keys) == ["label"])
        try history.undo()
        #expect(Array(editor.graph.variables.keys) == ["gain", "label"], "undo restores the declaration order")
        try history.redo()
        #expect(editor.graph.variables["gain"] == nil)
    }

    @Test func badEditsAreRefusedAndChangeNothing() throws {
        let editor = editor()
        try editor.apply(.addVariable(variable: gain))
        #expect(throws: GraphEditError.duplicateVariable("gain")) { try editor.apply(.addVariable(variable: gain)) }
        #expect(throws: GraphEditError.invalidVariableName) {
            try editor.apply(.addVariable(variable: GraphVariable(name: "  ", value: .null)))
        }
        #expect(throws: GraphEditError.invalidVariableName) {
            try editor.apply(.addVariable(variable: GraphVariable(name: "", value: .null)))
        }
        #expect(throws: GraphEditError.variableNotFound("nope")) { try editor.apply(.removeVariable(name: "nope")) }
        #expect(throws: GraphEditError.variableNotFound("nope")) {
            try editor.apply(.updateVariable(variable: GraphVariable(name: "nope", value: .null)))
        }
        #expect(throws: GraphEditError.indexOutOfRange(5)) { try editor.apply(.addVariable(variable: GraphVariable(name: "z", value: .null), index: 5)) }
        #expect(editor.graph.variables.count == 1)
    }

    @Test func variablesAreRootOnly() throws {
        let editor = editor()
        let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Inner"), graph: Graph())
        try editor.apply(.addSubgraph(definition: definition))
        #expect(throws: GraphEditError.invalidScope) {
            try editor.apply(.inSubgraph(id: definition.id, command: .addVariable(variable: gain)))
        }
    }

    @Test func repeatedUpdatesOfOneVariableMergeIntoOneStep() throws {
        let editor = editor()
        let history = GraphHistory(editor: editor)
        try history.perform(.addVariable(variable: gain))
        history.endCoalescing()
        for value in [3.0, 4.0, 5.0] {
            var changed = gain
            changed.value = .double(value)
            try history.perform(.updateVariable(variable: changed), coalescing: true)
        }
        try history.undo()
        #expect(editor.graph.variables["gain"]?.value == .double(2), "one undo reverts the whole sweep")
    }

    @Test func variablesRoundTripThroughTheDocumentAndAreOmittedWhenThereAreNone() throws {
        var graph = Graph()
        #expect(!(String(decoding: try GraphDocument(graph: graph).encoded(), as: UTF8.self)).contains("variables"))
        let editor = GraphEditor(graph: graph, nodes: registry(), types: TypeRegistry())
        try editor.apply(.addVariable(variable: gain))
        try editor.apply(.addVariable(variable: GraphVariable(name: "a", value: .int(1))))
        graph = editor.graph
        let data = try GraphDocument(graph: graph).encoded()
        let loaded = try GraphDocument.decode(from: data)
        #expect(loaded.graph == graph)
        #expect(Array(loaded.graph.variables.keys) == ["gain", "a"], "order is kept")
        #expect(try GraphDocument(graph: loaded.graph).encoded() == data, "saving again gives the same bytes")
    }

    @Test func aFileWithTwoVariablesOfOneNameIsRefused() {
        let json = #"{"schemaVersion":1,"graph":{"nodes":[],"links":[],"groups":[],"variables":[{"name":"a","type":"any","value":{"type":"null"},"summary":""},{"name":"a","type":"any","value":{"type":"null"},"summary":""}]},"metadata":{}}"#
        #expect(throws: (any Error).self) { try GraphDocument.decode(from: Data(json.utf8)) }
    }

    @Test func variablesCountInGraphEquality() throws {
        let editor = editor()
        let before = editor.graph
        try editor.apply(.addVariable(variable: gain))
        #expect(editor.graph != before)
    }
}

@Suite struct VariableRunTests {
    private func graph(reading names: [String] = ["gain"], declaring: [GraphVariable] = [gain]) throws -> (Graph, [NodeID]) {
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        for variable in declaring { try editor.apply(.addVariable(variable: variable)) }
        var ids: [NodeID] = []
        for name in names {
            let node = Node(typeID: "read", properties: ["name": .string(name)])
            try editor.apply(.addNode(node: node))
            ids.append(node.id)
        }
        return (editor.graph, ids)
    }

    @Test func nodesReadTheDeclaredValue() async throws {
        let (graph, ids) = try graph()
        let runner = try GraphRunner(graph: graph, registry: registry())
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .double(2)])
        #expect(await runner.variables == ["gain": .double(2)])
    }

    @Test func anOverrideReplacesItFromTheNextPassAndNilRestoresIt() async throws {
        let (graph, ids) = try graph()
        let runner = try GraphRunner(graph: graph, registry: registry())
        _ = await runner.step()
        try await runner.setVariable("gain", to: .double(9))
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .double(9)])
        try await runner.setVariable("gain", to: nil)
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .double(2)])
        // The graph itself never changed.
        #expect(graph.variables["gain"]?.value == .double(2))
    }

    @Test func overridesCanBeGivenAtStartAndAreChecked() async throws {
        let (graph, ids) = try graph()
        let runner = try GraphRunner(graph: graph, registry: registry(), variables: ["gain": .double(7)])
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .double(7)])
        #expect(throws: VariableOverrideError.undeclared("nope")) {
            _ = try GraphRunner(graph: graph, registry: registry(), variables: ["nope": .int(1)])
        }
        #expect(throws: VariableOverrideError.kindMismatch(name: "gain", expected: "double", found: "int")) {
            _ = try GraphRunner(graph: graph, registry: registry(), variables: ["gain": .int(1)])
        }
    }

    @Test func aRefusedOverrideChangesNothing() async throws {
        let (graph, ids) = try graph(declaring: [gain, GraphVariable(name: "label", value: .string("a"))])
        let runner = try GraphRunner(graph: graph, registry: registry(), variables: ["gain": .double(7)])
        await #expect(throws: VariableOverrideError.undeclared("nope")) {
            try await runner.setVariables(["gain": .double(1), "nope": .int(1)])
        }
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .double(7)], "the earlier override is untouched")
        try await runner.setVariables([:])
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .double(2)])
    }

    @Test func aMissingVariableFailsTheNodeWithItsName() async throws {
        let (graph, ids) = try graph(reading: ["missing"])
        let tick = await (try GraphRunner(graph: graph, registry: registry())).step()
        guard case .failure(let failure)? = tick.results[ids[0]]?.outcome else { Issue.record("expected a failure"); return }
        #expect(failure.message.contains("no variable named \"missing\""))
    }

    @Test func updatingTheGraphPicksUpNewDefaultsAndDropsStaleOverrides() async throws {
        let (graph, ids) = try graph(declaring: [gain, GraphVariable(name: "gone", value: .int(1))])
        let runner = try GraphRunner(graph: graph, registry: registry(), variables: ["gain": .double(7), "gone": .int(5)])
        let editor = GraphEditor(graph: graph, nodes: registry(), types: TypeRegistry())
        var changed = gain
        changed.value = .string("now text")
        try editor.apply(.updateVariable(variable: changed))     // another kind: the override no longer fits
        try editor.apply(.removeVariable(name: "gone"))
        try await runner.update(graph: editor.graph, registry: registry())
        #expect(await runner.variables == ["gain": .string("now text")])
        #expect(await runner.step().outputs(of: ids[0]) == ["out": .string("now text")])
    }

    @Test func aValueChangeReachesNodesThatWereCachedBefore() async throws {
        // A pure node downstream of the reader must recompute when the variable changes.
        var nodes = registry()
        nodes.register(NodeDefinition(
            typeID: "double", displayName: "Double",
            ports: [PortDefinition(id: "in", direction: .input), PortDefinition(id: "out", direction: .output)],
            isPure: true)
        ) { ctx in ["out": .double((try ctx.number("in")) * 2)] }
        let editor = GraphEditor(nodes: nodes, types: TypeRegistry())
        try editor.apply(.addVariable(variable: gain))
        let reader = Node(typeID: "read"), doubler = Node(typeID: "double")
        try editor.apply(.addNode(node: Node(id: reader.id, typeID: "read", properties: ["name": "gain"])))
        try editor.apply(.addNode(node: doubler))
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: reader.id, port: "out", direction: .output),
            target: PortAddress(node: doubler.id, port: "in", direction: .input)))
        let runner = try GraphRunner(graph: editor.graph, registry: nodes)
        #expect(await runner.step().outputs(of: doubler.id) == ["out": .double(4)])
        try await runner.setVariable("gain", to: .double(10))
        #expect(await runner.step().outputs(of: doubler.id) == ["out": .double(20)])
    }
}
