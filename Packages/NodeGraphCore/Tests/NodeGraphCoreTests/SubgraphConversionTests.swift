import Foundation
import Testing
@testable import NodeGraphCore

// MARK: Fixture

/// An editor over runnable nodes, so conversions can be checked by running the graph.
private struct Bench {
    let editor: GraphEditor
    let history: GraphHistory

    init(extra: (inout NodeRegistry) -> Void = { _ in }) {
        var (nodes, types) = runnable()
        // An input that takes any number of links.
        nodes.register(NodeDefinition(
            typeID: "sum", displayName: "Sum",
            ports: [
                PortDefinition(id: "in", direction: .input, type: number, allowsMultipleLinks: true),
                PortDefinition(id: "out", direction: .output, type: number),
            ])
        ) { ctx in
            guard case .array(let values)? = ctx.inputs["in"] else { return ["out": 0.0] }
            return ["out": .double(values.compactMap(\.numberValue).reduce(0, +))]
        }
        extra(&nodes)
        editor = GraphEditor(nodes: nodes, types: types)
        history = GraphHistory(editor: editor)
    }

    @discardableResult
    func add(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:], at x: Double = 0, _ y: Double = 0) throws -> NodeID {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y), properties: properties)
        try history.perform(.addNode(node: node))
        return node.id
    }

    func link(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
        try history.connect(ConnectionProposal(
            source: PortAddress(node: a, port: out, direction: .output),
            target: PortAddress(node: b, port: input, direction: .input)))
    }

    func run() async throws -> TickResult {
        await (try GraphRunner(
            graph: editor.graph, registry: editor.nodes, subgraphs: Array(editor.subgraphs.values))).step()
    }
}

/// `source(5) -> b -> c -> sink`, where `b` and `c` are `add` nodes.
private struct Chain {
    let bench = Bench()
    let source: NodeID, b: NodeID, c: NodeID, sink: NodeID

    init() throws {
        source = try bench.add("const", ["value": 5.0], at: 0, 0)
        b = try bench.add("add", at: 200, 0)
        c = try bench.add("add", at: 400, 100)
        sink = try bench.add("add", at: 600, 0)
        try bench.link(source, "out", b, "a")
        try bench.link(b, "out", c, "a")
        try bench.link(c, "out", sink, "a")
    }
}

private func outputValue(_ tick: TickResult, _ node: NodeID, _ port: PortID = "out") -> GraphValue? {
    tick.outputs(of: node)?[port]
}

// MARK: Converting a selection

@Test func convertingTheMiddleOfAChainExposesTheLinksThatCrossTheEdge() async throws {
    let chain = try Chain()
    let bench = chain.bench
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [chain.b, chain.c], name: "Pair")
    try bench.history.perform(conversion.command, name: "Convert")

    let definition = try #require(bench.editor.subgraphs[conversion.subgraph])
    #expect(Set(definition.graph.nodes.keys) == [chain.b, chain.c])
    #expect(definition.graph.links.count == 1, "the link between b and c moved inside")
    #expect(definition.interface.inputs.map(\.id) == ["a"])
    #expect(definition.interface.inputs[0].targets == [PortAddress(node: chain.b, port: "a", direction: .input)])
    #expect(definition.interface.outputs.map(\.id) == ["out"])
    #expect(definition.interface.outputs[0].source == PortAddress(node: chain.c, port: "out", direction: .output))
    #expect(definition.problems(nodes: bench.editor.nodes).isEmpty)

    let graph = bench.editor.graph
    #expect(graph.nodes[chain.b] == nil && graph.nodes[chain.c] == nil)
    #expect(graph.nodes[conversion.instance]?.typeID == definition.typeID)
    #expect(graph.links.count == 2)
    #expect(graph.links(into: PortAddress(node: conversion.instance, port: "a", direction: .input)).first?.source.node == chain.source)
    #expect(graph.links(into: PortAddress(node: chain.sink, port: "a", direction: .input)).first?.source.node == conversion.instance)
    // The instance sits at the centre of what it replaced: x 200...(400 + 160), y 0...(100 + 80).
    let position = try #require(graph.nodes[conversion.instance]?.position)
    #expect(position == GraphPoint(x: 380 - 80, y: 90 - 40))
}

@Test func theConvertedGraphComputesTheSameResult() async throws {
    let chain = try Chain()
    let before = try await chain.bench.run()
    let conversion = try chain.bench.editor.convertToSubgraphCommand(nodes: [chain.b, chain.c], name: "Pair")
    try chain.bench.history.perform(conversion.command)
    let after = try await chain.bench.run()
    #expect(outputValue(before, chain.sink) == 5.0)
    #expect(outputValue(after, chain.sink) == outputValue(before, chain.sink))
    #expect(after.succeeded)
}

@Test func oneUndoRestoresTheOriginalGraphExactly() async throws {
    let chain = try Chain()
    let bench = chain.bench
    let before = bench.editor.graph
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [chain.b, chain.c], name: "Pair")
    try bench.history.perform(conversion.command)
    try bench.history.undo()
    #expect(bench.editor.graph == before)
    #expect(bench.editor.subgraphs.isEmpty)
    #expect(bench.editor.nodes.definition(for: NodeTypeID("subgraph.\(conversion.subgraph)")) == nil)
    try bench.history.redo()
    #expect(bench.editor.subgraphs[conversion.subgraph] != nil && bench.editor.graph.nodes[conversion.instance] != nil)
}

@Test func anOutputThatFeedsSeveralNodesBecomesOneOutputAndAnInputFeedsSeveralPorts() async throws {
    let bench = Bench()
    let source = try bench.add("const", ["value": 2.0])
    let b = try bench.add("add"), c = try bench.add("add")
    let sinkOne = try bench.add("add"), sinkTwo = try bench.add("add")
    try bench.link(source, "out", b, "a"); try bench.link(source, "out", c, "a")      // one outside output, two inner ports
    try bench.link(b, "out", sinkOne, "a"); try bench.link(b, "out", sinkTwo, "a")    // one inner output, two outside inputs
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [b, c], name: "Fan")
    try bench.history.perform(conversion.command)

    let interface = try #require(bench.editor.subgraphs[conversion.subgraph]?.interface)
    #expect(interface.inputs.count == 1 && Set(interface.inputs[0].targets.map(\.node)) == [b, c])
    #expect(interface.outputs.count == 1)
    #expect(bench.editor.graph.links.count == 3, "one link in, two out")
    let tick = try await bench.run()
    #expect(outputValue(tick, sinkOne) == 2.0 && outputValue(tick, sinkTwo) == 2.0)
}

@Test func separateOutsideSourcesBecomeSeparateInputsWithUniqueIDs() async throws {
    let bench = Bench()
    let one = try bench.add("const", ["value": 1.0]), two = try bench.add("const", ["value": 2.0])
    let b = try bench.add("add"), c = try bench.add("add")
    try bench.link(one, "out", b, "a"); try bench.link(two, "out", c, "a")        // both inputs are called "a"
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [b, c], name: "Two")
    try bench.history.perform(conversion.command)
    let interface = try #require(bench.editor.subgraphs[conversion.subgraph]?.interface)
    #expect(interface.inputs.map(\.id) == ["a", "a_2"])
    #expect(interface.inputs[0].targets.map(\.node) == [b] && interface.inputs[1].targets.map(\.node) == [c])
    #expect(interface.outputs.isEmpty)
}

@Test func unlinkedInnerPortsStayUnlinkedAndDefaultsCarryOver() async throws {
    let bench = Bench()
    let source = try bench.add("const", ["value": 3.0]), b = try bench.add("add")
    try bench.link(source, "out", b, "b")
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [b], name: "One")
    let input = try #require(conversion.command.firstSubgraph?.interface.inputs.first)
    #expect(input.id == "b" && input.defaultValue == 0.0 && input.type == number && input.kind == .data)
}

@Test func promotedPropertiesKeepTheirValuesAndBecomeEditableOnTheInstance() async throws {
    let bench = Bench()
    let constant = try bench.add("const", ["value": 7.0]), sink = try bench.add("add")
    try bench.link(constant, "out", sink, "a")
    let conversion = try bench.editor.convertToSubgraphCommand(
        nodes: [constant], name: "Seven", promoting: [PropertyTarget(node: constant, property: "value")])
    try bench.history.perform(conversion.command)

    let definition = try #require(bench.editor.subgraphs[conversion.subgraph])
    #expect(definition.interface.properties.map(\.id) == ["value"])
    #expect(definition.interface.properties[0].defaultValue == 7.0, "today's value is the default")
    #expect(try await bench.run().outputs(of: sink) == ["out": 7.0])

    try bench.history.perform(.setNodeProperty(node: conversion.instance, property: "value", value: 9.0))
    #expect(try await bench.run().outputs(of: sink) == ["out": 9.0])
}

@Test func badSelectionsAreRefused() async throws {
    let chain = try Chain()
    let editor = chain.bench.editor
    #expect(throws: GraphEditError.self) { try editor.convertToSubgraphCommand(nodes: [], name: "x") }
    let missing = NodeID()
    #expect(throws: GraphEditError.nodeNotFound(missing)) { try editor.convertToSubgraphCommand(nodes: [missing], name: "x") }
    #expect(throws: GraphEditError.nodeNotFound(chain.sink)) {
        try editor.convertToSubgraphCommand(nodes: [chain.b], name: "x", promoting: [PropertyTarget(node: chain.sink, property: "value")])
    }
    #expect(throws: GraphEditError.unknownProperty("nope")) {
        try editor.convertToSubgraphCommand(nodes: [chain.b], name: "x", promoting: [PropertyTarget(node: chain.b, property: "nope")])
    }
    #expect(editor.subgraphs.isEmpty, "building a command changes nothing")
}

@Test func aMultiLinkPortThatTakesLinksFromOutsideCannotBecomeOneInput() async throws {
    let bench = Bench()
    let one = try bench.add("const", ["value": 1.0]), two = try bench.add("const", ["value": 2.0])
    let total = try bench.add("sum")
    try bench.link(one, "out", total, "in"); try bench.link(two, "out", total, "in")
    #expect(throws: GraphEditError.self) { try bench.editor.convertToSubgraphCommand(nodes: [total], name: "x") }
    // With the sources inside the selection too, the links are internal and nothing is exposed.
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [one, two, total], name: "Whole")
    try bench.history.perform(conversion.command)
    #expect(bench.editor.subgraphs[conversion.subgraph]?.interface.inputs.isEmpty == true)
    #expect(try await bench.run().outputs(of: conversion.instance) == [:], "no outputs were exposed")
}

@Test func aSelectionWithNothingAroundItBecomesAnInterfaceFreeSubgraph() async throws {
    let bench = Bench()
    let a = try bench.add("const", ["value": 1.0]), b = try bench.add("add")
    try bench.link(a, "out", b, "a")
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [a, b], name: "All")
    try bench.history.perform(conversion.command)
    #expect(bench.editor.graph.nodes.count == 1 && bench.editor.graph.links.isEmpty)
    #expect(bench.editor.subgraphs[conversion.subgraph]?.graph.links.count == 1)
}

@Test func convertingInsideASubgraphReplacesNodesInThatInnerGraph() async throws {
    let bench = Bench()
    let wrapperNodes = (Node(typeID: "const", properties: ["value": 4.0]), Node(typeID: "add"), Node(typeID: "add"))
    var inner = Graph()
    inner.insert(wrapperNodes.0); inner.insert(wrapperNodes.1); inner.insert(wrapperNodes.2)
    inner.insert(Link(sourceNode: wrapperNodes.0.id, sourcePort: "out", targetNode: wrapperNodes.1.id, targetPort: "a"))
    inner.insert(Link(sourceNode: wrapperNodes.1.id, sourcePort: "out", targetNode: wrapperNodes.2.id, targetPort: "a"))
    let wrapper = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Wrapper",
            outputs: [SubgraphOutput(id: "out", type: number, source: PortAddress(node: wrapperNodes.2.id, port: "out", direction: .output))]),
        graph: inner)
    try bench.history.perform(.addSubgraph(definition: wrapper))
    let before = bench.editor.subgraphs[wrapper.id]

    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [wrapperNodes.1.id], name: "Inner", in: wrapper.id)
    try bench.history.perform(conversion.command)
    let changed = try #require(bench.editor.subgraphs[wrapper.id])
    #expect(changed.graph.nodes[wrapperNodes.1.id] == nil)
    #expect(changed.graph.nodes[conversion.instance]?.typeID == bench.editor.subgraphs[conversion.subgraph]?.typeID)
    #expect(changed.graph.links.count == 2)

    // The wrapper still computes the same thing.
    let instance = try bench.add(wrapper.typeID)
    #expect(try await bench.run().outputs(of: instance) == ["out": 4.0])
    try bench.history.perform(.removeNode(id: instance))
    try bench.history.undo(); try bench.history.undo()   // the removal, then the instance
    try bench.history.undo()                             // the conversion
    #expect(bench.editor.subgraphs[wrapper.id] == before && bench.editor.subgraphs[conversion.subgraph] == nil)
}

// MARK: Unpacking

private func wiredAdder() throws -> (Bench, Adder, instance: NodeID, source: NodeID, sinkA: NodeID, sinkB: NodeID) {
    let bench = Bench()
    let adder = Adder()
    try bench.history.perform(.addSubgraph(definition: adder.definition))
    let source = try bench.add("const", ["value": 5.0], at: 0, 0)
    let instance = try bench.add(adder.definition.typeID, ["offset": 3.0], at: 300, 200)
    let sinkA = try bench.add("add", at: 600, 0), sinkB = try bench.add("add", at: 600, 200)
    try bench.link(source, "out", instance, "x")
    try bench.link(instance, "result", sinkA, "a"); try bench.link(instance, "result", sinkB, "b")
    return (bench, adder, instance, source, sinkA, sinkB)
}

@Test func unpackingCopiesTheInnerGraphWiresItAndKeepsTheResult() async throws {
    let (bench, adder, instance, source, sinkA, sinkB) = try wiredAdder()
    let before = try await bench.run()
    let unpacking = try bench.editor.unpackCommand(instance: instance)
    try bench.history.perform(unpacking.command, name: "Unpack")

    let graph = bench.editor.graph
    #expect(graph.nodes[instance] == nil)
    #expect(graph.nodes.count == 5, "source, two sinks, and the two inner nodes")
    let newAdd = try #require(unpacking.nodes[adder.add]), newConstant = try #require(unpacking.nodes[adder.constant])
    #expect(newAdd != adder.add && newConstant != adder.constant, "the copies have new ids")
    // Wiring: source -> add.a, const -> add.b, add -> both sinks.
    #expect(graph.links(into: PortAddress(node: newAdd, port: "a", direction: .input)).first?.source.node == source)
    #expect(graph.links(into: PortAddress(node: newAdd, port: "b", direction: .input)).first?.source.node == newConstant)
    #expect(graph.links(into: PortAddress(node: sinkA, port: "a", direction: .input)).first?.source.node == newAdd)
    #expect(graph.links(into: PortAddress(node: sinkB, port: "b", direction: .input)).first?.source.node == newAdd)
    // The promoted property's value (3.0, set on the instance) was written into the copy.
    #expect(graph.nodes[newConstant]?.properties["value"] == 3.0)

    let after = try await bench.run()
    #expect(outputValue(before, sinkA) == 8.0 && outputValue(after, sinkA) == 8.0)
    #expect(outputValue(after, sinkB) == 8.0 && after.succeeded)
    #expect(bench.editor.subgraphs[adder.definition.id] != nil, "the definition stays")
}

@Test func unpackedNodesKeepTheirLayoutAnchoredWhereTheInstanceWas() async throws {
    let (bench, adder, instance, _, _, _) = try wiredAdder()
    var definition = adder.definition
    definition.graph.insert(Node(id: adder.add, typeID: "add", position: GraphPoint(x: 100, y: 50)))
    definition.graph.insert(Node(id: adder.constant, typeID: "const", position: GraphPoint(x: 20, y: 90), properties: ["value": 10.0]))
    try bench.history.perform(.removeNode(id: instance))
    try bench.history.perform(.removeSubgraph(id: definition.id))
    try bench.history.perform(.addSubgraph(definition: definition))
    let again = try bench.add(definition.typeID, at: 300, 200)
    let unpacking = try bench.editor.unpackCommand(instance: again)
    try bench.history.perform(unpacking.command)
    // The inner top-left corner (x 20, y 50) lands on the instance position (300, 200).
    #expect(bench.editor.graph.nodes[try #require(unpacking.nodes[adder.constant])]?.position == GraphPoint(x: 300, y: 240))
    #expect(bench.editor.graph.nodes[try #require(unpacking.nodes[adder.add])]?.position == GraphPoint(x: 380, y: 200))
}

@Test func unpackingTwiceGivesTwoIndependentCopies() async throws {
    let bench = Bench()
    let adder = Adder()
    try bench.history.perform(.addSubgraph(definition: adder.definition))
    let first = try bench.add(adder.definition.typeID, ["offset": 1.0]), second = try bench.add(adder.definition.typeID, ["offset": 2.0])
    let a = try bench.editor.unpackCommand(instance: first)
    try bench.history.perform(a.command)
    let b = try bench.editor.unpackCommand(instance: second)
    try bench.history.perform(b.command)
    #expect(Set(a.nodes.values).isDisjoint(with: Set(b.nodes.values)))
    #expect(bench.editor.graph.nodes.count == 4)
    let tick = try await bench.run()
    let sums = [a, b].compactMap { outputValue(tick, $0.nodes[adder.add]!) }
    #expect(sums == [1.0, 2.0])
}

@Test func unpackingIsOneUndoStepThatRestoresTheInstanceAndItsLinks() async throws {
    let (bench, _, instance, _, _, _) = try wiredAdder()
    let before = bench.editor.graph
    try bench.history.perform(try bench.editor.unpackCommand(instance: instance).command)
    try bench.history.undo()
    #expect(bench.editor.graph == before)
}

@Test func unpackingAnInstanceWithNothingLinkedJustAddsTheInnerNodes() async throws {
    let bench = Bench()
    let adder = Adder()
    try bench.history.perform(.addSubgraph(definition: adder.definition))
    let instance = try bench.add(adder.definition.typeID)
    try bench.history.perform(try bench.editor.unpackCommand(instance: instance).command)
    #expect(bench.editor.graph.nodes.count == 2 && bench.editor.graph.links.count == 1)
}

@Test func unpackRefusesWhatIsNotAnInstance() async throws {
    let chain = try Chain()
    let editor = chain.bench.editor
    #expect(throws: GraphEditError.self) { try editor.unpackCommand(instance: chain.b) }
    let missing = NodeID()
    #expect(throws: GraphEditError.nodeNotFound(missing)) { try editor.unpackCommand(instance: missing) }
}

@Test func unpackingInsideASubgraphEditsThatInnerGraph() async throws {
    let bench = Bench()
    let adder = Adder()
    try bench.history.perform(.addSubgraph(definition: adder.definition))
    let nested = Node(typeID: adder.definition.typeID)
    var wrapperGraph = Graph()
    wrapperGraph.insert(nested)
    let wrapper = SubgraphDefinition(interface: SubgraphInterface(name: "Wrapper"), graph: wrapperGraph)
    try bench.history.perform(.addSubgraph(definition: wrapper))
    let before = bench.editor.subgraphs[wrapper.id]
    let unpacking = try bench.editor.unpackCommand(instance: nested.id, in: wrapper.id)
    try bench.history.perform(unpacking.command)
    #expect(bench.editor.subgraphs[wrapper.id]?.graph.nodes.count == 2)
    #expect(bench.editor.subgraphs[wrapper.id]?.graph.nodes[nested.id] == nil)
    try bench.history.undo()
    #expect(bench.editor.subgraphs[wrapper.id] == before)
}

// MARK: Round trip

@Test func convertingThenUnpackingGivesBackAnEquivalentGraph() async throws {
    let chain = try Chain()
    let bench = chain.bench
    let before = try await bench.run()
    let conversion = try bench.editor.convertToSubgraphCommand(nodes: [chain.b, chain.c], name: "Pair")
    try bench.history.perform(conversion.command)
    let unpacking = try bench.editor.unpackCommand(instance: conversion.instance)
    try bench.history.perform(unpacking.command)

    let graph = bench.editor.graph
    #expect(graph.nodes.count == 4 && graph.links.count == 3)
    #expect(Set(graph.nodes.values.map(\.typeID)) == ["const", "add"])
    #expect(try await bench.run().outputs(of: chain.sink) == before.outputs(of: chain.sink))
    // Nodes returned to where they were (the copies are translated back onto the instance's
    // position, which was the selection's centre, so only the shape is preserved here).
    let moved = try #require(unpacking.nodes[chain.b].flatMap { graph.nodes[$0] })
    let other = try #require(unpacking.nodes[chain.c].flatMap { graph.nodes[$0] })
    #expect(other.position.x - moved.position.x == 200 && other.position.y - moved.position.y == 100)
}

// MARK: Helpers

extension GraphCommand {
    /// The first definition added by this command or by a batch it contains, for inspecting a
    /// conversion before applying it.
    fileprivate var firstSubgraph: SubgraphDefinition? {
        switch self {
        case .addSubgraph(let definition, _): definition
        case .batch(let commands): commands.lazy.compactMap(\.firstSubgraph).first
        default: nil
        }
    }
}

/// One outside node feeding several selected ports, as when a value drives two nodes that are
/// wrapped together.
@Suite struct SharedInputConversionTests {
    @Test func oneOutsideOutputFeedingTwoSelectedNodesBecomesOneInputForBoth() throws {
        let (nodes, types) = registries()
        let editor = GraphEditor(nodes: nodes, types: types)
        let a = Node(typeID: "const", title: "A"), b = Node(typeID: "const", title: "B")
        let x = Node(typeID: "add"), y = Node(typeID: "add")
        for node in [a, b, x, y] { try editor.apply(.addNode(node: node)) }
        func link(_ from: Node, _ to: Node, _ port: PortID) throws {
            try editor.connect(ConnectionProposal(
                source: PortAddress(node: from.id, port: "out", direction: .output),
                target: PortAddress(node: to.id, port: port, direction: .input)))
        }
        try link(a, x, "a"); try link(a, y, "a"); try link(b, y, "b")

        let conversion = try editor.convertToSubgraphCommand(nodes: [x.id, y.id], name: "Pair")
        try editor.apply(conversion.command)
        let definition = try #require(editor.subgraphs[conversion.subgraph])
        // Two inputs, not three: A feeds both nodes through one.
        #expect(definition.interface.inputs.count == 2)
        let fromA = try #require(definition.interface.inputs.first { $0.displayName == "A" })
        #expect(Set(fromA.targets.map(\.node)) == [x.id, y.id])
        #expect(definition.interface.inputs.contains { $0.displayName == "B" && $0.targets.map(\.node) == [y.id] })
        // Outside, A and B each link to the instance once.
        #expect(editor.graph.links.count == 2)
        #expect(editor.graph.links.values.allSatisfy { $0.target.node == conversion.instance })
    }

    @Test func anUntitledFeederFallsBackToTheInnerPortName() throws {
        let (nodes, types) = registries()
        let editor = GraphEditor(nodes: nodes, types: types)
        let feeder = Node(typeID: "const"), x = Node(typeID: "add")
        for node in [feeder, x] { try editor.apply(.addNode(node: node)) }
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: feeder.id, port: "out", direction: .output),
            target: PortAddress(node: x.id, port: "a", direction: .input)))
        let conversion = try editor.convertToSubgraphCommand(nodes: [x.id], name: "One")
        #expect(editor.subgraphs.isEmpty)
        try editor.apply(conversion.command)
        #expect(editor.subgraphs[conversion.subgraph]?.interface.inputs.first?.displayName == "a")
    }
}
