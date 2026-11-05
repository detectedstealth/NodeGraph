import Foundation
import Synchronization
import Testing
@testable import NodeGraphCore

// MARK: Fixture

private final class Counter: Sendable {
    private let value = Mutex(0)
    func hit() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

/// Registries whose nodes actually run.
private func runnable(counter: Counter = Counter()) -> (NodeRegistry, TypeRegistry) {
    var (nodes, types) = registries()
    nodes.register(NodeDefinition(
        typeID: "add", displayName: "Add",
        ports: [
            PortDefinition(id: "a", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "b", direction: .input, type: number, defaultValue: 0.0),
            PortDefinition(id: "out", direction: .output, type: number),
        ], isPure: true)
    ) { ctx in counter.hit(); return ["out": .double(try ctx.number("a") + ctx.number("b"))] }
    nodes.register(NodeDefinition(
        typeID: "const", displayName: "Const",
        ports: [PortDefinition(id: "out", direction: .output, type: number)],
        properties: [PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0)],
        isPure: true)
    ) { ctx in ["out": try ctx.property("value")] }
    nodes.register(NodeDefinition(
        typeID: "delay", displayName: "Delay",
        ports: [PortDefinition(id: "in", direction: .input, type: number), PortDefinition(id: "out", direction: .output, type: number)],
        isFeedback: true)
    ) { ctx in ["out": try ctx.input("in")] }
    nodes.register(NodeDefinition(
        typeID: "boom", displayName: "Boom",
        ports: [PortDefinition(id: "in", direction: .input, type: number), PortDefinition(id: "out", direction: .output, type: number)])
    ) { _ in throw NodeExecutionError.failed("kaboom") }
    nodes.register(NodeDefinition(
        typeID: "pulse", displayName: "Pulse",
        ports: [PortDefinition(id: "fire", direction: .output, kind: .trigger)])
    ) { _ in NodeOutputs(triggers: ["fire"]) }
    nodes.register(NodeDefinition(
        typeID: "listener", displayName: "Listener",
        ports: [
            PortDefinition(id: "go", direction: .input, kind: .trigger),
            PortDefinition(id: "heard", direction: .output, type: "bool"),
        ])
    ) { ctx in ["heard": .bool(ctx.didTrigger("go"))] }
    types.register(PortTypeInfo(type: "bool", displayName: "Bool", color: RGBAColor(red: 0, green: 0, blue: 0)))
    return (nodes, types)
}

private struct World {
    var graph = Graph()
    var subgraphs: [SubgraphDefinition] = []
    let nodes: NodeRegistry

    init(counter: Counter = Counter()) { nodes = runnable(counter: counter).0 }

    @discardableResult
    mutating func add(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:], mode: NodeMode = .always) -> NodeID {
        let node = Node(typeID: type, mode: mode, properties: properties)
        graph.insert(node)
        return node.id
    }

    mutating func link(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) {
        graph.insert(Link(sourceNode: a, sourcePort: out, targetNode: b, targetPort: input))
    }

    func runner(caching: Bool = true) throws -> GraphRunner {
        try GraphRunner(graph: graph, registry: nodes, subgraphs: subgraphs, caching: caching)
    }
}

private func result(_ tick: TickResult, _ node: NodeID, _ port: PortID = "result") -> GraphValue? {
    tick.outputs(of: node)?[port]
}

// MARK: Running instances

@Test func anInstanceRunsItsInnerGraphWithItsInputsAndPromotedProperties() async throws {
    var w = World()
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let five = w.add("const", ["value": 5.0])
    let instance = w.add(adder.definition.typeID, ["offset": 3.0])
    w.link(five, "out", instance, "x")
    let tick = await (try w.runner()).step()
    #expect(tick.succeeded)
    #expect(result(tick, instance) == 8.0)           // 5 + 3
}

@Test func unsetInputsAndPropertiesUseTheInterfaceDefaults() async throws {
    var w = World()
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let instance = w.add(adder.definition.typeID)
    #expect(result(await (try w.runner()).step(), instance) == 10.0)   // x default 0 + offset default 10
}

@Test func thePromotedDefaultWinsOverWhatTheInnerNodeHolds() async throws {
    var w = World()
    var adder = Adder()
    // The inner constant says 99, but the promoted property's default (10) is what runs.
    adder.definition.graph.insert(Node(id: adder.constant, typeID: "const", properties: ["value": 99.0]))
    w.subgraphs = [adder.definition]
    let instance = w.add(adder.definition.typeID)
    #expect(result(await (try w.runner()).step(), instance) == 10.0)
}

@Test func instancesOfOneDefinitionAreIndependent() async throws {
    var w = World()
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let a = w.add(adder.definition.typeID, ["offset": 1.0]), b = w.add(adder.definition.typeID, ["offset": 2.0])
    let tick = await (try w.runner()).step()
    #expect(result(tick, a) == 1.0 && result(tick, b) == 2.0)
}

@Test func instancesFeedLaterNodesLikeAnyOther() async throws {
    var w = World()
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let one = w.add("const", ["value": 1.0]), instance = w.add(adder.definition.typeID)
    let after = w.add("add")
    w.link(one, "out", instance, "x")
    w.link(instance, "result", after, "a")              // (1 + 10) feeds a plain node
    #expect(result(await (try w.runner()).step(), after, "out") == 11.0)
}

// MARK: State

/// A subgraph that adds its input to a running total, using a feedback loop inside.
private func accumulator() -> SubgraphDefinition {
    let add = Node(typeID: "add"), memory = Node(typeID: "delay")
    var inner = Graph()
    inner.insert(add); inner.insert(memory)
    inner.insert(Link(sourceNode: add.id, sourcePort: "out", targetNode: memory.id, targetPort: "in"))
    inner.insert(Link(sourceNode: memory.id, sourcePort: "out", targetNode: add.id, targetPort: "b"))
    return SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Accumulate",
            inputs: [SubgraphInput(id: "step", type: number, defaultValue: 0.0,
                                   targets: [PortAddress(node: add.id, port: "a", direction: .input)])],
            outputs: [SubgraphOutput(id: "total", type: number,
                                     source: PortAddress(node: add.id, port: "out", direction: .output))]),
        graph: inner)
}

@Test func eachInstanceKeepsItsOwnStateBetweenPasses() async throws {
    var w = World()
    let accumulate = accumulator()
    w.subgraphs = [accumulate]
    let one = w.add("const", ["value": 1.0]), ten = w.add("const", ["value": 10.0])
    let slow = w.add(accumulate.typeID), fast = w.add(accumulate.typeID)
    w.link(one, "out", slow, "step"); w.link(ten, "out", fast, "step")
    let runner = try w.runner()
    var slowTotals: [GraphValue?] = [], fastTotals: [GraphValue?] = []
    for _ in 0..<4 {
        let tick = await runner.step()
        slowTotals.append(result(tick, slow, "total")); fastTotals.append(result(tick, fast, "total"))
    }
    #expect(slowTotals == [1.0, 2.0, 3.0, 4.0])
    #expect(fastTotals == [10.0, 20.0, 30.0, 40.0])
    await runner.reset()
    #expect(result(await runner.step(), slow, "total") == 1.0, "reset forgets instance state")
}

@Test func pureNodesInsideAnInstanceAreCachedAcrossPasses() async throws {
    let counter = Counter()
    var w = World(counter: counter)
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let instance = w.add(adder.definition.typeID)
    let runner = try w.runner()
    for _ in 0..<3 { #expect(result(await runner.step(), instance) == 10.0) }
    #expect(counter.count == 1)
    await runner.invalidateAll()
    _ = await runner.step()
    #expect(counter.count == 2)
}

@Test func updatingKeepsInstanceStateUnlessADefinitionChanged() async throws {
    var w = World()
    let accumulate = accumulator()
    w.subgraphs = [accumulate]
    let one = w.add("const", ["value": 1.0]), instance = w.add(accumulate.typeID)
    w.link(one, "out", instance, "step")
    let runner = try w.runner()
    _ = await runner.step(); _ = await runner.step()

    var moved = w
    moved.graph.insert(Node(id: one, typeID: "const", properties: ["value": 5.0]))
    try await runner.update(graph: moved.graph, registry: moved.nodes, subgraphs: moved.subgraphs)
    #expect(result(await runner.step(), instance, "total") == 7.0, "state survives a root edit")

    var changed = accumulate
    changed.interface.name = "Renamed"
    try await runner.update(graph: moved.graph, registry: moved.nodes, subgraphs: [changed])
    #expect(result(await runner.step(), instance, "total") == 5.0, "a changed definition starts fresh")
}

// MARK: Failures, modes, triggers

@Test func anInnerFailureFailsTheInstanceAndSkipsWhatDependsOnIt() async throws {
    var w = World()
    var adder = Adder()
    let boom = Node(typeID: "boom")
    adder.definition.graph.insert(boom)
    adder.definition.graph.insert(Link(sourceNode: adder.add, sourcePort: "out", targetNode: boom.id, targetPort: "in"))
    adder.definition.interface.outputs[0].source = PortAddress(node: boom.id, port: "out", direction: .output)
    w.subgraphs = [adder.definition]
    let instance = w.add(adder.definition.typeID), after = w.add("add"), healthy = w.add("const", ["value": 1.0])
    w.link(instance, "result", after, "a")
    let tick = await (try w.runner()).step()
    #expect(tick.failedNodes == [instance])
    guard case .failure(let failure)? = tick.results[instance]?.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("Adder") && failure.message.contains("boom") && failure.message.contains("kaboom"))
    #expect(tick.results[after]?.outcome == .skipped(.upstreamFailed))
    #expect(tick.outputs(of: healthy) == ["out": 1.0])
}

@Test func instanceModesWorkLikeAnyOtherNodesModes() async throws {
    var w = World()
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let source = w.add("const", ["value": 7.0])
    let muted = w.add(adder.definition.typeID, mode: .muted)
    let off = w.add(adder.definition.typeID, mode: .never)
    let bypassed = w.add(adder.definition.typeID, mode: .bypassed)
    w.link(source, "out", bypassed, "x")
    let tick = await (try w.runner()).step()
    #expect(tick.results[muted]?.outcome == .skipped(.muted))
    #expect(tick.results[off]?.outcome == .skipped(.disabled))
    #expect(tick.results[bypassed]?.outcome == .bypassed(["result": 7.0]), "the input passes straight through")
}

@Test func triggersCrossTheSubgraphBoundaryBothWays() async throws {
    var w = World()
    let listener = Node(typeID: "listener"), pulse = Node(typeID: "pulse")
    var inner = Graph()
    inner.insert(listener); inner.insert(pulse)
    let definition = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Relay",
            inputs: [SubgraphInput(id: "go", kind: .trigger, targets: [PortAddress(node: listener.id, port: "go", direction: .input)])],
            outputs: [
                SubgraphOutput(id: "heard", type: "bool", source: PortAddress(node: listener.id, port: "heard", direction: .output)),
                SubgraphOutput(id: "fire", kind: .trigger, source: PortAddress(node: pulse.id, port: "fire", direction: .output)),
            ]),
        graph: inner)
    w.subgraphs = [definition]
    let outsidePulse = w.add("pulse"), outsideListener = w.add("listener")
    let quiet = w.add(definition.typeID), loud = w.add(definition.typeID)
    w.link(outsidePulse, "fire", loud, "go")
    w.link(loud, "fire", outsideListener, "go")
    let tick = await (try w.runner()).step()
    #expect(result(tick, loud, "heard") == true)       // the instance's trigger input reached the inner listener
    #expect(result(tick, quiet, "heard") == false)
    #expect(result(tick, outsideListener, "heard") == true, "the inner pulse left through the trigger output")
}

// MARK: Nesting and limits

@Test func subgraphsNestAndPromotedPropertiesReachTheInnermostNode() async throws {
    var w = World()
    let adder = Adder()
    let nested = Node(typeID: adder.definition.typeID)
    var wrapperGraph = Graph()
    wrapperGraph.insert(nested)
    let wrapper = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Wrapper",
            inputs: [SubgraphInput(id: "in", type: number, defaultValue: 0.0, targets: [PortAddress(node: nested.id, port: "x", direction: .input)])],
            outputs: [SubgraphOutput(id: "result", type: number, source: PortAddress(node: nested.id, port: "result", direction: .output))],
            properties: [PromotedProperty(id: "bias", kind: .double(), defaultValue: 10.0, targets: [PropertyTarget(node: nested.id, property: "offset")])]),
        graph: wrapperGraph)
    w.subgraphs = [adder.definition, wrapper]
    let source = w.add("const", ["value": 4.0])
    let a = w.add(wrapper.typeID, ["bias": 1.0]), b = w.add(wrapper.typeID, ["bias": 100.0])
    w.link(source, "out", a, "in"); w.link(source, "out", b, "in")
    let tick = await (try w.runner()).step()
    #expect(result(tick, a) == 5.0 && result(tick, b) == 104.0)
}

@Test func nestedInstancesKeepSeparateStateEvenThoughTheirNodeIDsRepeat() async throws {
    var w = World()
    let accumulate = accumulator()
    let inner = Node(typeID: accumulate.typeID)
    var wrapperGraph = Graph()
    wrapperGraph.insert(inner)
    let wrapper = SubgraphDefinition(
        interface: SubgraphInterface(
            name: "Wrapper",
            inputs: [SubgraphInput(id: "step", type: number, defaultValue: 0.0, targets: [PortAddress(node: inner.id, port: "step", direction: .input)])],
            outputs: [SubgraphOutput(id: "total", type: number, source: PortAddress(node: inner.id, port: "total", direction: .output))]),
        graph: wrapperGraph)
    w.subgraphs = [accumulate, wrapper]
    let one = w.add("const", ["value": 1.0]), two = w.add("const", ["value": 2.0])
    let a = w.add(wrapper.typeID), b = w.add(wrapper.typeID)
    w.link(one, "out", a, "step"); w.link(two, "out", b, "step")
    let runner = try w.runner()
    _ = await runner.step()
    let tick = await runner.step()
    #expect(result(tick, a, "total") == 2.0 && result(tick, b, "total") == 4.0)
}

@Test func aSubgraphThatContainsItselfFailsCleanlyInsteadOfRecursingForever() async throws {
    var w = World()
    var definition = SubgraphDefinition(interface: SubgraphInterface(name: "Loop"), graph: Graph())
    definition.graph.insert(Node(typeID: definition.typeID))
    w.subgraphs = [definition]
    let outer = w.add(definition.typeID), healthy = w.add("const", ["value": 1.0])
    let tick = await (try w.runner()).step()
    guard case .failure(let failure)? = tick.results[outer]?.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("nested too deeply"))
    #expect(tick.outputs(of: healthy) == ["out": 1.0])
}

@Test func aSubgraphWhoseInnerGraphHasACycleFailsOnlyItsInstances() async throws {
    var w = World()
    var adder = Adder()
    adder.definition.graph.insert(Link(sourceNode: adder.add, sourcePort: "out", targetNode: adder.add, targetPort: "b"))
    w.subgraphs = [adder.definition]
    let broken = w.add(adder.definition.typeID), healthy = w.add("const", ["value": 2.0])
    let tick = await (try w.runner()).step()
    guard case .failure(let failure)? = tick.results[broken]?.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("cycle"))
    #expect(tick.outputs(of: healthy) == ["out": 2.0])
}

@Test func anInstanceWhoseDefinitionIsMissingFails() async throws {
    var w = World()
    let adder = Adder()
    let orphan = w.add(adder.definition.typeID)   // definition never given to the runner
    let tick = await (try w.runner()).step()
    #expect(tick.failedNodes == [orphan])
}

// MARK: Integration

@Test func anEditedDocumentRunsEndToEnd() async throws {
    let (nodes, types) = runnable()
    let editor = GraphEditor(nodes: nodes, types: types)
    let adder = Adder()
    try editor.apply(.addSubgraph(definition: adder.definition))
    let source = Node(typeID: "const", properties: ["value": 2.0])
    let instance = Node(typeID: adder.definition.typeID, properties: ["offset": 40.0])
    try editor.apply(.addNode(node: source)); try editor.apply(.addNode(node: instance))
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: source.id, port: "out", direction: .output),
        target: PortAddress(node: instance.id, port: "x", direction: .input)))

    let document = try GraphDocument.decode(from: editor.makeDocument().encoded())
    let runner = try GraphRunner(document: document, registry: nodes)
    #expect(result(await runner.step(), instance.id) == 42.0)
}

@Test func innerNodesAreNotAnnouncedInTheEventStream() async throws {
    var w = World()
    let adder = Adder()
    w.subgraphs = [adder.definition]
    let instance = w.add(adder.definition.typeID)
    let runner = try w.runner()
    let stream = runner.events()
    _ = await runner.step()
    var announced = Set<NodeID>()
    for await event in stream {
        if case .nodeFinished(let node, _, _, _) = event { announced.insert(node) }
        if case .passFinished = event { break }
    }
    #expect(announced == [instance])
}
