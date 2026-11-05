import Foundation
import Synchronization
import Testing
@testable import NodeGraphCore

// MARK: Fixture

private final class Log: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ item: String) { items.withLock { $0.append(item) } }
    var all: [String] { items.withLock { $0 } }
}

private struct Pack {
    var registry = NodeRegistry()
    var graph = Graph()
    let log = Log()

    init() {
        registry.register(NodeDefinition(
            typeID: "const", displayName: "Const",
            ports: [PortDefinition(id: "out", direction: .output)],
            properties: [PropertyDefinition(id: "value", displayName: "Value", kind: .double(), defaultValue: 0.0)])
        ) { ctx in ["out": try ctx.property("value")] }

        registry.register(NodeDefinition(
            typeID: "add", displayName: "Add",
            ports: [
                PortDefinition(id: "a", direction: .input, defaultValue: 0.0),
                PortDefinition(id: "b", direction: .input, defaultValue: 0.0),
                PortDefinition(id: "sum", direction: .output),
            ])
        ) { ctx in ["sum": .double(try ctx.number("a") + ctx.number("b"))] }

        registry.register(NodeDefinition(
            typeID: "total", displayName: "Total",
            ports: [
                PortDefinition(id: "in", direction: .input, allowsMultipleLinks: true),
                PortDefinition(id: "out", direction: .output),
            ])
        ) { ctx in
            guard case .array(let values) = try ctx.input("in") else { throw NodeExecutionError.invalidInput("in", expected: "array") }
            return ["out": .array(values)]
        }

        registry.register(NodeDefinition(
            typeID: "fail", displayName: "Fail",
            ports: [PortDefinition(id: "in", direction: .input), PortDefinition(id: "out", direction: .output)])
        ) { _ in throw NodeExecutionError.failed("boom") }

        registry.register(NodeDefinition(
            typeID: "pass", displayName: "Pass",
            ports: [PortDefinition(id: "in", direction: .input), PortDefinition(id: "out", direction: .output)])
        ) { ctx in ["out": try ctx.input("in")] }

        registry.register(NodeDefinition(
            typeID: "delay", displayName: "Delay",
            ports: [PortDefinition(id: "in", direction: .input), PortDefinition(id: "out", direction: .output)],
            isFeedback: true)
        ) { ctx in ["out": try ctx.input("in")] }

        let log = log
        registry.register(NodeDefinition(
            typeID: "record", displayName: "Record",
            ports: [PortDefinition(id: "out", direction: .output)],
            properties: [PropertyDefinition(id: "name", displayName: "Name", kind: .string(), defaultValue: "")])
        ) { ctx in
            log.add(try ctx.property("name").stringValue ?? "")
            return ["out": .double(ctx.time.elapsedSeconds)]
        }

        registry.register(NodeDefinition(
            typeID: "sleep", displayName: "Sleep",
            ports: [PortDefinition(id: "out", direction: .output)])
        ) { _ in
            try await Task.sleep(for: .milliseconds(150))
            return ["out": 1.0]
        }

        registry.register(NodeDefinition(
            typeID: "wait", displayName: "Wait",
            ports: [PortDefinition(id: "out", direction: .output)])
        ) { _ in
            while true { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    @discardableResult
    mutating func node(
        _ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:], mode: NodeMode = .always
    ) -> NodeID {
        let node = Node(typeID: type, mode: mode, properties: properties)
        graph.insert(node)
        return node.id
    }

    mutating func link(_ a: NodeID, _ out: PortID = "out", _ b: NodeID, _ input: PortID) {
        graph.insert(Link(sourceNode: a, sourcePort: out, targetNode: b, targetPort: input))
    }

    func runner(services: ServiceContainer = ServiceContainer()) throws -> GraphRunner {
        try GraphRunner(graph: graph, registry: registry, services: services)
    }
}

private func collect(_ stream: AsyncStream<TickResult>, count: Int) async -> [TickResult] {
    var all: [TickResult] = []
    for await result in stream {
        all.append(result)
        if all.count == count { break }
    }
    return all
}

// MARK: Once and data flow

@Test func onceEvaluatesTheWholeGraphInDependencyOrder() async throws {
    var p = Pack()
    let sum = p.node("add"), two = p.node("const", ["value": 2.0]), three = p.node("const", ["value": 3.0])
    p.link(two, "out", sum, "a")
    p.link(three, "out", sum, "b")
    let results = await collect(try p.runner().run(.once), count: 5)
    #expect(results.count == 1)
    let tick = results[0]
    #expect(tick.succeeded && tick.tick == 0 && !tick.wasCancelled)
    #expect(tick.outputs(of: sum) == ["sum": 5.0])
    #expect(Array(tick.results.keys) == [two, three, sum])
}

@Test func unlinkedInputsUseTheirDefaults() async throws {
    var p = Pack()
    let sum = p.node("add"), one = p.node("const", ["value": 1.0])
    p.link(one, "out", sum, "a")
    let tick = await (try p.runner()).step()
    #expect(tick.outputs(of: sum) == ["sum": 1.0])
}

@Test func multiLinkInputsReceiveAnArrayInLinkOrder() async throws {
    var p = Pack()
    let a = p.node("const", ["value": 1.0]), b = p.node("const", ["value": 2.0])
    let total = p.node("total")
    p.link(b, "out", total, "in")
    p.link(a, "out", total, "in")
    let tick = await (try p.runner()).step()
    #expect(tick.outputs(of: total) == ["out": .array([2.0, 1.0])])
}

// MARK: Failure

@Test func aFailureSkipsOnlyItsDownstream() async throws {
    var p = Pack()
    let source = p.node("const", ["value": 1.0]), bad = p.node("fail"), after = p.node("pass")
    let healthy = p.node("pass")
    p.link(source, "out", bad, "in")
    p.link(bad, "out", after, "in")
    p.link(source, "out", healthy, "in")
    let tick = await (try p.runner()).step()
    #expect(tick.failedNodes == [bad])
    #expect(tick.results[after]?.outcome == .skipped(.upstreamFailed))
    #expect(tick.outputs(of: healthy) == ["out": 1.0])
    #expect(!tick.succeeded)
    guard case .failure(let failure)? = tick.results[bad]?.outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("boom"))
}

@Test func skippingPropagatesThroughChains() async throws {
    var p = Pack()
    let bad = p.node("fail"), one = p.node("pass"), two = p.node("pass")
    p.link(bad, "out", one, "in")
    p.link(one, "out", two, "in")
    let tick = await (try p.runner()).step()
    #expect(tick.results[two]?.outcome == .skipped(.upstreamFailed))
}

@Test func nodesWithoutAnExecutorFail() async throws {
    var p = Pack()
    p.registry.register(NodeDefinition(typeID: "display", displayName: "Display"))
    let shown = p.node("display"), ghost = p.node("ghost")
    let tick = await (try p.runner()).step()
    #expect(Set(tick.failedNodes) == [shown, ghost])
}

// MARK: Feedback

@Test func aFeedbackLoopAccumulatesAcrossTicks() async throws {
    var p = Pack()
    let one = p.node("const", ["value": 1.0]), acc = p.node("add"), memory = p.node("delay")
    p.link(one, "out", acc, "a")
    p.link(memory, "out", acc, "b")     // feedback: the previous tick's value
    p.link(acc, "sum", memory, "in")
    let runner = try p.runner()
    var sums: [GraphValue?] = []
    for _ in 0..<4 { sums.append(await runner.step().outputs(of: acc)?["sum"]) }
    #expect(sums == [1.0, 2.0, 3.0, 4.0])
}

@Test func resetClearsFeedbackAndTheTickCounter() async throws {
    var p = Pack()
    let one = p.node("const", ["value": 1.0]), acc = p.node("add"), memory = p.node("delay")
    p.link(one, "out", acc, "a"); p.link(memory, "out", acc, "b"); p.link(acc, "sum", memory, "in")
    let runner = try p.runner()
    _ = await runner.step(); _ = await runner.step()
    #expect(await runner.completedTicks == 2)
    await runner.reset()
    let tick = await runner.step()
    #expect(tick.tick == 0 && tick.outputs(of: acc) == ["sum": 1.0])
}

// MARK: Modes

@Test func deterministicRunsAreReproducibleAndSimulateTime() async throws {
    var p = Pack()
    let one = p.node("const", ["value": 1.0]), acc = p.node("add"), memory = p.node("delay")
    p.link(one, "out", acc, "a"); p.link(memory, "out", acc, "b"); p.link(acc, "sum", memory, "in")
    p.node("record", ["name": "r"])

    func run() async throws -> [TickResult] {
        await collect(try p.runner().run(.deterministic(fixedDelta: .milliseconds(10), ticks: 5)), count: 99)
    }
    let first = try await run(), second = try await run()
    #expect(first.count == 5)
    #expect(first.map { $0.tick } == [0, 1, 2, 3, 4])
    #expect(first.map { $0.time.elapsed } == (0..<5).map { .milliseconds(10) * $0 })
    #expect(first.allSatisfy { $0.time.delta == .milliseconds(10) })
    // Same inputs, same outputs, regardless of wall-clock time.
    #expect(first.map { $0.results.mapValues(\.outcome) } == second.map { $0.results.mapValues(\.outcome) })
    #expect(first.last?.outputs(of: acc) == ["sum": 5.0])
}

@Test func deterministicModeRunsNodesOneAtATimeInPlanOrder() async throws {
    var p = Pack()
    let names = ["a", "b", "c", "d"]
    for name in names { p.node("record", ["name": .string(name)]) }
    _ = await collect(try p.runner().run(.deterministic(fixedDelta: .milliseconds(1), ticks: 3)), count: 99)
    #expect(p.log.all == names + names + names)
}

@Test func nodesInOneLevelRunConcurrently() async throws {
    var p = Pack()
    for _ in 0..<4 { p.node("sleep") }
    let start = ContinuousClock.now
    let tick = await (try p.runner()).step()
    let took = ContinuousClock.now - start
    #expect(tick.succeeded)
    #expect(took < .milliseconds(400), "4 x 150 ms ran serially: \(took)")
}

@Test func stepReportsRealTimeDeltas() async throws {
    var p = Pack()
    p.node("record", ["name": "r"])
    let runner = try p.runner()
    let first = await runner.step()
    try await Task.sleep(for: .milliseconds(30))
    let second = await runner.step()
    #expect(first.tick == 0 && first.time.delta == .zero)
    #expect(second.tick == 1 && second.time.delta >= .milliseconds(25))
    #expect(second.time.elapsed >= second.time.delta)
}

@Test func continuousRunsRepeatedlyUntilTheConsumerStops() async throws {
    var p = Pack()
    p.node("record", ["name": "r"])
    let results = await collect(try p.runner().run(.continuous(interval: .milliseconds(10))), count: 3)
    #expect(results.count == 3)
    #expect(zip(results, results.dropFirst()).allSatisfy { $0.tick < $1.tick })
    #expect(results.allSatisfy { $0.succeeded })
}

@Test func eventDrivenRunsOnlyWhenAsked() async throws {
    var p = Pack()
    p.node("record", ["name": "r"])
    let runner = try p.runner()
    let stream = runner.run(.eventDriven)
    var iterator = stream.makeAsyncIterator()

    try await Task.sleep(for: .milliseconds(50))
    #expect(p.log.all.isEmpty, "nothing should run before a request")

    runner.requestEvaluation()
    let first = await iterator.next()
    runner.requestEvaluation()
    let second = await iterator.next()
    #expect(first?.tick == 0 && second?.tick == 1)
    #expect(p.log.all.count == 2)
}

@Test func onceFinishesItsStream() async throws {
    var p = Pack()
    p.node("record", ["name": "r"])
    var count = 0
    for await _ in try p.runner().run(.once) { count += 1 }
    #expect(count == 1)
}

// MARK: Cancellation and serialization

@Test func cancellingMidPassMarksUnfinishedNodesCancelled() async throws {
    var p = Pack()
    let waiting = p.node("wait"), after = p.node("pass")
    p.link(waiting, "out", after, "in")
    let runner = try p.runner()
    let task = Task { await runner.step() }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let tick = await task.value
    #expect(tick.wasCancelled)
    #expect(tick.results[waiting]?.outcome == .cancelled)
    #expect(tick.results[after]?.outcome == .cancelled)
}

@Test func overlappingStepsAreSerialized() async throws {
    var p = Pack()
    let running = Mutex(0), peak = Mutex(0)
    p.registry.register(NodeDefinition(
        typeID: "probe", displayName: "Probe", ports: [PortDefinition(id: "out", direction: .output)])
    ) { _ in
        let now = running.withLock { $0 += 1; return $0 }
        peak.withLock { $0 = max($0, now) }
        try await Task.sleep(for: .milliseconds(30))
        running.withLock { $0 -= 1 }
        return [:]
    }
    p.node("probe")
    let runner = try p.runner()
    let ticks = await withTaskGroup(of: Int.self) { group in
        for _ in 0..<4 { group.addTask { await runner.step().tick } }
        var all: [Int] = []
        for await tick in group { all.append(tick) }
        return all.sorted()
    }
    #expect(ticks == [0, 1, 2, 3])
    #expect(peak.withLock { $0 } == 1)
}

// MARK: Updating, services, progress

@Test func updateSwapsTheGraphAndKeepsPreviousOnError() async throws {
    var p = Pack()
    let one = p.node("const", ["value": 1.0])
    let runner = try p.runner()
    #expect(await runner.step().outputs(of: one) == ["out": 1.0])

    var changed = p
    changed.graph.insert(Node(id: one, typeID: "const", properties: ["value": 9.0]))
    try await runner.update(graph: changed.graph, registry: changed.registry)
    #expect(await runner.step().outputs(of: one) == ["out": 9.0])

    var cyclic = Pack()
    let a = cyclic.node("pass"), b = cyclic.node("pass")
    cyclic.link(a, "out", b, "in"); cyclic.link(b, "out", a, "in")
    await #expect(throws: ExecutionPlanError.self) {
        try await runner.update(graph: cyclic.graph, registry: cyclic.registry)
    }
    #expect(await runner.step().outputs(of: one) == ["out": 9.0])
}

@Test func creatingARunnerForACyclicGraphThrows() {
    var p = Pack()
    let a = p.node("pass"), b = p.node("pass")
    p.link(a, "out", b, "in"); p.link(b, "out", a, "in")
    #expect(throws: ExecutionPlanError.self) { try p.runner() }
}

private struct Gain: Sendable { var value: Double }

@Test func servicesAndProgressReachNodes() async throws {
    var p = Pack()
    let seen = Log()
    p.registry.register(NodeDefinition(
        typeID: "svc", displayName: "Svc", ports: [PortDefinition(id: "out", direction: .output)])
    ) { ctx in
        ctx.reportProgress(0.5, message: "half")
        return ["out": .double(ctx.services[Gain.self]?.value ?? -1)]
    }
    let id = p.node("svc")
    var services = ServiceContainer()
    services.register(Gain(value: 4))
    let runner = try GraphRunner(
        graph: p.graph, registry: p.registry, services: services,
        onProgress: { seen.add("\($0.fraction) \($0.message ?? "")") })
    #expect(await runner.step().outputs(of: id) == ["out": 4.0])
    #expect(seen.all == ["0.5 half"])
}

// MARK: Triggers

private func triggerPack() -> Pack {
    var p = Pack()
    // Fires "hit" when its input exceeds a threshold.
    p.registry.register(NodeDefinition(
        typeID: "threshold", displayName: "Threshold",
        ports: [
            PortDefinition(id: "in", direction: .input, defaultValue: 0.0),
            PortDefinition(id: "hit", direction: .output, kind: .trigger),
            PortDefinition(id: "out", direction: .output),
        ])
    ) { ctx in
        let over = try ctx.number("in") > 10
        return NodeOutputs(["out": .double(try ctx.number("in"))], triggers: over ? ["hit"] : [])
    }
    // Reports which of its trigger inputs fired.
    p.registry.register(NodeDefinition(
        typeID: "listener", displayName: "Listener",
        ports: [
            PortDefinition(id: "a", direction: .input, kind: .trigger),
            PortDefinition(id: "b", direction: .input, kind: .trigger, allowsMultipleLinks: true),
            PortDefinition(id: "fired", direction: .output),
        ])
    ) { ctx in
        ["fired": .string([ctx.didTrigger("a") ? "a" : "", ctx.didTrigger("b") ? "b" : ""].joined())]
    }
    return p
}

private func firedPorts(_ tick: TickResult, _ node: NodeID) -> String? {
    tick.outputs(of: node)?["fired"]?.stringValue
}

@Test func aTriggerFiresDownstreamInputsOnlyWhenTheSourceFires() async throws {
    var p = triggerPack()
    let quiet = p.node("const", ["value": 1.0]), loud = p.node("const", ["value": 50.0])
    let low = p.node("threshold"), high = p.node("threshold")
    let listener = p.node("listener"), other = p.node("listener")
    p.link(quiet, "out", low, "in"); p.link(loud, "out", high, "in")
    p.link(low, "hit", listener, "a")
    p.link(high, "hit", other, "a")
    let tick = await (try p.runner()).step()
    #expect(tick.succeeded)
    #expect(firedPorts(tick, listener) == "")
    #expect(firedPorts(tick, other) == "a")
    #expect(tick.outputs(of: high)?.triggers == ["hit"] && tick.outputs(of: low)?.triggers == [])
}

@Test func anyOneOfSeveralTriggerSourcesFiresTheInput() async throws {
    var p = triggerPack()
    let quiet = p.node("const", ["value": 1.0]), loud = p.node("const", ["value": 50.0])
    let low = p.node("threshold"), high = p.node("threshold"), listener = p.node("listener")
    p.link(quiet, "out", low, "in"); p.link(loud, "out", high, "in")
    p.link(low, "hit", listener, "b")
    p.link(high, "hit", listener, "b")
    #expect(firedPorts(await (try p.runner()).step(), listener) == "b")
}

@Test func triggersAndDataAreIndependent() async throws {
    var p = triggerPack()
    let loud = p.node("const", ["value": 50.0]), source = p.node("threshold"), listener = p.node("listener")
    p.link(loud, "out", source, "in")
    p.link(source, "hit", listener, "a")
    let tick = await (try p.runner()).step()
    // The trigger fired, and the data output next to it still carries its value.
    #expect(tick.outputs(of: source) == NodeOutputs(["out": 50.0], triggers: ["hit"]))
    #expect(firedPorts(tick, listener) == "a")
}

@Test func unconnectedTriggerInputsNeverFire() async throws {
    var p = triggerPack()
    let listener = p.node("listener")
    #expect(firedPorts(await (try p.runner()).step(), listener) == "")
}

@Test func triggersOverFeedbackLinksArriveOnTheNextPass() async throws {
    var p = triggerPack()
    p.registry.register(NodeDefinition(
        typeID: "pulse", displayName: "Pulse", ports: [PortDefinition(id: "tick", direction: .output, kind: .trigger)],
        isFeedback: true)
    ) { _ in NodeOutputs(triggers: ["tick"]) }
    let pulse = p.node("pulse"), listener = p.node("listener")
    p.link(pulse, "tick", listener, "a")
    let runner = try p.runner()
    let first = await runner.step(), second = await runner.step()
    #expect(firedPorts(first, listener) == "")      // nothing existed on the first pass
    #expect(firedPorts(second, listener) == "a")
}

@Test func aFailedTriggerSourceSkipsTheListener() async throws {
    var p = triggerPack()
    p.registry.register(NodeDefinition(
        typeID: "badfire", displayName: "BadFire", ports: [PortDefinition(id: "hit", direction: .output, kind: .trigger)])
    ) { _ in throw NodeExecutionError.failed("no") }
    let source = p.node("badfire"), listener = p.node("listener")
    p.link(source, "hit", listener, "a")
    let tick = await (try p.runner()).step()
    #expect(tick.results[listener]?.outcome == .skipped(.upstreamFailed))
}

@Test func writingTheWrongKindOfOutputFails() async throws {
    var p = triggerPack()
    p.registry.register(NodeDefinition(
        typeID: "valueOnTrigger", displayName: "V",
        ports: [PortDefinition(id: "hit", direction: .output, kind: .trigger), PortDefinition(id: "out", direction: .output)])
    ) { _ in ["hit": 1.0] }
    p.registry.register(NodeDefinition(
        typeID: "fireOnData", displayName: "F",
        ports: [PortDefinition(id: "hit", direction: .output, kind: .trigger), PortDefinition(id: "out", direction: .output)])
    ) { _ in NodeOutputs(triggers: ["out"]) }
    p.registry.register(NodeDefinition(
        typeID: "fireUnknown", displayName: "U", ports: [PortDefinition(id: "hit", direction: .output, kind: .trigger)])
    ) { _ in NodeOutputs(triggers: ["nope"]) }
    let a = p.node("valueOnTrigger"), b = p.node("fireOnData"), c = p.node("fireUnknown")
    let tick = await (try p.runner()).step()
    for (id, word) in [(a, "wrongPortKind"), (b, "wrongPortKind"), (c, "undeclaredOutput")] {
        guard case .failure(let failure)? = tick.results[id]?.outcome else { Issue.record("expected failure"); continue }
        #expect(failure.message.contains(word))
    }
}

@Test func triggerPortsDoNotGetDataDefaults() {
    let definition = NodeDefinition(typeID: "t", displayName: "T", ports: [
        PortDefinition(id: "go", direction: .input, kind: .trigger, defaultValue: true)])
    let ctx = NodeContext(node: Node(typeID: "t"), definition: definition)
    #expect(ctx.inputs["go"] == nil && !ctx.didTrigger("go"))
    let fired = NodeContext(node: Node(typeID: "t"), definition: definition, triggered: ["go"])
    #expect(fired.didTrigger("go"))
}


// MARK: Node modes

@Test func aNeverNodeAndEverythingAfterItAreSwitchedOff() async throws {
    var p = Pack()
    let off = p.node("const", ["value": 1.0], mode: .never)
    let next = p.node("pass"), last = p.node("pass"), independent = p.node("const", ["value": 2.0])
    p.link(off, "out", next, "in"); p.link(next, "out", last, "in")
    let tick = await (try p.runner()).step()
    #expect(tick.results[off]?.outcome == .skipped(.disabled))
    #expect(tick.results[next]?.outcome == .skipped(.upstreamDisabled))
    #expect(tick.results[last]?.outcome == .skipped(.upstreamDisabled))
    #expect(tick.outputs(of: independent) == ["out": 2.0])
    #expect(tick.failedNodes.isEmpty)
}

@Test func aMutedNodePublishesNothingButNodesAfterItStillRun() async throws {
    var p = Pack()
    let muted = p.node("const", ["value": 5.0], mode: .muted), sum = p.node("add")
    p.link(muted, "out", sum, "a")
    let tick = await (try p.runner()).step()
    #expect(tick.results[muted]?.outcome == .skipped(.muted))
    #expect(tick.outputs(of: sum) == ["sum": 0.0], "the muted value must not arrive; the default does")
    #expect(tick.succeeded == false && tick.failedNodes.isEmpty)
}

@Test func failureOutranksDisabledWhenBothFeedANode() async throws {
    var p = Pack()
    let bad = p.node("fail"), off = p.node("const", mode: .never), total = p.node("total")
    p.link(off, "out", total, "in"); p.link(bad, "out", total, "in")
    #expect(await (try p.runner()).step().results[total]?.outcome == .skipped(.upstreamFailed))
}

@Test func aMutedOrNeverNodeDoesNotNeedItsTypeToExist() async throws {
    var p = Pack()
    let ghostMuted = p.node("ghost", mode: .muted), ghostOff = p.node("ghost", mode: .never)
    let tick = await (try p.runner()).step()
    #expect(tick.results[ghostMuted]?.outcome == .skipped(.muted))
    #expect(tick.results[ghostOff]?.outcome == .skipped(.disabled))
}

@Test func aBypassedNodePassesItsInputThrough() async throws {
    var p = Pack()
    let source = p.node("const", ["value": 7.0]), bypassed = p.node("add", mode: .bypassed), after = p.node("pass")
    p.link(source, "out", bypassed, "a")
    p.link(bypassed, "sum", after, "in")
    let tick = await (try p.runner()).step()
    #expect(tick.results[bypassed]?.outcome == .bypassed(["sum": 7.0]))
    #expect(tick.outputs(of: after) == ["out": 7.0])
    #expect(tick.outputs(of: bypassed) == ["sum": 7.0])
    #expect(tick.succeeded == false, "a bypassed node is not a success")
}

@Test func bypassMatchesPortsByTypeAndOrder() {
    let definition = NodeDefinition(typeID: "mix", displayName: "Mix", ports: [
        PortDefinition(id: "n1", direction: .input, type: "number"),
        PortDefinition(id: "s1", direction: .input, type: "string"),
        PortDefinition(id: "n2", direction: .input, type: "number"),
        PortDefinition(id: "text", direction: .output, type: "string"),
        PortDefinition(id: "first", direction: .output, type: "number"),
        PortDefinition(id: "second", direction: .output, type: "number"),
        PortDefinition(id: "extra", direction: .output, type: "number"),
        PortDefinition(id: "any", direction: .output),
        PortDefinition(id: "go", direction: .input, kind: .trigger),
        PortDefinition(id: "skip", direction: .input, kind: .trigger),
        PortDefinition(id: "done", direction: .output, kind: .trigger),
        PortDefinition(id: "never", direction: .output, kind: .trigger),
    ])
    let result = definition.bypassedOutputs(
        inputs: ["n1": 1.0, "s1": "s", "n2": 2.0], triggered: ["go"])
    #expect(result.values == ["text": "s", "first": 1.0, "second": 2.0])   // no third number; "any" has nothing left
    #expect(result.triggers == ["done"])
    // An input with no value is not passed on, and the next one takes its place.
    let sparse = definition.bypassedOutputs(inputs: ["n2": 2.0], triggered: [])
    #expect(sparse.values == ["first": 2.0] && sparse.triggers.isEmpty)
}

@Test func aBypassedNodeWithAMissingPackStillPassesThrough() async throws {
    var p = Pack()
    let source = p.node("const", ["value": 3.0]), ghost = p.node("ghost", mode: .bypassed), after = p.node("pass")
    p.link(source, "out", ghost, "in")
    p.link(ghost, "out", after, "in")
    // Placeholder definitions give the missing type ports (from its links) but no executor.
    let registry = p.registry.addingPlaceholders(for: p.graph)
    let tick = await (try GraphRunner(graph: p.graph, registry: registry)).step()
    #expect(tick.results[ghost]?.outcome == .bypassed(["out": 3.0]))
    #expect(tick.outputs(of: after) == ["out": 3.0])
    #expect(tick.failedNodes.isEmpty)
}

@Test func bypassedTriggersPassThrough() async throws {
    var p = triggerPack()
    p.registry.register(NodeDefinition(typeID: "relay", displayName: "Relay", ports: [
        PortDefinition(id: "in", direction: .input, kind: .trigger),
        PortDefinition(id: "out", direction: .output, kind: .trigger),
    ])) { _ in NodeOutputs.empty }
    let loud = p.node("const", ["value": 50.0]), source = p.node("threshold")
    let relay = p.node("relay", mode: .bypassed), listener = p.node("listener")
    p.link(loud, "out", source, "in"); p.link(source, "hit", relay, "in"); p.link(relay, "out", listener, "a")
    #expect(firedPorts(await (try p.runner()).step(), listener) == "a")
}

private func latchPack() -> Pack {
    var p = triggerPack()
    // Copies "in" to "out" and fires "done", but only when "go" fires (when set to onTrigger).
    p.registry.register(NodeDefinition(
        typeID: "latch", displayName: "Latch",
        ports: [
            PortDefinition(id: "in", direction: .input, defaultValue: 0.0),
            PortDefinition(id: "go", direction: .input, kind: .trigger),
            PortDefinition(id: "out", direction: .output),
            PortDefinition(id: "done", direction: .output, kind: .trigger),
        ])
    ) { ctx in NodeOutputs(["out": try ctx.input("in")], triggers: ["done"]) }
    return p
}

@Test func anOnTriggerNodeRunsOnlyWhenTriggeredAndHoldsItsLastOutputs() async throws {
    var p = latchPack()
    let value = p.node("const", ["value": 50.0]), gate = p.node("threshold")
    let latch = p.node("latch", mode: .onTrigger), reader = p.node("add"), listener = p.node("listener")
    p.link(value, "out", gate, "in")
    p.link(gate, "out", latch, "in")
    p.link(gate, "hit", latch, "go")
    p.link(latch, "out", reader, "a")
    p.link(latch, "done", listener, "a")
    let runner = try p.runner()

    let first = await runner.step()           // 50 > 10: the gate fires, the latch runs
    #expect(first.results[latch]?.outcome == .success(NodeOutputs(["out": 50.0], triggers: ["done"])))
    #expect(first.outputs(of: reader) == ["sum": 50.0])
    #expect(firedPorts(first, listener) == "a")

    var quiet = p
    quiet.graph.insert(Node(id: value, typeID: "const", properties: ["value": 1.0]))
    try await runner.update(graph: quiet.graph, registry: quiet.registry)
    let second = await runner.step()          // 1 < 10: no trigger
    #expect(second.results[latch]?.outcome == .skipped(.notTriggered))
    #expect(second.outputs(of: reader) == ["sum": 50.0], "the reader still sees the held value")
    #expect(firedPorts(second, listener) == "", "triggers are events, never held")

    await runner.reset()
    let third = await runner.step()
    #expect(third.outputs(of: reader) == ["sum": 0.0], "reset forgets held outputs")
}

@Test func anOnTriggerNodeBeforeItsFirstRunPublishesNothing() async throws {
    var p = latchPack()
    let latch = p.node("latch", mode: .onTrigger), reader = p.node("add")
    p.link(latch, "out", reader, "a")
    let tick = await (try p.runner()).step()
    #expect(tick.results[latch]?.outcome == .skipped(.notTriggered))
    #expect(tick.outputs(of: reader) == ["sum": 0.0])
}

@Test func anOnTriggerNodeWithNoTriggerInputsNeverRuns() async throws {
    var p = Pack()
    let id = p.node("const", ["value": 1.0], mode: .onTrigger)
    let runner = try p.runner()
    _ = await runner.step()
    #expect(await runner.step().results[id]?.outcome == .skipped(.notTriggered))
}

@Test func changingAModeTakesEffectOnUpdate() async throws {
    var p = Pack()
    let id = p.node("const", ["value": 1.0])
    let runner = try p.runner()
    #expect(await runner.step().outputs(of: id) == ["out": 1.0])
    var changed = p
    changed.graph.insert(Node(id: id, typeID: "const", mode: .muted, properties: ["value": 1.0]))
    try await runner.update(graph: changed.graph, registry: changed.registry)
    #expect(await runner.step().results[id]?.outcome == .skipped(.muted))
}

@Test func modesSurviveSavingAndLoading() throws {
    var p = Pack()
    p.node("const", mode: .bypassed); p.node("const", mode: .onTrigger)
    let document = try GraphDocument.decode(from: GraphDocument(graph: p.graph).encoded())
    #expect(document.graph.nodes.values.map(\.mode) == [.bypassed, .onTrigger])
}

// MARK: Caching

private final class Counter: Sendable {
    private let counts = Mutex<[String: Int]>([:])
    func hit(_ name: String) { counts.withLock { $0[name, default: 0] += 1 } }
    subscript(_ name: String) -> Int { counts.withLock { $0[name] ?? 0 } }
}

private struct CachePack {
    var pack = Pack()
    let counter = Counter()

    init(failFirstDouble: Bool = false) {
        let counter = counter
        let failures = Mutex(failFirstDouble ? 1 : 0)
        pack.registry.register(NodeDefinition(
            typeID: "src", displayName: "Src",
            ports: [PortDefinition(id: "out", direction: .output)],
            properties: [PropertyDefinition(id: "value", displayName: "V", kind: .double(), defaultValue: 0.0)],
            isPure: true)
        ) { ctx in counter.hit("src"); return ["out": try ctx.property("value")] }

        pack.registry.register(NodeDefinition(
            typeID: "double", displayName: "Double",
            ports: [PortDefinition(id: "in", direction: .input, defaultValue: 0.0), PortDefinition(id: "out", direction: .output)],
            isPure: true)
        ) { ctx in
            counter.hit("double")
            if failures.withLock({ let f = $0 > 0; if f { $0 -= 1 }; return f }) { throw NodeExecutionError.failed("once") }
            return ["out": .double(try ctx.number("in") * 2)]
        }

        pack.registry.register(NodeDefinition(
            typeID: "clamp", displayName: "Clamp",
            ports: [PortDefinition(id: "in", direction: .input, defaultValue: 0.0), PortDefinition(id: "out", direction: .output)],
            isPure: true)
        ) { ctx in counter.hit("clamp"); return ["out": .double(min(try ctx.number("in"), 10))] }

        // Impure: depends on the tick, so it must run every pass.
        pack.registry.register(NodeDefinition(
            typeID: "ticker", displayName: "Ticker", ports: [PortDefinition(id: "out", direction: .output)])
        ) { ctx in counter.hit("ticker"); return ["out": .double(Double(ctx.time.tick))] }

        // Impure, but constant output.
        pack.registry.register(NodeDefinition(
            typeID: "steady", displayName: "Steady", ports: [PortDefinition(id: "out", direction: .output)])
        ) { _ in counter.hit("steady"); return ["out": 1.0] }

        pack.registry.register(NodeDefinition(
            typeID: "pulser", displayName: "Pulser",
            ports: [PortDefinition(id: "out", direction: .output), PortDefinition(id: "fire", direction: .output, kind: .trigger)],
            isPure: true)
        ) { _ in counter.hit("pulser"); return NodeOutputs(["out": 1.0], triggers: ["fire"]) }
    }

    @discardableResult
    mutating func node(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:]) -> NodeID {
        pack.node(type, properties)
    }

    mutating func link(_ a: NodeID, _ b: NodeID, _ input: PortID = "in") { pack.link(a, "out", b, input) }

    func runner(caching: Bool = true) throws -> GraphRunner {
        try GraphRunner(graph: pack.graph, registry: pack.registry, caching: caching)
    }
}

@Test func pureNodesRunOnceThenComeFromTheCache() async throws {
    var c = CachePack()
    let src = c.node("src", ["value": 4.0]), twice = c.node("double")
    c.link(src, twice)
    let runner = try c.runner()
    let first = await runner.step()
    #expect(first.outputs(of: twice) == ["out": 8.0] && first.cachedNodes.isEmpty)
    for _ in 0..<3 {
        let again = await runner.step()
        #expect(again.outputs(of: twice) == ["out": 8.0])
        #expect(Set(again.cachedNodes) == [src, twice] && again.succeeded)
    }
    #expect(c.counter["src"] == 1 && c.counter["double"] == 1)
}

@Test func impureNodesAlwaysRun() async throws {
    var c = CachePack()
    let ticker = c.node("ticker"), twice = c.node("double")
    c.link(ticker, twice)
    let runner = try c.runner()
    var seen: [GraphValue?] = []
    for _ in 0..<3 { seen.append(await runner.step().outputs(of: twice)?["out"]) }
    #expect(seen == [0.0, 2.0, 4.0])
    #expect(c.counter["ticker"] == 3 && c.counter["double"] == 3)
}

@Test func anImpureNodeWithAnUnchangedOutputLetsPureNodesAfterItCache() async throws {
    var c = CachePack()
    let steady = c.node("steady"), twice = c.node("double")
    c.link(steady, twice)
    let runner = try c.runner()
    for _ in 0..<3 { _ = await runner.step() }
    #expect(c.counter["steady"] == 3 && c.counter["double"] == 1)
}

@Test func changingAPropertyReRunsOnlyWhatDependsOnIt() async throws {
    var c = CachePack()
    let a = c.node("src", ["value": 1.0]), b = c.node("src", ["value": 2.0])
    let doubleA = c.node("double"), doubleB = c.node("double")
    c.link(a, doubleA); c.link(b, doubleB)
    let runner = try c.runner()
    _ = await runner.step()

    var edited = c
    edited.pack.graph.insert(Node(id: a, typeID: "src", properties: ["value": 5.0]))
    try await runner.update(graph: edited.pack.graph, registry: edited.pack.registry)
    let tick = await runner.step()
    #expect(tick.outputs(of: doubleA) == ["out": 10.0] && tick.outputs(of: doubleB) == ["out": 4.0])
    #expect(Set(tick.cachedNodes) == [b, doubleB])
    #expect(c.counter["src"] == 3 && c.counter["double"] == 3)   // 2 + 1 re-run each
}

@Test func unchangedOutputsStopTheChainEarly() async throws {
    var c = CachePack()
    let src = c.node("src", ["value": 20.0]), clamp = c.node("clamp"), twice = c.node("double")
    c.link(src, clamp); c.link(clamp, twice)
    let runner = try c.runner()
    _ = await runner.step()

    var edited = c
    edited.pack.graph.insert(Node(id: src, typeID: "src", properties: ["value": 30.0]))   // still clamps to 10
    try await runner.update(graph: edited.pack.graph, registry: edited.pack.registry)
    let tick = await runner.step()
    #expect(tick.outputs(of: twice) == ["out": 20.0])
    #expect(tick.cachedNodes == [twice], "clamp re-ran, but its output was the same")
    #expect(c.counter["clamp"] == 2 && c.counter["double"] == 1)
}

@Test func addingOrRemovingALinkReRunsTheTarget() async throws {
    var c = CachePack()
    let src = c.node("src", ["value": 3.0]), twice = c.node("double")
    let runner = try c.runner()
    #expect(await runner.step().outputs(of: twice) == ["out": 0.0])

    var linked = c
    linked.link(src, twice)
    try await runner.update(graph: linked.pack.graph, registry: linked.pack.registry)
    #expect(await runner.step().outputs(of: twice) == ["out": 6.0])

    try await runner.update(graph: c.pack.graph, registry: c.pack.registry)
    #expect(await runner.step().outputs(of: twice) == ["out": 0.0])
    #expect(c.counter["double"] == 3)
}

@Test func cachingCanBeSwitchedOff() async throws {
    var c = CachePack()
    c.node("src", ["value": 1.0])
    let runner = try c.runner(caching: false)
    for _ in 0..<3 { #expect(await runner.step().cachedNodes.isEmpty) }
    #expect(c.counter["src"] == 3)
}

@Test func invalidationForcesARerun() async throws {
    var c = CachePack()
    let a = c.node("src", ["value": 1.0]), b = c.node("src", ["value": 2.0])
    let runner = try c.runner()
    _ = await runner.step()
    await runner.invalidate([a])
    let partial = await runner.step()
    #expect(partial.cachedNodes == [b] && c.counter["src"] == 3)
    await runner.invalidateAll()
    #expect(await runner.step().cachedNodes.isEmpty && c.counter["src"] == 5)
    _ = await runner.step()
    await runner.reset()
    #expect(await runner.step().cachedNodes.isEmpty, "reset clears the cache")
}

@Test func changingANodeDefinitionDropsItsCachedOutputs() async throws {
    var c = CachePack()
    let src = c.node("src", ["value": 1.0]), other = c.node("steady")
    let runner = try c.runner()
    _ = await runner.step()

    var changed = c
    var definition = try #require(changed.pack.registry.definition(for: "src"))
    definition.displayName = "Src v2"
    let counter = c.counter
    changed.pack.registry.register(definition) { ctx in counter.hit("src"); return ["out": try ctx.property("value")] }
    try await runner.update(graph: changed.pack.graph, registry: changed.pack.registry)
    let tick = await runner.step()
    #expect(!tick.cachedNodes.contains(src))
    #expect(c.counter["src"] == 2)
    _ = other
}

@Test func changingANodesTypeDropsItsCachedOutputs() async throws {
    var c = CachePack()
    let id = c.node("src", ["value": 1.0])
    let runner = try c.runner()
    _ = await runner.step()
    var swapped = c
    swapped.pack.graph.insert(Node(id: id, typeID: "pulser"))
    try await runner.update(graph: swapped.pack.graph, registry: swapped.pack.registry)
    let tick = await runner.step()
    #expect(tick.cachedNodes.isEmpty && tick.outputs(of: id)?["out"] == 1.0)
}

@Test func failuresAreNeverCached() async throws {
    var c = CachePack(failFirstDouble: true)
    let twice = c.node("double")
    let runner = try c.runner()
    #expect(await runner.step().failedNodes == [twice])
    let second = await runner.step()
    #expect(second.outputs(of: twice) == ["out": 0.0] && second.cachedNodes.isEmpty)
    #expect(await runner.step().cachedNodes == [twice])
    #expect(c.counter["double"] == 2)
}

@Test func cachedTriggersFireAgainLikeARealRunWould() async throws {
    var c = CachePack()
    c.pack.registry.register(NodeDefinition(
        typeID: "counter", displayName: "C", ports: [PortDefinition(id: "go", direction: .input, kind: .trigger), PortDefinition(id: "out", direction: .output)])
    ) { ctx in ["out": .bool(ctx.didTrigger("go"))] }
    let pulser = c.node("pulser"), listener = c.node("counter")
    c.pack.graph.insert(Link(sourceNode: pulser, sourcePort: "fire", targetNode: listener, targetPort: "go"))
    let runner = try c.runner()
    for _ in 0..<3 {
        let tick = await runner.step()
        #expect(tick.outputs(of: listener) == ["out": true])
    }
    #expect(c.counter["pulser"] == 1)
}

@Test func deterministicRunsGiveTheSameResultsWithAndWithoutTheCache() async throws {
    var c = CachePack()
    let src = c.node("src", ["value": 2.0]), ticker = c.node("ticker"), twice = c.node("double"), clamp = c.node("clamp")
    c.link(src, twice); c.link(twice, clamp)
    _ = ticker
    func outcomes(caching: Bool) async throws -> [[NodeID: GraphValue?]] {
        let ticks = await collect(try c.runner(caching: caching).run(.deterministic(fixedDelta: .milliseconds(1), ticks: 4)), count: 99)
        return ticks.map { t in Dictionary(uniqueKeysWithValues: t.results.map { ($0.key, $0.value.outputs?["out"]) }) }
    }
    #expect(try await outcomes(caching: true) == outcomes(caching: false))
}

// MARK: Execution events

/// Reads events until the end of the first pass `count` passes have finished.
private func events(_ stream: AsyncStream<ExecutionEvent>, passes: Int = 1) async -> [ExecutionEvent] {
    var all: [ExecutionEvent] = [], finished = 0
    for await event in stream {
        all.append(event)
        if case .passFinished = event { finished += 1 }
        if finished == passes { break }
    }
    return all
}

@Test func eventsBracketAPassAndAnnounceEachNodeOnce() async throws {
    var p = Pack()
    let a = p.node("const", ["value": 1.0]), b = p.node("pass"), c = p.node("const", mode: .muted)
    p.link(a, "out", b, "in")
    let runner = try p.runner()
    let stream = runner.events()
    _ = await runner.step()
    let seen = await events(stream)

    guard case .passStarted(let tick, _) = seen.first, case .passFinished(let endTick, _, let cancelled) = seen.last else {
        Issue.record("pass not bracketed: \(seen)"); return
    }
    #expect(tick == 0 && endTick == 0 && !cancelled)
    let finished = seen.compactMap { event -> (NodeID, NodeRunStatus)? in
        if case .nodeFinished(let node, _, let status, _) = event { (node, status) } else { nil }
    }
    #expect(Set(finished.map(\.0)) == [a, b, c] && finished.count == 3)
    #expect(finished.first { $0.0 == c }?.1 == .skipped(.muted))
    #expect(finished.first { $0.0 == a }?.1 == .succeeded)

    // Executed nodes start before they finish; muted nodes never start.
    let index = { (match: (ExecutionEvent) -> Bool) in seen.firstIndex(where: match)! }
    #expect(index { $0 == .nodeStarted(node: a, tick: 0) } < index { if case .nodeFinished(a, _, _, _) = $0 { true } else { false } })
    #expect(!seen.contains(.nodeStarted(node: c, tick: 0)))
}

@Test func failuresCachingAndBypassAreReportedInTheirEvents() async throws {
    var c = CachePack()
    let src = c.node("src", ["value": 1.0]), bad = c.pack.node("fail"), after = c.pack.node("pass")
    c.pack.link(bad, "out", after, "in")
    _ = src
    let runner = try c.runner()
    let stream = runner.events()
    _ = await runner.step(); _ = await runner.step()
    let seen = await events(stream, passes: 2)
    let statuses = seen.compactMap { event -> (Int, NodeID, NodeRunStatus)? in
        if case .nodeFinished(let node, let tick, let status, _) = event { (tick, node, status) } else { nil }
    }
    #expect(statuses.contains { $0.0 == 0 && $0.1 == bad && $0.2 == .failed(message: "failed(\"boom\")") })
    #expect(statuses.contains { $0.0 == 0 && $0.1 == after && $0.2 == .skipped(.upstreamFailed) })
    #expect(statuses.contains { $0.0 == 1 && $0.1 == src && $0.2 == .cached })
}

@Test func progressArrivesBetweenStartAndFinish() async throws {
    var p = Pack()
    p.registry.register(NodeDefinition(
        typeID: "work", displayName: "Work", ports: [PortDefinition(id: "out", direction: .output)])
    ) { ctx in
        ctx.reportProgress(0.25, message: "a quarter")
        ctx.reportProgress(1)
        return [:]
    }
    let work = p.node("work")
    let runner = try p.runner()
    let stream = runner.events()
    _ = await runner.step()
    let seen = await events(stream)
    let ofNode = seen.filter {
        switch $0 {
        case .nodeStarted(let n, _), .nodeFinished(let n, _, _, _): n == work
        case .nodeProgress(let p): p.node == work
        default: false
        }
    }
    #expect(ofNode.count == 4)
    #expect(ofNode[1] == .nodeProgress(NodeProgress(node: work, fraction: 0.25, message: "a quarter")))
    if case .nodeProgress(let last) = ofNode[2] { #expect(last.fraction == 1) } else { Issue.record("expected progress") }
}

@Test func theStateTrackerFollowsEvents() async throws {
    var p = Pack()
    let wait = p.node("wait")
    let runner = try p.runner()
    let stream = runner.events()
    let task = Task { await runner.step() }

    var state = ExecutionState()
    var sawRunning = false
    for await event in stream {
        state.apply(event)
        if case .running = state[wait] {
            sawRunning = true
            #expect(state.isRunning)
            task.cancel()
        }
        if case .passFinished = event { break }
    }
    _ = await task.value
    #expect(sawRunning)
    #expect(!state.isRunning && state.wasCancelled && state.tick == 0)
    if case .finished(.cancelled, _) = state[wait] {} else { Issue.record("expected the waiting node to finish cancelled") }
}

@Test func theStateTrackerReducesEventsDirectly() {
    let node = NodeID(), other = NodeID()
    var state = ExecutionState()
    #expect(state[node] == .idle && !state.isRunning && state.tick == nil)
    state.apply(.passStarted(tick: 3, time: ExecutionTime(tick: 3)))
    state.apply(.nodeProgress(NodeProgress(node: node, fraction: 0.5, message: nil)))   // ignored: not running
    #expect(state[node] == .idle && state.isRunning && state.tick == 3)
    state.apply(.nodeStarted(node: node, tick: 3))
    #expect(state[node] == .running(progress: nil, message: nil))
    state.apply(.nodeProgress(NodeProgress(node: node, fraction: 0.5, message: "half")))
    #expect(state[node] == .running(progress: 0.5, message: "half"))
    state.apply(.nodeFinished(node: node, tick: 3, status: .succeeded, duration: .seconds(1)))
    state.apply(.nodeFinished(node: other, tick: 3, status: .cached, duration: .zero))
    state.apply(.passFinished(tick: 3, duration: .seconds(2), wasCancelled: false))
    #expect(state[node] == .finished(.succeeded, duration: .seconds(1)) && !state.isRunning)
    // A new pass keeps the last known results until a node is reached again.
    state.apply(.passStarted(tick: 4, time: ExecutionTime(tick: 4)))
    #expect(state[node] == .finished(.succeeded, duration: .seconds(1)))
    state.prune(keeping: [other])
    #expect(state[node] == .idle && state[other] != .idle)
}

@Test func everySubscriberGetsEveryEventAndNobodyIsRequired() async throws {
    var p = Pack()
    p.node("const", ["value": 1.0])
    let runner = try p.runner()
    _ = await runner.step()                    // nobody listening: must not fail or leak
    let first = runner.events(), second = runner.events()
    _ = await runner.step()
    let a = await events(first), b = await events(second)
    #expect(a == b && !a.isEmpty)
}

@Test func eventsEndWhenTheRunnerIsReleased() async throws {
    var p = Pack()
    p.node("const", ["value": 1.0])
    var runner: GraphRunner? = try p.runner()
    let stream = runner!.events()
    runner = nil
    var count = 0
    for await _ in stream { count += 1 }       // returns because the stream finished
    #expect(count == 0)
}

@Test func cancelledPassesReportCancelledNodesAndTheCancelledFlag() async throws {
    var p = Pack()
    let waiting = p.node("wait"), after = p.node("pass")
    p.link(waiting, "out", after, "in")
    let runner = try p.runner()
    let stream = runner.events()
    let task = Task { await runner.step() }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let seen = await events(stream)
    _ = await task.value
    #expect(seen.contains { if case .passFinished(_, _, true) = $0 { true } else { false } })
    let cancelled = seen.compactMap { event -> NodeID? in
        if case .nodeFinished(let n, _, .cancelled, _) = event { n } else { nil }
    }
    #expect(Set(cancelled) == [waiting, after])
}

@Test func statusMatchesEveryOutcome() {
    let id = NodeID()
    func status(_ outcome: NodeRunResult.Outcome) -> NodeRunStatus {
        NodeRunResult(node: id, outcome: outcome, duration: .zero).status
    }
    #expect(status(.success(.empty)) == .succeeded)
    #expect(status(.failure(NodeFailure(message: "x"))) == .failed(message: "x"))
    #expect(status(.cancelled) == .cancelled)
    #expect(status(.skipped(.muted)) == .skipped(.muted))
    #expect(status(.bypassed(.empty)) == .bypassed)
    #expect(status(.cached(.empty)) == .cached)
}
