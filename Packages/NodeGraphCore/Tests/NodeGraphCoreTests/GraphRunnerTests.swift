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
    mutating func node(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:]) -> NodeID {
        let node = Node(typeID: type, properties: properties)
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
