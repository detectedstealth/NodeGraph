import Foundation
import Testing
@testable import NodeGraphCore

// MARK: Fixture

private let sumGroup = DynamicPortGroup(
    id: "in", displayName: "Input", type: number, defaultValue: nil,
    minimum: 1, maximum: 5, initialCount: 2, resizing: .keepOneFree)

private let sumDefinition = NodeDefinition(
    typeID: "sum", displayName: "Sum",
    ports: [
        PortDefinition(id: "bias", direction: .input, type: number, defaultValue: 0.0),
        PortDefinition(id: "out", direction: .output, type: number),
    ],
    dynamicPorts: [sumGroup],
    isPure: true)

/// Outputs a copy of its input on each of a manually sized group of output ports.
private let splitDefinition = NodeDefinition(
    typeID: "split", displayName: "Split",
    ports: [PortDefinition(id: "in", direction: .input, type: number, defaultValue: 0.0)],
    dynamicPorts: [DynamicPortGroup(
        id: "copy", displayName: "Copy", direction: .output, type: number,
        minimum: 1, maximum: 4, initialCount: 2, resizing: .manual)])

private func world() -> (GraphEditor, GraphHistory) {
    var (nodes, types) = runnable()
    nodes.register(sumDefinition) { ctx in
        let total = ctx.values(inGroup: "in").compactMap(\.numberValue).reduce(try ctx.number("bias"), +)
        return ["out": .double(total)]
    }
    nodes.register(splitDefinition) { ctx in
        var outputs = NodeOutputs.empty
        for port in ctx.definition.outputs where port.group == "copy" { outputs[port.id] = try ctx.input("in") }
        return outputs
    }
    let editor = GraphEditor(nodes: nodes, types: types)
    return (editor, GraphHistory(editor: editor))
}

private func add(_ history: GraphHistory, _ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:]) throws -> NodeID {
    let node = Node(typeID: type, properties: properties)
    try history.perform(.addNode(node: node))
    return node.id
}

private func connect(_ history: GraphHistory, _ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
    try history.connect(ConnectionProposal(
        source: PortAddress(node: a, port: out, direction: .output),
        target: PortAddress(node: b, port: input, direction: .input)))
}

private func portIDs(_ editor: GraphEditor, _ node: NodeID, _ direction: PortDirection = .input) -> [String] {
    let definition = editor.nodes.definition(for: editor.graph.nodes[node]!)!
    return (direction == .input ? definition.inputs : definition.outputs).map(\.id.rawValue)
}

// MARK: Definitions

@Test func aDefinitionResolvesToItsFixedPortsFollowedByTheGroupsPorts() {
    let two = sumDefinition.resolved(for: Node(typeID: "sum"))
    #expect(two.inputs.map(\.id.rawValue) == ["bias", "in_1", "in_2"])
    #expect(two.outputs.map(\.id.rawValue) == ["out"])
    let port = try! #require(two.port("in_2", direction: .input))
    #expect(port.displayName == "Input 2" && port.group == "in" && port.type == number)
    #expect(port.allowsMultipleLinks == false && port.defaultValue == nil)
    #expect(two.port("bias", direction: .input)?.group == nil)

    let four = sumDefinition.resolved(for: Node(typeID: "sum", portCounts: ["in": 4]))
    #expect(four.inputs.count == 5)
    // Resolving a resolved definition changes nothing, and counts outside the limits are held in.
    #expect(four.resolved(for: Node(typeID: "sum", portCounts: ["in": 4])) == four)
    #expect(sumDefinition.resolved(for: Node(typeID: "sum", portCounts: ["in": 99])).inputs.count == 1 + 5)
    #expect(sumDefinition.resolved(for: Node(typeID: "sum", portCounts: ["in": -3])).inputs.count == 1 + 1)
    #expect(sumDefinition.resolved(for: Node(typeID: "sum", portCounts: ["nope": 3])).inputs.count == 1 + 2)

    let plain = NodeDefinition(typeID: "p", displayName: "P", ports: [PortDefinition(id: "a", direction: .input)])
    #expect(plain.resolved(for: Node(typeID: "p", portCounts: ["x": 1])) == plain)
}

@Test func theRegistryHandsOutTheInstancesDefinition() {
    var registry = NodeRegistry()
    registry.register(sumDefinition)
    #expect(registry.definition(for: Node(typeID: "sum", portCounts: ["in": 3]))?.inputs.count == 4)
    #expect(registry.definition(for: "sum")?.inputs.count == 1, "by type alone you get the fixed ports")
    #expect(registry.definition(for: Node(typeID: "other")) == nil)
}

@Test func outputGroupsAndTriggerGroupsGenerateTheRightPorts() {
    let split = splitDefinition.resolved(for: Node(typeID: "split", portCounts: ["copy": 3]))
    #expect(split.outputs.map(\.id.rawValue) == ["copy_1", "copy_2", "copy_3"])
    #expect(split.outputs.allSatisfy { $0.allowsMultipleLinks })
    let trigger = DynamicPortGroup(id: "go", kind: .trigger, defaultValue: 1.0, minimum: 1)
    #expect(trigger.port(1).defaultValue == nil, "a trigger port never has a data default")
}

@Test func malformedGroupsAreReported() {
    func problems(_ groups: [DynamicPortGroup], ports: [PortDefinition] = []) -> [String] {
        NodeDefinition(typeID: "t", displayName: "T", ports: ports, dynamicPorts: groups).problems
    }
    #expect(problems([sumGroup]).isEmpty)
    #expect(problems([sumGroup, sumGroup]).contains("Duplicate port group \"in\""))
    #expect(problems([DynamicPortGroup(id: "has space")]).contains { $0.contains("no spaces") })
    #expect(problems([DynamicPortGroup(id: "x", minimum: -1)]).contains { $0.contains("negative minimum") })
    #expect(problems([DynamicPortGroup(id: "x", minimum: 3, maximum: 2)]).contains { $0.contains("maximum below") })
    #expect(problems([DynamicPortGroup(id: "x", minimum: 1, maximum: 3, initialCount: 7)]).contains { $0.contains("outside its limits") })
    #expect(problems([sumGroup], ports: [PortDefinition(id: "in_1", direction: .input)]).contains { $0.contains("collides") })
    #expect(problems([sumGroup], ports: [PortDefinition(id: "in_1", direction: .output)]).isEmpty, "other direction: no clash")
}

// MARK: Node data

@Test func portCountsAreOmittedWhenEmptyAndRoundTrip() throws {
    let plain = Node(typeID: "sum")
    #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("portCounts"))
    let sized = Node(typeID: "sum", portCounts: ["in": 4])
    let data = try JSONEncoder().encode(sized)
    #expect(String(decoding: data, as: UTF8.self).contains("portCounts"))
    #expect(try JSONDecoder().decode(Node.self, from: data) == sized)
    #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(plain)).portCounts.isEmpty)
}

// MARK: setPortCount

@Test func growingAndShrinkingChangesThePortsAndKeepsLinksToSurvivingPorts() throws {
    let (editor, history) = world()
    let source = try add(history, "const", ["value": 1.0]), sum = try add(history, "sum")
    try connect(history, source, "out", sum, "in_1")
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2"])

    try history.perform(.setPortCount(node: sum, group: "in", count: 4))
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2", "in_3", "in_4"])
    try connect(history, source, "out", sum, "in_4")
    #expect(editor.graph.links.count == 2)

    let before = editor.graph
    try history.perform(.setPortCount(node: sum, group: "in", count: 3), name: "Shrink")
    #expect(editor.graph.links.count == 1, "the link to in_4 went with the port")
    #expect(editor.graph.links(into: PortAddress(node: sum, port: "in_1", direction: .input)).count == 1)
    try history.undo()
    #expect(editor.graph == before, "undo restores the count and the link")
}

@Test func theCountThatEqualsTheInitialOneIsNotStored() throws {
    let (editor, history) = world()
    let sum = try add(history, "sum")
    try history.perform(.setPortCount(node: sum, group: "in", count: 4))
    #expect(editor.graph.nodes[sum]?.portCounts == ["in": 4])
    try history.perform(.setPortCount(node: sum, group: "in", count: 2))
    #expect(editor.graph.nodes[sum]?.portCounts.isEmpty == true, "two is the initial count")
}

@Test func badPortCountEditsAreRefused() throws {
    let (editor, history) = world()
    let sum = try add(history, "sum"), plain = try add(history, "add")
    #expect(throws: GraphEditError.portCountOutOfRange(group: "in", count: 6)) {
        try editor.apply(.setPortCount(node: sum, group: "in", count: 6))
    }
    #expect(throws: GraphEditError.portCountOutOfRange(group: "in", count: 0)) {
        try editor.apply(.setPortCount(node: sum, group: "in", count: 0))
    }
    #expect(throws: GraphEditError.unknownPortGroup("nope")) { try editor.apply(.setPortCount(node: sum, group: "nope", count: 2)) }
    #expect(throws: GraphEditError.unknownPortGroup("in")) { try editor.apply(.setPortCount(node: plain, group: "in", count: 2)) }
    let missing = NodeID()
    #expect(throws: GraphEditError.nodeNotFound(missing)) { try editor.apply(.setPortCount(node: missing, group: "in", count: 2)) }
}

@Test func portCountEditsCoalesceAndWorkInsideSubgraphs() throws {
    let id = NodeID()
    #expect(GraphCommand.setPortCount(node: id, group: "in", count: 3)
        .coalesced(with: .setPortCount(node: id, group: "in", count: 4)) == .setPortCount(node: id, group: "in", count: 4))
    #expect(GraphCommand.setPortCount(node: id, group: "in", count: 3)
        .coalesced(with: .setPortCount(node: id, group: "other", count: 4)) == nil)

    let (editor, history) = world()
    let inner = Node(typeID: "sum")
    var graph = Graph()
    graph.insert(inner)
    let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Holder"), graph: graph)
    try history.perform(.addSubgraph(definition: definition))
    try history.perform(.inSubgraph(id: definition.id, command: .setPortCount(node: inner.id, group: "in", count: 3)))
    #expect(editor.subgraphs[definition.id]?.graph.nodes[inner.id]?.portCounts == ["in": 3])
    try history.undo()
    #expect(editor.subgraphs[definition.id] == definition)
    let data = try JSONEncoder().encode(GraphCommand.setPortCount(node: id, group: "in", count: 3))
    #expect(try JSONDecoder().decode(GraphCommand.self, from: data) == .setPortCount(node: id, group: "in", count: 3))
}

// MARK: Automatic resizing

@Test func connectingTheLastPortAddsAnotherAndUndoTakesItBack() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    #expect(portIDs(editor, sum).count == 3)                       // bias, in_1, in_2
    try connect(history, source, "out", sum, "in_1")
    #expect(portIDs(editor, sum).count == 3, "in_2 is still free")
    let before = editor.graph
    try connect(history, source, "out", sum, "in_2")
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2", "in_3"], "linking the last port added one")
    try history.undo()
    #expect(editor.graph == before, "one undo removes the link and the extra port")
    try history.redo()
    #expect(portIDs(editor, sum).count == 4)
}

@Test func theGroupStopsGrowingAtItsMaximum() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    for n in 1...5 { try connect(history, source, "out", sum, PortID("in_\(n)")) }
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2", "in_3", "in_4", "in_5"])
    #expect(editor.graph.links.count == 5)
}

@Test func unlinkingTrailingPortsShrinksTheGroupButNeverBelowALinkedPort() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    for n in 1...3 { try connect(history, source, "out", sum, PortID("in_\(n)")) }   // grows to 4 ports
    #expect(portIDs(editor, sum).count == 5)

    // Unlink the middle one: ports 1 and 3 are still linked, so nothing can shrink.
    let middle = try #require(editor.graph.links(into: PortAddress(node: sum, port: "in_2", direction: .input)).first)
    try history.perform(.removeLink(id: middle.id))
    #expect(portIDs(editor, sum).count == 5)

    // Unlink the last linked one: the highest linked port is now in_1, so it shrinks to in_1 and in_2.
    let last = try #require(editor.graph.links(into: PortAddress(node: sum, port: "in_3", direction: .input)).first)
    try history.perform(.removeLink(id: last.id))
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2"])
    try history.undo()
    #expect(portIDs(editor, sum).count == 5 && editor.graph.links.count == 2)
}

@Test func unlinkingEverythingShrinksBackToTheInitialCountAndNoFurther() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    try connect(history, source, "out", sum, "in_1")
    try connect(history, source, "out", sum, "in_2")
    let links = editor.graph.links.keys
    try history.group(name: "Clear") { for id in links { try history.perform(.removeLink(id: id)) } }
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2"], "back to the initial two, not down to the minimum of one")
}

@Test func removingANodeResizesItsNeighboursAndUndoRestoresThem() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), split = try add(history, "split"), sum = try add(history, "sum")
    try connect(history, source, "out", split, "in")
    try connect(history, split, "copy_1", sum, "in_1")
    try connect(history, split, "copy_2", sum, "in_2")
    #expect(portIDs(editor, sum).count == 4)
    let before = editor.graph
    try history.perform(.removeNode(id: split))
    #expect(portIDs(editor, sum) == ["bias", "in_1", "in_2"], "no links left, back to the initial count")
    try history.undo()
    #expect(editor.graph == before)
}

@Test func replayingACommandRecomputesTheSameAutomaticResizes() throws {
    let (a, historyA) = world()
    let (b, _) = world()
    let sourceA = Node(typeID: "const"), sumA = Node(typeID: "sum")
    for node in [sourceA, sumA] {
        try historyA.perform(.addNode(node: node))
        try b.apply(.addNode(node: node))
    }
    for n in 1...2 {
        let change = try a.connect(ConnectionProposal(
            source: PortAddress(node: sourceA.id, port: "out", direction: .output),
            target: PortAddress(node: sumA.id, port: PortID("in_\(n)"), direction: .input)))
        try b.apply(change.command, validation: .structural)      // a server replaying the log
    }
    #expect(a.graph == b.graph)
    #expect(a.graph.nodes[sumA.id]?.portCounts == ["in": 3])
}

@Test func automaticResizingWorksInsideASubgraph() throws {
    let (editor, history) = world()
    let source = Node(typeID: "const"), sum = Node(typeID: "sum")
    var graph = Graph()
    graph.insert(source); graph.insert(sum)
    let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Holder"), graph: graph)
    try history.perform(.addSubgraph(definition: definition))
    let link = Link(sourceNode: source.id, sourcePort: "out", targetNode: sum.id, targetPort: "in_2")
    try history.perform(.inSubgraph(id: definition.id, command: .addLink(link: link)))
    #expect(editor.subgraphs[definition.id]?.graph.nodes[sum.id]?.portCounts == ["in": 3])
    try history.undo()
    #expect(editor.subgraphs[definition.id] == definition)
}

@Test func manuallySizedGroupsNeverResizeOnTheirOwn() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), split = try add(history, "split"), sink = try add(history, "add")
    try connect(history, source, "out", split, "in")
    try connect(history, split, "copy_2", sink, "a")
    #expect(portIDs(editor, split, .output) == ["copy_1", "copy_2"])
}

// MARK: Validation

@Test func linksMustUsePortsThatExist() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    #expect(throws: GraphEditError.self) { try connect(history, source, "out", sum, "in_3") }
    try history.perform(.setPortCount(node: sum, group: "in", count: 3))
    try connect(history, source, "out", sum, "in_3")
    #expect(editor.graph.links.count == 1)
}

@Test func wholeGraphValidationFlagsBadPortCountsAndStrandedLinks() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    try connect(history, source, "out", sum, "in_1")
    var document = editor.makeDocument()
    var broken = try #require(document.graph.nodes[sum])
    broken.portCounts = ["in": 99, "ghost": 2]
    var graph = document.graph
    graph.insert(broken)
    graph.insert(Link(sourceNode: source, sourcePort: "out", targetNode: sum, targetPort: "in_5"))   // beyond the default count
    document.graph = graph
    let found = GraphValidator().validate(ValidationContext(graph: document.graph, nodes: editor.nodes, types: editor.types))
    let codes = found.map(\.code)
    #expect(codes.filter { $0 == .invalidPortCount }.count == 2)
    #expect(!codes.contains(.missingPort), "99 is clamped to 5, so in_5 exists for this node")
    #expect(GraphValidator().validate(editor.validationContext).isEmpty)
}

// MARK: Running

@Test func aVariadicNodeSeesOnlyTheValuesItWasGiven() async throws {
    let (editor, history) = world()
    let one = try add(history, "const", ["value": 1.0]), two = try add(history, "const", ["value": 2.0])
    let sum = try add(history, "sum")
    try connect(history, one, "out", sum, "in_1")
    try connect(history, two, "out", sum, "in_2")        // grows to three ports; in_3 stays unlinked
    let runner = try GraphRunner(graph: editor.graph, registry: editor.nodes)
    #expect(await runner.step().outputs(of: sum)?["out"] == 3.0)
    #expect(portIDs(editor, sum).count == 4)
}

@Test func outputGroupsDeliverToTheRightLinks() async throws {
    let (editor, history) = world()
    let source = try add(history, "const", ["value": 7.0]), split = try add(history, "split")
    let a = try add(history, "add"), b = try add(history, "add")
    try connect(history, source, "out", split, "in")
    try history.perform(.setPortCount(node: split, group: "copy", count: 3))
    try connect(history, split, "copy_1", a, "a")
    try connect(history, split, "copy_3", b, "b")
    let tick = await (try GraphRunner(graph: editor.graph, registry: editor.nodes)).step()
    #expect(tick.outputs(of: a)?["out"] == 7.0 && tick.outputs(of: b)?["out"] == 7.0)
    #expect(tick.outputs(of: split)?.values.count == 3)
}

@Test func theContextListsGroupValuesInPortOrder() {
    let node = Node(typeID: "sum", portCounts: ["in": 3])
    let definition = sumDefinition.resolved(for: node)
    let context = NodeContext(
        node: node, definition: definition, linkedInputs: ["in_3": 30.0, "in_1": 10.0, "bias": 1.0])
    #expect(context.values(inGroup: "in") == [10.0, 30.0], "in_2 was not provided")
    #expect(context.values(inGroup: "nothing").isEmpty)
}

// MARK: Around dynamic ports

@Test func subgraphBindingsCanTargetDynamicPortsThatExist() throws {
    let (_, history) = world()
    var inner = Graph()
    let sum = Node(typeID: "sum", portCounts: ["in": 3])
    inner.insert(sum)
    func definition(targeting port: PortID) -> SubgraphDefinition {
        SubgraphDefinition(
            interface: SubgraphInterface(
                name: "Holder", inputs: [SubgraphInput(id: "x", type: number, targets: [PortAddress(node: sum.id, port: port, direction: .input)])],
                outputs: [SubgraphOutput(id: "r", type: number, source: PortAddress(node: sum.id, port: "out", direction: .output))]),
            graph: inner)
    }
    let nodes = history.editor.nodes
    #expect(definition(targeting: "in_3").problems(nodes: nodes).isEmpty)
    #expect(definition(targeting: "in_4").problems(nodes: nodes).contains { $0.contains("no input port \"in_4\"") })
}

@Test func portCountsSurviveSavingAndUnknownTypesKeepTheirData() throws {
    let (editor, history) = world()
    let sum = try add(history, "sum")
    try history.perform(.setPortCount(node: sum, group: "in", count: 4))
    var graph = editor.graph
    graph.insert(Node(typeID: "ghost", portCounts: ["in": 3]))
    let document = try GraphDocument.decode(from: GraphDocument(graph: graph).encoded())
    #expect(document.graph == graph)
    #expect(document.graph.nodes[sum]?.portCounts == ["in": 4])
    #expect(document.missingNodeTypes(in: editor.nodes) == ["ghost"])
}

@Test func undoRestoresAManualCountExactlyEvenOnAnAutomaticGroup() throws {
    let (editor, history) = world()
    let source = try add(history, "const"), sum = try add(history, "sum")
    try history.perform(.setPortCount(node: sum, group: "in", count: 5))     // not what automatic sizing would pick
    let before = editor.graph
    try connect(history, source, "out", sum, "in_1")                         // resizes down to in_1 + in_2
    #expect(portIDs(editor, sum).count == 3)
    try history.undo()
    #expect(editor.graph == before && portIDs(editor, sum).count == 6, "undo must not re-run the automatic sizing")
    try history.redo()
    #expect(portIDs(editor, sum).count == 3, "redo does")
}
