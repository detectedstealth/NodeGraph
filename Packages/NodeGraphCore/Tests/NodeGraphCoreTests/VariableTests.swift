import Foundation
import Testing
@testable import NodeGraphCore

private func registry() -> NodeRegistry {
    var nodes = NodeRegistry()
    // Reads the variable named by its `name` property.
    nodes.register(NodeDefinition(
        typeID: "read", displayName: "Read",
        ports: [PortDefinition(id: "out", direction: .output)],
        properties: [PropertyDefinition(id: "name", displayName: "Name", kind: .variable, defaultValue: "x")])
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

@Suite struct VariableRenameTests {
    private func editor() throws -> GraphEditor {
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        try editor.apply(.addVariable(variable: GraphVariable(name: "first", value: .int(1))))
        try editor.apply(.addVariable(variable: gain))
        try editor.apply(.addVariable(variable: GraphVariable(name: "last", value: .int(3))))
        return editor
    }

    private func reader(_ name: String, in editor: GraphEditor, scope: SubgraphID? = nil) throws -> NodeID {
        let node = Node(typeID: "read", properties: ["name": .string(name)])
        let add = GraphCommand.addNode(node: node)
        try editor.apply(scope.map { .inSubgraph(id: $0, command: add) } ?? add)
        return node.id
    }

    @Test func renamingKeepsThePositionAndFollowsEveryReader() async throws {
        let editor = try editor()
        let history = GraphHistory(editor: editor)
        let a = try reader("gain", in: editor), b = try reader("gain", in: editor), other = try reader("last", in: editor)
        let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Inner"), graph: Graph())
        try editor.apply(.addSubgraph(definition: definition))
        let inner = try reader("gain", in: editor, scope: definition.id)

        try history.perform(try editor.renameVariableCommand(from: "gain", to: "volume"))
        #expect(Array(editor.graph.variables.keys) == ["first", "volume", "last"])
        #expect(editor.graph.variables["volume"]?.value == .double(2), "the value and summary come along")
        #expect(editor.graph.variables["volume"]?.summary == "Output gain")
        for id in [a, b] { #expect(editor.graph.nodes[id]?.properties["name"] == "volume") }
        #expect(editor.graph.nodes[other]?.properties["name"] == "last", "readers of other variables are left alone")
        #expect(editor.subgraphs[definition.id]?.graph.nodes[inner]?.properties["name"] == "volume")

        let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes, subgraphs: Array(editor.subgraphs.values))
        #expect(await runner.step().outputs(of: a) == ["out": .double(2)], "still reads the value after the rename")

        try history.undo()
        #expect(Array(editor.graph.variables.keys) == ["first", "gain", "last"], "one undo restores everything")
        for id in [a, b] { #expect(editor.graph.nodes[id]?.properties["name"] == "gain") }
        #expect(editor.subgraphs[definition.id]?.graph.nodes[inner]?.properties["name"] == "gain")
        try history.redo()
        #expect(editor.graph.variables["volume"] != nil)
    }

    @Test func aNodeThatAlreadyPointsAtTheNewNameIsNotTouchedByUndo() throws {
        // It referred to a name nobody declared yet; undoing the rename must not rewrite it.
        let editor = try editor()
        let history = GraphHistory(editor: editor)
        let dangling = try reader("volume", in: editor), real = try reader("gain", in: editor)
        try history.perform(try editor.renameVariableCommand(from: "gain", to: "volume"))
        try history.undo()
        #expect(editor.graph.nodes[dangling]?.properties["name"] == "volume")
        #expect(editor.graph.nodes[real]?.properties["name"] == "gain")
    }

    @Test func badRenamesAreRefused() throws {
        let editor = try editor()
        #expect(throws: GraphEditError.variableNotFound("nope")) { try editor.renameVariableCommand(from: "nope", to: "x") }
        #expect(throws: GraphEditError.invalidVariableName) { try editor.renameVariableCommand(from: "gain", to: "  ") }
        #expect(throws: GraphEditError.duplicateVariable("last")) { try editor.renameVariableCommand(from: "gain", to: "last") }
    }

    @Test func aStringPropertyThatHappensToMatchIsNotARename() throws {
        // Only properties of kind .variable are readers; a plain string property is left alone.
        var nodes = registry()
        nodes.register(NodeDefinition(
            typeID: "label", displayName: "Label", ports: [],
            properties: [PropertyDefinition(id: "text", displayName: "Text", kind: .string(), defaultValue: "")])
        ) { _ in .empty }
        let editor = GraphEditor(nodes: nodes, types: TypeRegistry())
        try editor.apply(.addVariable(variable: gain))
        let label = Node(typeID: "label", properties: ["text": "gain"])
        try editor.apply(.addNode(node: label))
        try editor.apply(try editor.renameVariableCommand(from: "gain", to: "volume"))
        #expect(editor.graph.nodes[label.id]?.properties["text"] == "gain")
    }

    @Test func aVariableKindPropertyTakesAnyString() throws {
        let property = PropertyDefinition(id: "name", displayName: "Name", kind: .variable, defaultValue: "")
        #expect(property.isValid(.string("anything")))
        #expect(!property.isValid(.int(1)))
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

@Suite struct UndeclaredVariableDiagnosticTests {
    private func validate(_ editor: GraphEditor, in scope: SubgraphID? = nil) throws -> [GraphDiagnostic] {
        GraphValidator().validate(try #require(editor.validationContext(in: scope)))
    }

    @Test func aNodeNamingAVariableNobodyDeclaredIsAnErrorAndABlankOneAWarning() throws {
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        try editor.apply(.addVariable(variable: gain))
        let good = Node(typeID: "read", properties: ["name": "gain"])
        let bad = Node(typeID: "read", properties: ["name": "gian"])
        let blank = Node(typeID: "read", properties: ["name": ""])
        for node in [good, bad, blank] { try editor.apply(.addNode(node: node)) }

        let found = try validate(editor).filter { $0.code == .undeclaredVariable }
        #expect(found.map(\.node) == [bad.id, blank.id])
        #expect(found[0].severity == .error)
        #expect(found[0].message == "The graph has no variable named \"gian\".")
        #expect(found[1].severity == .warning)
    }

    @Test func theDefaultValueIsCheckedToo() throws {
        // The test node's default name is "x"; nothing declares it.
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        let node = Node(typeID: "read")
        try editor.apply(.addNode(node: node))
        #expect(try validate(editor).contains { $0.code == .undeclaredVariable && $0.node == node.id })
    }

    @Test func declaringTheVariableOrRenamingItClearsTheProblem() throws {
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        try editor.apply(.addNode(node: Node(typeID: "read", properties: ["name": "gain"])))
        #expect(try validate(editor).contains { $0.code == .undeclaredVariable })
        try editor.apply(.addVariable(variable: gain))
        #expect(try validate(editor).filter { $0.code == .undeclaredVariable }.isEmpty)
        try editor.apply(try editor.renameVariableCommand(from: "gain", to: "volume"))
        #expect(try validate(editor).filter { $0.code == .undeclaredVariable }.isEmpty, "a rename keeps readers valid")
    }

    @Test func insideASubgraphTheRootsVariablesCount() throws {
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        try editor.apply(.addVariable(variable: gain))
        let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Inner"), graph: Graph())
        try editor.apply(.addSubgraph(definition: definition))
        try editor.apply(.inSubgraph(id: definition.id, command: .addNode(node: Node(typeID: "read", properties: ["name": "gain"]))))
        #expect(try validate(editor, in: definition.id).filter { $0.code == .undeclaredVariable }.isEmpty)
    }

    @Test func aContextWithoutVariableNamesSkipsTheCheck() throws {
        let editor = GraphEditor(nodes: registry(), types: TypeRegistry())
        try editor.apply(.addNode(node: Node(typeID: "read", properties: ["name": "nope"])))
        let context = ValidationContext(graph: editor.graph, nodes: editor.nodes, types: editor.types)
        #expect(GraphValidator().validate(context).isEmpty)
    }
}
