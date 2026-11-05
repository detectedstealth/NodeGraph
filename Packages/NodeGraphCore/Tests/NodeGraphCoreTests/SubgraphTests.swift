import Foundation
import Testing
@testable import NodeGraphCore

// MARK: Fixture

private let number: PortType = "number"

private func registries() -> (NodeRegistry, TypeRegistry) {
    var types = TypeRegistry()
    types.register(PortTypeInfo(type: number, displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "add", displayName: "Add",
        ports: [
            PortDefinition(id: "a", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "b", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "out", direction: .output, type: number),
        ]))
    nodes.register(NodeDefinition(
        typeID: "const", displayName: "Const",
        ports: [PortDefinition(id: "out", direction: .output, type: number)],
        properties: [PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0)]))
    nodes.register(NodeDefinition(
        typeID: "trig", displayName: "Trig",
        ports: [PortDefinition(id: "fire", direction: .output, kind: .trigger)]))
    return (nodes, types)
}

/// A subgraph computing `x + offset`: inner `add.a` takes input `x`, inner `add.b` takes a
/// constant whose `value` is promoted as `offset`, and `add.out` is the output `result`.
private struct Adder {
    var definition: SubgraphDefinition
    let add: NodeID, constant: NodeID

    init() {
        let add = Node(typeID: "add"), constant = Node(typeID: "const", properties: ["value": 10.0])
        var inner = Graph()
        inner.insert(add); inner.insert(constant)
        inner.insert(Link(sourceNode: constant.id, sourcePort: "out", targetNode: add.id, targetPort: "b"))
        self.add = add.id
        self.constant = constant.id
        definition = SubgraphDefinition(
            interface: SubgraphInterface(
                name: "Adder",
                inputs: [SubgraphInput(
                    id: "x", displayName: "X", type: number, defaultValue: 0.0,
                    targets: [PortAddress(node: add.id, port: "a", direction: .input)])],
                outputs: [SubgraphOutput(
                    id: "result", type: number, source: PortAddress(node: add.id, port: "out", direction: .output))],
                properties: [PromotedProperty(
                    id: "offset", displayName: "Offset", kind: .double(), defaultValue: 10.0,
                    targets: [PropertyTarget(node: constant.id, property: "value")])]),
            graph: inner)
    }
}

private func makeEditor(with adder: Adder? = nil) throws -> (GraphEditor, Adder) {
    let (nodes, types) = registries()
    let editor = GraphEditor(nodes: nodes, types: types)
    let adder = adder ?? Adder()
    try editor.apply(.addSubgraph(definition: adder.definition))
    return (editor, adder)
}

private func connect(_ editor: GraphEditor, _ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: a, port: out, direction: .output),
        target: PortAddress(node: b, port: input, direction: .input)))
}

// MARK: Definition model

@Test func theInstanceNodeTypeCarriesTheSubgraphID() {
    let adder = Adder()
    let type = adder.definition.typeID
    #expect(type.rawValue == "subgraph.\(adder.definition.id)")
    #expect(type.subgraphID == adder.definition.id)
    #expect(NodeTypeID("math.add").subgraphID == nil)
    #expect(NodeTypeID("subgraph.not-a-uuid").subgraphID == nil)
}

@Test func theInstanceDefinitionComesFromTheInterface() throws {
    let definition = Adder().definition.nodeDefinition
    #expect(definition.displayName == "Adder" && definition.category == "Subgraph")
    #expect(definition.ports.map(\.id) == ["x", "result"])
    #expect(definition.port("x", direction: .input)?.defaultValue == 0.0)
    #expect(definition.port("x", direction: .input)?.allowsMultipleLinks == false)
    #expect(definition.port("result", direction: .output)?.type == number)
    #expect(definition.property("offset")?.defaultValue == 10.0)
    #expect(definition.problems.isEmpty)
}

@Test func triggerInputsGetNoDataDefault() {
    var adder = Adder()
    adder.definition.interface.inputs[0].kind = .trigger
    adder.definition.interface.inputs[0].defaultValue = 5.0
    #expect(adder.definition.nodeDefinition.port("x", direction: .input)?.defaultValue == nil)
}

@Test func aSoundDefinitionHasNoProblems() {
    #expect(Adder().definition.problems(nodes: registries().0).isEmpty)
}

@Test func problemsDescribeEveryKindOfInconsistency() {
    let (nodes, _) = registries()
    var adder = Adder()
    let missing = NodeID()
    func problems(_ change: (inout SubgraphInterface) -> Void) -> [String] {
        var copy = adder.definition
        change(&copy.interface)
        return copy.problems(nodes: nodes)
    }
    let aIn = PortAddress(node: adder.add, port: "a", direction: .input)
    let aOut = PortAddress(node: adder.add, port: "out", direction: .output)

    #expect(problems { $0.inputs[0].targets = [PortAddress(node: missing, port: "a", direction: .input)] }
        .contains { $0.contains("node that does not exist") })
    #expect(problems { $0.inputs[0].targets = [aOut] }.contains { $0.contains("must be an input port") })
    #expect(problems { $0.inputs[0].targets = [PortAddress(node: adder.add, port: "zzz", direction: .input)] }
        .contains { $0.contains("no input port \"zzz\"") })
    #expect(problems { $0.inputs[0].kind = .trigger }.contains { $0.contains("is a data port") })
    #expect(problems { $0.inputs[0].targets = [] }.contains { $0.contains("feeds nothing") })
    #expect(problems { $0.outputs[0].source = nil }.contains { $0.contains("has no source") })
    #expect(problems { $0.outputs[0].source = aIn }.contains { $0.contains("must be an output port") })
    #expect(problems { $0.properties[0].targets = [] }.contains { $0.contains("sets nothing") })
    #expect(problems { $0.properties[0].targets = [PropertyTarget(node: adder.constant, property: "nope")] }
        .contains { $0.contains("no property \"nope\"") })
    #expect(problems { $0.inputs.append($0.inputs[0]) }.contains("Duplicate input \"x\""))
    #expect(problems { $0.outputs.append($0.outputs[0]) }.contains("Duplicate output \"result\""))
    #expect(problems { $0.properties.append($0.properties[0]) }.contains("Duplicate property \"offset\""))
    // An input and an output may share an id.
    #expect(problems { $0.outputs[0].id = "x" }.isEmpty)
    adder.definition.graph = Graph()
    #expect(adder.definition.problems(nodes: nodes).count >= 3, "deleting inner nodes leaves bindings dangling")
}

@Test func dependenciesListNestedInstances() {
    let inner = Adder()
    var outer = Adder()
    outer.definition.graph.insert(Node(typeID: inner.definition.typeID))
    #expect(outer.definition.directDependencies == [inner.definition.id])
    #expect(inner.definition.directDependencies.isEmpty)
}

// MARK: Editing definitions

@Test func addingADefinitionMakesItsInstancesCreatableAndLinkable() throws {
    let (editor, adder) = try makeEditor()
    #expect(editor.nodes.definition(for: adder.definition.typeID)?.displayName == "Adder")
    let source = Node(typeID: "const"), instance = Node(typeID: adder.definition.typeID, properties: ["offset": 3.0])
    try editor.apply(.addNode(node: source)); try editor.apply(.addNode(node: instance))
    try connect(editor, source.id, "out", instance.id, "x")
    #expect(editor.graph.links.count == 1)
    #expect(throws: GraphEditError.invalidProperty("offset", .typeMismatch(expected: "double"))) {
        try editor.apply(.addNode(node: Node(typeID: adder.definition.typeID, properties: ["offset": "ten"])))
    }
}

@Test func anInconsistentDefinitionIsRejectedAndLeavesNoTrace() throws {
    let (nodes, types) = registries()
    let editor = GraphEditor(nodes: nodes, types: types)
    var bad = Adder().definition
    bad.interface.inputs[0].targets = [PortAddress(node: NodeID(), port: "a", direction: .input)]
    do {
        try editor.apply(.addSubgraph(definition: bad))
        Issue.record("expected the definition to be rejected")
    } catch GraphEditError.invalidSubgraph(let problems) {
        #expect(problems.contains { $0.contains("does not exist") })
    }
    #expect(editor.subgraphs.isEmpty && editor.nodes.definition(for: bad.typeID) == nil && editor.revision == 0)

    // A broken inner graph is caught too: here a self-link inside the subgraph.
    var broken = Adder()
    broken.definition.graph.insert(Link(sourceNode: broken.add, sourcePort: "out", targetNode: broken.add, targetPort: "a"))
    #expect(throws: GraphEditError.self) { try editor.apply(.addSubgraph(definition: broken.definition)) }
}

@Test func addingTwiceOrAtABadIndexIsRejected() throws {
    let (editor, adder) = try makeEditor()
    #expect(throws: GraphEditError.duplicateID(adder.definition.id.description)) {
        try editor.apply(.addSubgraph(definition: adder.definition))
    }
    #expect(throws: GraphEditError.indexOutOfRange(5)) {
        try editor.apply(.addSubgraph(definition: Adder().definition, index: 5))
    }
}

@Test func undoAndRedoOfAddingRegisterAndUnregisterTheType() throws {
    let (nodes, types) = registries()
    let history = GraphHistory(editor: GraphEditor(nodes: nodes, types: types))
    let adder = Adder()
    try history.perform(.addSubgraph(definition: adder.definition))
    #expect(history.editor.nodes.definition(for: adder.definition.typeID) != nil)
    try history.undo()
    #expect(history.editor.subgraphs.isEmpty && history.editor.nodes.definition(for: adder.definition.typeID) == nil)
    try history.redo()
    #expect(history.editor.subgraphs.count == 1 && history.editor.nodes.definition(for: adder.definition.typeID) != nil)
}

@Test func aDefinitionInUseCannotBeRemovedUntilItsInstancesAre() throws {
    let (editor, adder) = try makeEditor()
    let instance = Node(typeID: adder.definition.typeID)
    try editor.apply(.addNode(node: instance))
    #expect(throws: GraphEditError.subgraphInUse(adder.definition.id)) {
        try editor.apply(.removeSubgraph(id: adder.definition.id))
    }
    try editor.apply(.removeNode(id: instance.id))
    let removal = try editor.apply(.removeSubgraph(id: adder.definition.id))
    #expect(editor.subgraphs.isEmpty && editor.nodes.definition(for: adder.definition.typeID) == nil)
    try editor.revert(removal)
    #expect(editor.subgraphs[adder.definition.id] == adder.definition)
    let unknown = SubgraphID()
    #expect(throws: GraphEditError.subgraphNotFound(unknown)) { try editor.apply(.removeSubgraph(id: unknown)) }
}

@Test func anInstanceInsideAnotherDefinitionCountsAsInUse() throws {
    let (editor, inner) = try makeEditor()
    var outer = Adder()
    outer.definition.graph.insert(Node(typeID: inner.definition.typeID))
    try editor.apply(.addSubgraph(definition: outer.definition))
    #expect(throws: GraphEditError.subgraphInUse(inner.definition.id)) {
        try editor.apply(.removeSubgraph(id: inner.definition.id))
    }
}

// MARK: Interface changes keep links consistent

private func wiredEditor() throws -> (GraphEditor, Adder, instance: NodeID, source: NodeID, sink: NodeID) {
    let (editor, adder) = try makeEditor()
    let source = Node(typeID: "const"), instance = Node(typeID: adder.definition.typeID, properties: ["offset": 3.0])
    let sink = Node(typeID: "add")
    for node in [source, instance, sink] { try editor.apply(.addNode(node: node)) }
    try connect(editor, source.id, "out", instance.id, "x")
    try connect(editor, instance.id, "result", sink.id, "a")
    return (editor, adder, instance.id, source.id, sink.id)
}

@Test func renamingAPortsLabelKeepsEveryLink() throws {
    let (editor, adder, _, _, _) = try wiredEditor()
    var interface = adder.definition.interface
    interface.name = "Plus"
    interface.inputs[0].displayName = "Input"
    let links = editor.graph.links
    try editor.apply(.setSubgraphInterface(id: adder.definition.id, interface: interface))
    #expect(editor.graph.links == links)
    #expect(editor.nodes.definition(for: adder.definition.typeID)?.displayName == "Plus")
    #expect(editor.nodes.definition(for: adder.definition.typeID)?.port("x", direction: .input)?.displayName == "Input")
}

@Test func removingAPortRemovesOnlyItsLinksAndUndoRestoresThemInOrder() throws {
    let (editor, adder, instance, source, sink) = try wiredEditor()
    let before = editor.graph
    var interface = adder.definition.interface
    interface.outputs = []                      // "result" goes away
    let change = try editor.apply(.setSubgraphInterface(id: adder.definition.id, interface: interface))
    #expect(editor.graph.links.count == 1)
    #expect(editor.graph.links.values.first?.source.node == source)
    #expect(editor.graph.nodes[instance] != nil && editor.graph.nodes[sink] != nil)
    #expect(editor.nodes.definition(for: adder.definition.typeID)?.outputs.isEmpty == true)
    try editor.revert(change)
    #expect(editor.graph == before)
    #expect(editor.subgraphs[adder.definition.id]?.interface == adder.definition.interface)
    #expect(editor.nodes.definition(for: adder.definition.typeID)?.outputs.map(\.id) == ["result"])
}

@Test func changingAPortsKindRemovesItsLinksButNotTheOthers() throws {
    let (editor, adder, instance, source, _) = try wiredEditor()
    // Give the subgraph a trigger to expose in place of the data output.
    let trigger = Node(typeID: "trig")
    try editor.apply(.inSubgraph(id: adder.definition.id, command: .addNode(node: trigger)))
    var interface = adder.definition.interface
    interface.outputs[0].kind = .trigger
    interface.outputs[0].type = .any
    interface.outputs[0].source = PortAddress(node: trigger.id, port: "fire", direction: .output)
    let before = editor.graph
    let change = try editor.apply(.setSubgraphInterface(id: adder.definition.id, interface: interface))
    #expect(editor.graph.links.count == 1, "the data link into the old output port is gone")
    #expect(editor.graph.links.values.first?.source.node == source && editor.graph.links.values.first?.target.node == instance)
    try editor.revert(change)
    #expect(editor.graph == before)
}

@Test func aBadInnerBindingInTheNewInterfaceIsRefusedAndLeavesLinksAlone() throws {
    let (editor, adder, _, _, _) = try wiredEditor()
    var interface = adder.definition.interface
    interface.outputs[0].kind = .trigger          // but the bound inner port is a data port
    #expect(throws: GraphEditError.self) { try editor.apply(.setSubgraphInterface(id: adder.definition.id, interface: interface)) }
    #expect(editor.graph.links.count == 2)
}

@Test func removingAPromotedPropertyClearsTheInstancesValue() throws {
    let (editor, adder, instance, _, _) = try wiredEditor()
    var interface = adder.definition.interface
    interface.properties = []
    let change = try editor.apply(.setSubgraphInterface(id: adder.definition.id, interface: interface))
    #expect(editor.graph.nodes[instance]?.properties.isEmpty == true)
    try editor.revert(change)
    #expect(editor.graph.nodes[instance]?.properties["offset"] == 3.0)
}

@Test func interfaceChangesAlsoCleanInstancesInsideOtherDefinitions() throws {
    let (editor, inner) = try makeEditor()
    var outer = Adder()
    let nested = Node(typeID: inner.definition.typeID)
    outer.definition.graph.insert(nested)
    outer.definition.graph.insert(Link(
        sourceNode: nested.id, sourcePort: "result", targetNode: outer.add, targetPort: "a"))
    try editor.apply(.addSubgraph(definition: outer.definition))
    let before = editor.subgraphs[outer.definition.id]
    var interface = inner.definition.interface
    interface.outputs = []
    let change = try editor.apply(.setSubgraphInterface(id: inner.definition.id, interface: interface))
    #expect(editor.subgraphs[outer.definition.id]?.graph.links.isEmpty == false)   // only the const link remains
    #expect(editor.subgraphs[outer.definition.id]?.graph.links.count == 1)
    try editor.revert(change)
    #expect(editor.subgraphs[outer.definition.id] == before)
}

@Test func anInconsistentInterfaceChangeIsRefused() throws {
    let (editor, adder, _, _, _) = try wiredEditor()
    var interface = adder.definition.interface
    interface.inputs[0].targets = []
    #expect(throws: GraphEditError.self) { try editor.apply(.setSubgraphInterface(id: adder.definition.id, interface: interface)) }
    let unknown = SubgraphID()
    #expect(throws: GraphEditError.subgraphNotFound(unknown)) {
        try editor.apply(.setSubgraphInterface(id: unknown, interface: interface))
    }
}

// MARK: Editing inside a subgraph

@Test func innerGraphsAreEditedWithTheSameCommandsAndRules() throws {
    let (editor, adder) = try makeEditor()
    let id = adder.definition.id
    let extra = Node(typeID: "add", position: GraphPoint(x: 5, y: 5))
    let added = try editor.apply(.inSubgraph(id: id, command: .addNode(node: extra)))
    #expect(editor.subgraphs[id]?.graph.nodes[extra.id] != nil)
    #expect(editor.graph.nodes.isEmpty, "the root graph is untouched")

    // The connection rules run against the inner graph.
    let selfLink = Link(sourceNode: extra.id, sourcePort: "out", targetNode: extra.id, targetPort: "a")
    #expect(throws: GraphEditError.self) { try editor.apply(.inSubgraph(id: id, command: .addLink(link: selfLink))) }
    let ok = Link(sourceNode: adder.add, sourcePort: "out", targetNode: extra.id, targetPort: "a")
    let linked = try editor.apply(.inSubgraph(id: id, command: .addLink(link: ok)))
    try editor.revert(linked)
    try editor.revert(added)
    #expect(editor.subgraphs[id] == adder.definition)
}

@Test func subgraphCommandsAreNotAllowedInsideASubgraph() throws {
    let (editor, adder) = try makeEditor()
    let id = adder.definition.id
    let nested: [GraphCommand] = [
        .inSubgraph(id: id, command: .removeSubgraph(id: id)),
        .inSubgraph(id: id, command: .inSubgraph(id: id, command: .batch(commands: []))),
        .inSubgraph(id: id, command: .addSubgraph(definition: Adder().definition)),
        .inSubgraph(id: id, command: .setSubgraphInterface(id: id, interface: adder.definition.interface)),
    ]
    for command in nested {
        #expect(throws: GraphEditError.invalidScope) { try editor.apply(command) }
    }
    let unknown = SubgraphID()
    #expect(throws: GraphEditError.subgraphNotFound(unknown)) {
        try editor.apply(.inSubgraph(id: unknown, command: .batch(commands: [])))
    }
}

@Test func aFailedBatchThatTouchesSubgraphsRollsBackCompletely() throws {
    let (editor, adder) = try makeEditor()
    let before = editor.subgraphs, graph = editor.graph
    let second = Adder()
    #expect(throws: GraphEditError.self) {
        try editor.apply(.batch(commands: [
            .addSubgraph(definition: second.definition),
            .inSubgraph(id: adder.definition.id, command: .removeNode(id: adder.add)),
            .removeNode(id: NodeID()),
        ]))
    }
    #expect(editor.subgraphs == before && editor.graph == graph)
    #expect(editor.nodes.definition(for: second.definition.typeID) == nil, "the rolled-back type is gone")
}

@Test func innerDragsCoalesceIntoOneUndoStep() throws {
    let (nodes, types) = registries()
    let history = GraphHistory(editor: GraphEditor(nodes: nodes, types: types))
    let adder = Adder()
    try history.perform(.addSubgraph(definition: adder.definition))
    for x in 1...5 {
        try history.perform(
            .inSubgraph(id: adder.definition.id, command: .setNodePositions(placements: [
                NodePlacement(node: adder.add, position: GraphPoint(x: Double(x), y: 0))])),
            coalescing: true)
    }
    #expect(history.undoStack.count == 2)
    try history.undo()
    #expect(history.editor.subgraphs[adder.definition.id] == adder.definition)
    #expect(GraphCommand.inSubgraph(id: adder.definition.id, command: .batch(commands: []))
        .coalesced(with: .inSubgraph(id: SubgraphID(), command: .batch(commands: []))) == nil)
}

// MARK: Documents

@Test func subgraphsSurviveSavingAndLoading() throws {
    let (editor, adder, instance, _, _) = try wiredEditor()
    let document = editor.makeDocument(metadata: ["title": "T"])
    #expect(document.subgraphs == [adder.definition])
    let loaded = try GraphDocument.decode(from: document.encoded())
    #expect(loaded == document)

    let (nodes, types) = registries()
    let reopened = GraphEditor(document: loaded, nodes: nodes, types: types)
    #expect(reopened.graph == editor.graph && reopened.subgraphs == editor.subgraphs)
    #expect(reopened.nodes.definition(for: adder.definition.typeID) != nil, "types are registered on open")
    _ = instance
    let context = reopened.validationContext
    #expect(GraphValidator().validate(context).isEmpty)
}

@Test func documentsWithoutSubgraphsKeepTheirOriginalBytes() throws {
    let text = String(decoding: try GraphDocument(graph: Graph()).encoded(prettyPrinted: false), as: UTF8.self)
    #expect(!text.contains("subgraphs"))
    let loaded = try GraphDocument.decode(from: Data(text.utf8))
    #expect(loaded.subgraphs.isEmpty)
}

@Test func duplicateSubgraphIDsFailToLoad() throws {
    let adder = Adder()
    let one = try JSONEncoder().encode(adder.definition)
    let json = #"{"schemaVersion":1,"graph":{"nodes":[],"links":[]},"metadata":{},"subgraphs":[\#(String(decoding: one, as: UTF8.self)),\#(String(decoding: one, as: UTF8.self))]}"#
    #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data(json.utf8)) }
}

@Test func definedSubgraphTypesAreNotReportedMissing() throws {
    let (editor, adder, _, _, _) = try wiredEditor()
    let document = editor.makeDocument()
    // Against a registry that knows nothing of the subgraph, only real unknowns are reported.
    var mine = Graph()
    mine.insert(Node(typeID: "ghost"))
    var withGhost = document
    withGhost.graph = mine
    withGhost.subgraphs[0].graph.insert(Node(typeID: "inner.ghost"))
    #expect(withGhost.missingNodeTypes(in: registries().0) == ["ghost", "inner.ghost"])
    _ = adder
}
