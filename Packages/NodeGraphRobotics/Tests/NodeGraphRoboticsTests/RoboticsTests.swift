import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphRobotics

// MARK: Helpers

private let registries = RoboticsPack.makeRegistries()

/// One pass of one node, with the state it returned last time passed back in.
private struct Bench {
    var node: Node
    var state: GraphValue?
    var tick = 0
    var step: Duration = .milliseconds(10)

    init(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:], step: Duration = .milliseconds(10)) {
        node = Node(typeID: type, properties: properties)
        self.step = step
    }

    @discardableResult
    mutating func run(_ inputs: [PortID: GraphValue] = [:], triggered: Set<PortID> = []) async throws -> NodeOutputs {
        let definition = try #require(registries.nodes.definition(for: node))
        let time = ExecutionTime(
            tick: tick, elapsed: step * tick, delta: tick == 0 ? .zero : step)
        let context = NodeContext(
            node: node, definition: definition, linkedInputs: inputs, triggered: triggered, time: time, state: state)
        let result = await NodeInvocation.run(node: node, registry: registries.nodes, context: context)
        tick += 1
        guard case .success(let outputs) = result.outcome else {
            Issue.record("\(node.typeID) did not succeed: \(result.outcome)")
            return .empty
        }
        state = outputs.state
        return outputs
    }

    mutating func number(_ port: PortID, _ inputs: [PortID: GraphValue] = [:]) async throws -> Double {
        try #require(await run(inputs).values[port]?.numberValue)
    }
}

private func failure(_ type: NodeTypeID, _ inputs: [PortID: GraphValue] = [:], properties: [PropertyID: GraphValue] = [:]) async throws -> String? {
    let node = Node(typeID: type, properties: properties)
    let definition = try #require(registries.nodes.definition(for: node))
    let context = NodeContext(node: node, definition: definition, linkedInputs: inputs)
    let result = await NodeInvocation.run(node: node, registry: registries.nodes, context: context)
    if case .failure(let failure) = result.outcome { return failure.message } else { return nil }
}

private struct Rig {
    let editor = GraphEditor(nodes: registries.nodes, types: registries.types)

    @discardableResult
    func add(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:]) throws -> NodeID {
        let node = Node(typeID: type, properties: properties)
        try editor.apply(.addNode(node: node))
        return node.id
    }

    func link(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: a, port: out, direction: .output),
            target: PortAddress(node: b, port: input, direction: .input)))
    }

    func scenario(ticks: Int, probes: [ScenarioProbe]) async throws -> ScenarioTrace {
        try await FixedStepScenario.run(
            graph: editor.graph, registry: editor.nodes, step: .milliseconds(10), ticks: ticks, probes: probes)
    }
}

// MARK: Signal source

@Test func sineStartsAtZeroAndPeaksAtAQuarterPeriod() async throws {
    var bench = Bench("robotics.signal", ["amplitude": 2.0, "frequency": 1.0], step: .milliseconds(250))
    #expect(try await bench.number("value") == 0)
    #expect(abs(try await bench.number("value") - 2) < 1e-12)
}

@Test(arguments: [
    ("square", [1.0, 1.0, -1.0, -1.0]),
    ("triangle", [0.0, 1.0, 0.0, -1.0]),
    ("sawtooth", [-1.0, -0.5, 0.0, 0.5]),
    ("constant", [1.0, 1.0, 1.0, 1.0]),
])
func waveformsAtQuarterPeriods(_ name: String, _ expected: [Double]) async throws {
    var bench = Bench("robotics.signal", ["waveform": .string(name)], step: .milliseconds(250))
    for want in expected {
        #expect(abs(try await bench.number("value") - want) < 1e-12, "\(name) wanted \(want)")
    }
}

@Test func noiseRepeatsForASeedAndStaysWithinItsAmplitude() async throws {
    func readings(seed: Int64) async throws -> [Double] {
        var bench = Bench("robotics.signal", ["waveform": "constant", "amplitude": 0.0, "noise": 0.5, "seed": .int(seed)])
        var values: [Double] = []
        for _ in 0..<50 { values.append(try await bench.number("value")) }
        return values
    }
    let a = try await readings(seed: 7), b = try await readings(seed: 7), c = try await readings(seed: 8)
    #expect(a == b)
    #expect(a != c)
    #expect(a.allSatisfy { abs($0) <= 0.5 })
    #expect(Set(a).count > 40)
}

@Test func unknownWaveformFails() async throws {
    #expect(try await failure("robotics.signal", properties: ["waveform": "wobble"]) == "Unknown waveform wobble")
}

// MARK: Filters

@Test func lowPassPassesTheFirstSampleThenApproachesAStep() async throws {
    var bench = Bench("robotics.lowPass", ["tau": 0.1])
    #expect(try await bench.number("result", ["value": 0.0]) == 0)
    // One step of dt / (tau + dt) = 0.01 / 0.11.
    let first = try await bench.number("result", ["value": 1.0])
    #expect(abs(first - 0.01 / 0.11) < 1e-12)
    var last = first
    for _ in 0..<200 { last = try await bench.number("result", ["value": 1.0]) }
    #expect(abs(last - 1) < 1e-3)
}

@Test func lowPassWithZeroTauFollowsTheInputAndNegativeTauFails() async throws {
    var bench = Bench("robotics.lowPass", ["tau": 0.0])
    _ = try await bench.number("result", ["value": 0.0])
    #expect(try await bench.number("result", ["value": 3.0]) == 3)
    #expect(try await failure("robotics.lowPass", properties: ["tau": -1.0]) == "Time constant must not be negative")
}

@Test func rateLimiterMovesAtMostRateTimesStep() async throws {
    var bench = Bench("robotics.rateLimit", ["maxRate": 2.0])
    #expect(try await bench.number("result", ["value": 0.0]) == 0)
    // 2 units per second at 10 ms is 0.02 per pass.
    #expect(abs(try await bench.number("result", ["value": 1.0]) - 0.02) < 1e-12)
    #expect(abs(try await bench.number("result", ["value": 1.0]) - 0.04) < 1e-12)
    #expect(abs(try await bench.number("result", ["value": -1.0]) - 0.02) < 1e-12)
    bench.node.properties["maxRate"] = 0.0
    #expect(try await bench.number("result", ["value": 9.0]) == 9)
    #expect(try await failure("robotics.rateLimit", properties: ["maxRate": -1.0]) == "Maximum rate must not be negative")
}

@Test func deadbandZeroesSmallValues() async throws {
    var bench = Bench("robotics.deadband", ["width": 0.05])
    #expect(try await bench.number("result", ["value": 0.04]) == 0)
    #expect(try await bench.number("result", ["value": -0.05]) == 0)
    #expect(try await bench.number("result", ["value": 0.06]) == 0.06)
}

@Test func thresholdHoldsBetweenItsEdgesAndFiresOnChanges() async throws {
    var bench = Bench("robotics.threshold", ["high": 0.6, "low": 0.4])
    func feed(_ value: Double) async throws -> (active: Bool, rose: Bool, fell: Bool) {
        let out = try await bench.run(["value": .double(value)])
        return (out.values["active"]?.boolValue ?? false, out.triggers.contains("rose"), out.triggers.contains("fell"))
    }
    #expect(try await feed(0.5) == (false, false, false))
    #expect(try await feed(0.7) == (true, true, false))
    #expect(try await feed(0.5) == (true, false, false))
    #expect(try await feed(0.45) == (true, false, false))
    #expect(try await feed(0.3) == (false, false, true))
    #expect(try await feed(0.5) == (false, false, false))
    #expect(try await failure("robotics.threshold", properties: ["high": 0.1, "low": 0.2]) == "Low must not be above high")
}

// MARK: PID

@Test func pidProportionalIntegralAndDerivativeTerms() async throws {
    var bench = Bench("robotics.pid", ["kp": 2.0, "ki": 10.0, "kd": 0.5, "min": -100.0, "max": 100.0])
    func pass(setpoint: Double, measurement: Double) async throws -> NodeOutputs {
        try await bench.run(["setpoint": .double(setpoint), "measurement": .double(measurement)])
    }
    // First pass: proportional only, nothing to integrate or differentiate yet.
    #expect(try await pass(setpoint: 1, measurement: 0).values["output"] == .double(2))
    // Error 1 for 10 ms: P = 2, I = 10 * 1 * 0.01 = 0.1, D = 0 (measurement unchanged).
    let second = try await pass(setpoint: 1, measurement: 0)
    #expect(abs((second.values["output"]?.numberValue ?? 0) - 2.1) < 1e-12)
    // Measurement rises by 0.1 in 10 ms: error 0.9, P = 1.8, I = 0.1 + 0.09, D = -0.5 * 10 = -5.
    let third = try await pass(setpoint: 1, measurement: 0.1)
    #expect(abs((third.values["output"]?.numberValue ?? 0) - (1.8 + 0.19 - 5)) < 1e-9)
    #expect(third.values["error"] == .double(0.9))
}

@Test func pidDoesNotKickWhenTheSetpointSteps() async throws {
    var bench = Bench("robotics.pid", ["kp": 0.0, "kd": 1.0, "min": -100.0, "max": 100.0])
    let inputs: (Double) -> [PortID: GraphValue] = { ["setpoint": .double($0), "measurement": 0.0] }
    _ = try await bench.run(inputs(0))
    _ = try await bench.run(inputs(0))
    #expect(try await bench.number("output", inputs(50)) == 0)
}

@Test func pidIntegralDoesNotWindUpWhileSaturated() async throws {
    var bench = Bench("robotics.pid", ["kp": 1.0, "ki": 5.0, "min": -1.0, "max": 1.0])
    let saturated: [PortID: GraphValue] = ["setpoint": 10.0, "measurement": 0.0]
    for _ in 0..<500 { _ = try await bench.run(saturated) }
    #expect(try await bench.number("output", saturated) == 1)
    // The error flips sign; an integral that had wound up for 5 seconds would hold the output at 1.
    var flipped = saturated
    flipped["setpoint"] = -10.0
    let out = try await bench.number("output", flipped)
    #expect(out < 0, "output \(out) shows wound-up integral")
}

@Test func pidResetClearsItsMemoryAndRejectsBadLimits() async throws {
    var bench = Bench("robotics.pid", ["kp": 0.0, "ki": 1.0])
    let inputs: [PortID: GraphValue] = ["setpoint": 1.0, "measurement": 0.0]
    for _ in 0..<20 { _ = try await bench.run(inputs) }
    #expect(try await bench.number("output", inputs) > 0.15)
    let cleared = try await bench.run(inputs, triggered: ["reset"])
    #expect(cleared.values["output"] == .double(0))
    #expect(try await failure("robotics.pid", properties: ["min": 1.0, "max": 0.0]) == "Min must not be above max")
}

// MARK: State machine

private func machine(_ transitions: String? = nil) -> Bench {
    var properties: [PropertyID: GraphValue] = [:]
    if let transitions { properties["transitions"] = .string(transitions) }
    return Bench("robotics.stateMachine", properties)
}

@Test func stateMachineStartsInTheInitialStateAndFollowsEvents() async throws {
    var bench = machine()
    #expect(try await bench.run().values["state"] == "idle")
    let started = try await bench.run(["event": "start"])
    #expect(started.values["state"] == "running" && started.triggers == ["changed"])
    // An event with no line for the current state, or none at all, changes nothing.
    let ignored = try await bench.run(["event": "start"])
    #expect(ignored.values["state"] == "running" && ignored.triggers.isEmpty)
    #expect(try await bench.run(["event": "stop"]).values["state"] == "idle")
}

@Test func stateMachineCountsTimeInState() async throws {
    var bench = machine()
    _ = try await bench.run()
    _ = try await bench.run(["event": "start"])
    for _ in 0..<4 { _ = try await bench.run() }
    let out = try await bench.run()
    #expect(abs((out.values["seconds"]?.numberValue ?? 0) - 0.05) < 1e-12)
}

@Test func stateMachineWildcardsCommentsAndFirstMatch() async throws {
    var bench = machine("""
        # a small cell
        idle go -> a      # first match wins
        idle go -> b
        * halt -> stopped
        """)
    #expect(try await bench.run(["event": "go"]).values["state"] == "a")
    #expect(try await bench.run(["event": "halt"]).values["state"] == "stopped")
}

@Test func stateMachineAcceptsSeveralEventsAndResets() async throws {
    var bench = machine()
    #expect(try await bench.run(["event": .array(["", "start"])]).values["state"] == "running")
    let reset = try await bench.run(triggered: ["reset"])
    #expect(reset.values["state"] == "idle" && reset.triggers == ["changed"])
    #expect(try await bench.run(triggered: ["reset"]).triggers.isEmpty)
}

@Test func stateMachineReportsABadTableWithItsLine() async throws {
    #expect(try await failure("robotics.stateMachine", properties: ["transitions": "idle start -> a\nnonsense"])
        == "Line 2: expected \"from event -> to\"")
    #expect(try await failure("robotics.stateMachine", properties: ["initial": "has space"])
        == "The initial state needs a name without spaces")
}

@Test func eventNodeNamesATriggerOnlyWhenItFires() async throws {
    var bench = Bench("robotics.event", ["name": "start"])
    #expect(try await bench.run(triggered: ["trigger"]).values["event"] == "start")
    #expect(try await bench.run().values["event"] == "")
}

// MARK: Actuator and plant

@Test func actuatorLimitsRangeAndSpeedAndFallsBackToTheSafeValue() async throws {
    var bench = Bench("robotics.actuator", ["min": -1.0, "max": 1.0, "maxRate": 10.0, "safe": 0.25])
    let first = try await bench.run(["command": 5.0])
    // The first command has nothing to be rate limited against, so only the range applies.
    #expect(first.values["applied"] == .double(1) && first.values["limited"] == .bool(true))
    let slewed = try await bench.run(["command": -5.0])
    #expect(abs((slewed.values["applied"]?.numberValue ?? 0) - 0.9) < 1e-12)
    let within = try await bench.run(["command": 0.88])
    #expect(within.values["applied"] == .double(0.88) && within.values["limited"] == .bool(false))
    let stopped = try await bench.run(["command": 1.0, "enabled": false])
    #expect(stopped.values["applied"] == .double(0.25) && stopped.values["limited"] == .bool(false))
}

@Test func actuatorRejectsReversedLimits() async throws {
    #expect(try await failure("robotics.actuator", properties: ["min": 1.0, "max": -1.0]) == "Minimum must not be above maximum")
}

@Test func plantMovesTowardGainTimesInputAtTheRightRate() async throws {
    var bench = Bench("robotics.plant", ["gain": 2.0, "tau": 0.5], step: .milliseconds(500))
    #expect(try await bench.number("output", ["input": 1.0]) == 0)
    // One time constant covers 1 - 1/e of the way to the target of 2.
    #expect(abs(try await bench.number("output", ["input": 1.0]) - 2 * (1 - exp(-1))) < 1e-12)
}

// MARK: Scenarios

/// setpoint -> PID -> actuator -> plant -> (next pass) PID measurement.
private struct ControlLoop {
    let rig = Rig()
    let plant: NodeID, actuator: NodeID, pid: NodeID

    init(setpoint: Double = 1) throws {
        let source = try rig.add("robotics.signal", ["waveform": "constant", "amplitude": .double(setpoint)])
        pid = try rig.add("robotics.pid", ["kp": 4.0, "ki": 4.0, "min": -5.0, "max": 5.0])
        actuator = try rig.add("robotics.actuator", ["min": -2.0, "max": 2.0])
        plant = try rig.add("robotics.plant", ["gain": 1.0, "tau": 0.5])
        try rig.link(source, "value", pid, "setpoint")
        try rig.link(plant, "output", pid, "measurement")
        try rig.link(pid, "output", actuator, "command")
        try rig.link(actuator, "applied", plant, "input")
    }
}

@Test func aPIDLoopSettlesOnTheSetpoint() async throws {
    let loop = try ControlLoop()
    let measured = ScenarioProbe(node: loop.plant, port: "output")
    let trace = try await loop.rig.scenario(ticks: 1500, probes: [measured])
    #expect(trace.succeeded)
    #expect(trace.times.count == 1500)
    let readings = trace.numbers(measured).compactMap { $0 }
    #expect(abs((readings.last ?? 0) - 1) < 0.01)
    // The command is limited to 2, so the plant cannot overshoot beyond a modest bound.
    #expect((readings.max() ?? 0) < 1.5)
}

@Test func theActuatorBoundsTheCommandInTheLoop() async throws {
    let loop = try ControlLoop(setpoint: 10)
    let applied = ScenarioProbe(node: loop.actuator, port: "applied")
    let trace = try await loop.rig.scenario(ticks: 300, probes: [applied])
    let commands = trace.numbers(applied).compactMap { $0 }
    #expect(commands.allSatisfy { abs($0) <= 2 })
    #expect(commands.last == 2)
}

@Test func scenariosAreReproducible() async throws {
    let rig = Rig()
    let source = try rig.add("robotics.signal", ["frequency": 2.0, "noise": 0.2, "seed": 3])
    let filter = try rig.add("robotics.lowPass", ["tau": 0.05])
    try rig.link(source, "value", filter, "value")
    let probe = ScenarioProbe(node: filter, port: "result")
    let first = try await rig.scenario(ticks: 200, probes: [probe])
    let second = try await rig.scenario(ticks: 200, probes: [probe])
    #expect(first.series == second.series)
    #expect(first.numbers(probe).contains { ($0 ?? 0) != 0 })
}

@Test func aStateMachineDrivenByAThresholdRunsASequence() async throws {
    // A ramp crosses the threshold, which raises a "start" event: idle -> running.
    let rig = Rig()
    let ramp = try rig.add("robotics.signal", ["waveform": "sawtooth", "frequency": 0.5])
    let threshold = try rig.add("robotics.threshold", ["low": 0.0, "high": 0.5])
    let event = try rig.add("robotics.event", ["name": "start"])
    let machine = try rig.add("robotics.stateMachine")
    try rig.link(ramp, "value", threshold, "value")
    try rig.link(threshold, "rose", event, "trigger")
    try rig.link(event, "event", machine, "event")
    let state = ScenarioProbe(node: machine, port: "state")
    let trace = try await rig.scenario(ticks: 300, probes: [state])
    let states = (trace.series[state] ?? []).compactMap { $0?.stringValue }
    #expect(states.first == "idle" && states.last == "running")
    // The sawtooth passes 0.5 at one quarter of its 2 s period, tick 150 at 10 ms.
    let changeAt = try #require(states.firstIndex(of: "running"))
    #expect((149...152).contains(changeAt))
}
