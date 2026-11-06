import Foundation
import Testing
@testable import NodeGraphCore

// MARK: Fixture

/// An empty subgraph named `name`, with an editor that knows it.
private func definition(_ name: String, containing inner: [SubgraphDefinition] = []) -> SubgraphDefinition {
    var graph = Graph()
    for other in inner { graph.insert(Node(typeID: other.typeID)) }
    return SubgraphDefinition(interface: SubgraphInterface(name: name), graph: graph)
}

private func makeEditor(_ definitions: [SubgraphDefinition]) throws -> GraphEditor {
    let (nodes, types) = runnable()
    let editor = GraphEditor(nodes: nodes, types: types)
    for definition in definitions { try editor.apply(.addSubgraph(definition: definition)) }
    return editor
}

private func recursiveLoop(_ body: () throws -> Void) -> [SubgraphID]? {
    do {
        try body()
        return nil
    } catch GraphEditError.recursiveSubgraph(let loop) {
        return loop
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

// MARK: The guard

@Test func aSubgraphCannotContainAnInstanceOfItself() throws {
    let a = definition("A")
    let editor = try makeEditor([a])
    let loop = recursiveLoop {
        try editor.apply(.inSubgraph(id: a.id, command: .addNode(node: Node(typeID: a.typeID))))
    }
    #expect(loop == [a.id, a.id])
    #expect(editor.subgraphs[a.id] == a, "nothing changed")
}

@Test func norThroughAnotherSubgraphThatContainsIt() throws {
    let b = definition("B")
    let a = definition("A", containing: [b])               // A contains B
    let editor = try makeEditor([b, a])
    // Putting A inside B would close the loop A -> B -> A.
    let loop = recursiveLoop {
        try editor.apply(.inSubgraph(id: b.id, command: .addNode(node: Node(typeID: a.typeID))))
    }
    #expect(loop == [b.id, a.id, b.id], "the loop runs around B, A, back to B")
    #expect(editor.subgraphs[b.id] == b)
}

@Test func longerChainsAreCaughtToo() throws {
    let d = definition("D")
    let c = definition("C", containing: [d]), b = definition("B", containing: [c]), a = definition("A", containing: [b])
    let editor = try makeEditor([d, c, b, a])
    let loop = recursiveLoop {
        try editor.apply(.inSubgraph(id: d.id, command: .addNode(node: Node(typeID: a.typeID))))
    }
    #expect(loop == [d.id, a.id, b.id, c.id, d.id])
}

@Test func nestingThatDoesNotLoopIsStillAllowed() throws {
    let b = definition("B"), c = definition("C")
    let a = definition("A", containing: [b])
    let editor = try makeEditor([b, c, a])
    // Another B in A, a C in A, and anything at the top level: none of these loop.
    try editor.apply(.inSubgraph(id: a.id, command: .addNode(node: Node(typeID: b.typeID))))
    try editor.apply(.inSubgraph(id: a.id, command: .addNode(node: Node(typeID: c.typeID))))
    try editor.apply(.addNode(node: Node(typeID: a.typeID)))
    try editor.apply(.addNode(node: Node(typeID: b.typeID)))
    // Diamonds are fine: A contains B and C, which both contain D.
    let d = definition("D")
    try editor.apply(.addSubgraph(definition: d))
    try editor.apply(.inSubgraph(id: b.id, command: .addNode(node: Node(typeID: d.typeID))))
    try editor.apply(.inSubgraph(id: c.id, command: .addNode(node: Node(typeID: d.typeID))))
    #expect(editor.subgraphs[a.id]?.graph.nodes.count == 3)
}

@Test func theSameGuardAppliesWhenReplayingWithoutFullValidation() throws {
    let a = definition("A")
    let editor = try makeEditor([a])
    #expect(recursiveLoop {
        try editor.apply(.inSubgraph(id: a.id, command: .addNode(node: Node(typeID: a.typeID))), validation: .structural)
    } == [a.id, a.id])
}

@Test func addingADefinitionThatContainsItselfIsRefused() throws {
    var a = definition("A")
    a.graph.insert(Node(typeID: a.typeID))
    let editor = try makeEditor([])
    #expect(recursiveLoop { try editor.apply(.addSubgraph(definition: a)) } == [a.id, a.id])
    #expect(editor.subgraphs.isEmpty && editor.nodes.definition(for: a.typeID) == nil)
}

@Test func updatingADefinitionCannotCloseALoop() throws {
    let b = definition("B")
    let a = definition("A", containing: [b])
    let editor = try makeEditor([b, a])
    // A new version of B that contains A: A -> B -> A.
    var newB = b
    newB.graph.insert(Node(typeID: a.typeID))
    #expect(recursiveLoop { try editor.apply(.updateSubgraph(definition: newB)) } == [b.id, a.id, b.id])
    #expect(editor.subgraphs[b.id] == b)
    // A version of B that contains itself is refused too.
    var selfish = b
    selfish.graph.insert(Node(typeID: b.typeID))
    #expect(recursiveLoop { try editor.apply(.updateSubgraph(definition: selfish)) } == [b.id, b.id])
}

@Test func aLibraryUpdateThatWouldLoopIsRefusedAndTheDocumentIsLeftAlone() throws {
    var library = SubgraphLibrary(id: "lib", name: "Lib")
    let b = definition("B")
    let a = definition("A", containing: [b])
    try library.publish([b, a])
    let editor = try makeEditor([])
    try editor.apply(try editor.importCommand([a.id], from: library))

    // Version 2 of B, published on its own, contains A (which the library still has at revision 1).
    var newB = b
    newB.graph.insert(Node(typeID: a.typeID))
    #expect(throws: LibraryError.self) { try library.publish([newB]) }
    #expect(library.entry(for: b.id)?.revision == 1, "the library refuses it first")
}

@Test func aRefusedEditInsideABatchRollsEverythingBack() throws {
    let a = definition("A")
    let editor = try makeEditor([a])
    let before = editor.subgraphs
    #expect(recursiveLoop {
        try editor.apply(.batch(commands: [
            .inSubgraph(id: a.id, command: .addNode(node: Node(typeID: "const"))),
            .inSubgraph(id: a.id, command: .addNode(node: Node(typeID: a.typeID))),
        ]))
    } != nil)
    #expect(editor.subgraphs == before)
}

@Test func undoAndRedoNeverTripTheGuard() throws {
    let b = definition("B")
    let a = definition("A", containing: [b])
    let editor = try makeEditor([b, a])
    let history = GraphHistory(editor: editor)
    let extra = Node(typeID: b.typeID)
    try history.perform(.inSubgraph(id: a.id, command: .addNode(node: extra)))
    try history.perform(.inSubgraph(id: a.id, command: .removeNode(id: extra.id)))
    try history.undo()          // adds the instance back
    try history.undo()          // removes it again
    try history.redo()
    try history.redo()
    #expect(editor.subgraphs[a.id]?.graph.nodes.count == 1)
}

@Test func conversionAndUnpackingNeverCreateALoop() throws {
    let (nodes, types) = runnable()
    let editor = GraphEditor(nodes: nodes, types: types)
    let history = GraphHistory(editor: editor)
    let leaf = Adder().definition
    try history.perform(.addSubgraph(definition: leaf))
    let outer = definition("Outer")
    try history.perform(.addSubgraph(definition: outer))
    let instance = Node(typeID: leaf.typeID)
    try history.perform(.inSubgraph(id: outer.id, command: .addNode(node: instance)))
    // Wrap the leaf instance, inside Outer, in a new subgraph, then unpack that again.
    let conversion = try editor.convertToSubgraphCommand(nodes: [instance.id], name: "Wrapper", in: outer.id)
    try history.perform(conversion.command)
    let unpacking = try editor.unpackCommand(instance: conversion.instance, in: outer.id)
    try history.perform(unpacking.command)
    #expect(SubgraphDefinition.loops(in: Array(editor.subgraphs.values)).isEmpty)
}

// MARK: Finding loops in existing data

@Test func loopsInADefinitionSetAreFoundWithTheirMembers() {
    var a = definition("A"), b = definition("B"), c = definition("C")
    a.graph.insert(Node(typeID: b.typeID))
    b.graph.insert(Node(typeID: c.typeID))
    c.graph.insert(Node(typeID: a.typeID))
    let loops = SubgraphDefinition.loops(in: [a, b, c])
    #expect(loops.count == 1)
    #expect(loops.first?.first == loops.first?.last, "the chain ends where it began")
    #expect(Set(loops.first ?? []) == [a.id, b.id, c.id])

    var selfish = definition("S")
    selfish.graph.insert(Node(typeID: selfish.typeID))
    #expect(SubgraphDefinition.loops(in: [selfish]) == [[selfish.id, selfish.id]])
    #expect(SubgraphDefinition.loops(in: [definition("Fine"), definition("Also fine")]).isEmpty)
}

@Test func unknownInstancesAreNotLoopsAndADocumentReportsItsLoops() throws {
    var a = definition("A")
    a.graph.insert(Node(typeID: NodeTypeID("subgraph.\(SubgraphID())")))      // an undefined subgraph
    #expect(SubgraphDefinition.loops(in: [a]).isEmpty)

    a.graph.insert(Node(typeID: a.typeID))
    let document = GraphDocument(subgraphs: [a])
    #expect(document.recursiveSubgraphs == [[a.id, a.id]])
    #expect(GraphDocument(subgraphs: [definition("Fine")]).recursiveSubgraphs.isEmpty)
}

// MARK: Phase 3 extras: nesting and port changes

@Test func threeLevelsOfNestingRunWithPromotedPropertiesPassedDown() async throws {
    let adder = Adder()
    let mid = Node(typeID: adder.definition.typeID)
    var midGraph = Graph()
    midGraph.insert(mid)
    let middle = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Middle",
            inputs: [SubgraphInput(id: "x", type: number, defaultValue: 0.0, targets: [PortAddress(node: mid.id, port: "x", direction: .input)])],
            outputs: [SubgraphOutput(id: "result", type: number, source: PortAddress(node: mid.id, port: "result", direction: .output))],
            properties: [PromotedProperty(id: "offset", kind: .double(), defaultValue: 10.0, targets: [PropertyTarget(node: mid.id, property: "offset")])]),
        graph: midGraph)
    let top = Node(typeID: middle.typeID)
    var topGraph = Graph()
    topGraph.insert(top)
    let outer = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Outer",
            inputs: [SubgraphInput(id: "x", type: number, defaultValue: 0.0, targets: [PortAddress(node: top.id, port: "x", direction: .input)])],
            outputs: [SubgraphOutput(id: "result", type: number, source: PortAddress(node: top.id, port: "result", direction: .output))],
            properties: [PromotedProperty(id: "offset", kind: .double(), defaultValue: 10.0, targets: [PropertyTarget(node: top.id, property: "offset")])]),
        graph: topGraph)

    let editor = try makeEditor([adder.definition, middle, outer])
    let source = Node(typeID: "const", properties: ["value": 1.0])
    let instance = Node(typeID: outer.typeID, properties: ["offset": 100.0])
    try editor.apply(.addNode(node: source)); try editor.apply(.addNode(node: instance))
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: source.id, port: "out", direction: .output),
        target: PortAddress(node: instance.id, port: "x", direction: .input)))
    let tick = await (try GraphRunner(graph: editor.graph, registry: editor.nodes, subgraphs: Array(editor.subgraphs.values))).step()
    #expect(tick.outputs(of: instance.id)?["result"] == 101.0)
}

@Test func reorderingAddingAndRetypingPortsKeepsEveryLink() throws {
    let editor = {
        let (nodes, types) = runnable()
        return GraphEditor(nodes: nodes, types: types)
    }()
    let adder = Adder()
    var two = adder.definition
    two.interface.inputs.append(SubgraphInput(
        id: "y", type: number, defaultValue: 0.0, targets: [PortAddress(node: adder.add, port: "b", direction: .input)]))
    // y feeds add.b, which the fixture already feeds from a constant: unlink that one first.
    two.graph.removeLink(try #require(two.graph.links.values.first).id)
    try editor.apply(.addSubgraph(definition: two))
    let source = Node(typeID: "const"), instance = Node(typeID: two.typeID), sink = Node(typeID: "add")
    for node in [source, instance, sink] { try editor.apply(.addNode(node: node)) }
    func connect(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: a, port: out, direction: .output),
            target: PortAddress(node: b, port: input, direction: .input)))
    }
    try connect(source.id, "out", instance.id, "x")
    try connect(source.id, "out", instance.id, "y")
    try connect(instance.id, "result", sink.id, "a")
    let links = editor.graph.links

    var interface = two.interface
    interface.inputs.reverse()                                            // reorder
    interface.inputs[0].displayName = "Why"; interface.inputs[0].type = .any    // relabel and retype
    interface.inputs.append(SubgraphInput(id: "z", type: number, defaultValue: 0.0, targets: [PortAddress(node: adder.add, port: "a", direction: .input)]))
    interface.inputs.removeLast()                                         // z is added in the same breath as it is dropped: nothing to find
    interface.inputs.append(SubgraphInput(id: "extra", type: number, targets: []))
    // `extra` feeds nothing, which a definition may not have, so it is refused and nothing moves.
    #expect(throws: GraphEditError.self) { try editor.apply(.setSubgraphInterface(id: two.id, interface: interface)) }
    #expect(editor.graph.links == links)

    interface.inputs.removeLast()
    try editor.apply(.setSubgraphInterface(id: two.id, interface: interface))
    #expect(editor.graph.links == links, "reordering and relabelling never touch links")
    #expect(editor.nodes.definition(for: two.typeID)?.inputs.map(\.id.rawValue) == ["y", "x"])
}
