//# step 1
import NodeGraphCore
import NodeGraphRobotics

/// An editor that knows the built-in nodes and the robotics pack.
func makeRoboticsEditor() -> GraphEditor {
    let registries = RoboticsPack.makeRegistries()
    return GraphEditor(nodes: registries.nodes, types: registries.types)
}
//# step 2

/// Adds a controller and the machine it controls, and returns the machine's node.
///
/// The setpoint feeds a PID controller. Its command goes through an actuator, which limits what
/// the hardware can do, to a first-order plant: a simulated machine that moves toward its input.
func addControlLoop(
    to editor: GraphEditor, setpoint: Double, kp: Double = 4, ki: Double = 4
) throws -> NodeID {
    let source = Node(typeID: "robotics.signal", properties: ["waveform": "constant", "amplitude": .double(setpoint)])
    let pid = Node(typeID: "robotics.pid", properties: ["kp": .double(kp), "ki": .double(ki), "min": -5.0, "max": 5.0])
    let actuator = Node(typeID: "robotics.actuator", properties: ["min": -2.0, "max": 2.0])
    let plant = Node(typeID: "robotics.plant", properties: ["gain": 1.0, "tau": 0.5])
    for node in [source, pid, actuator, plant] {
        try editor.apply(.addNode(node: node))
    }
//# step 3

    func link(_ from: Node, _ output: PortID, _ to: Node, _ input: PortID) throws {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: from.id, port: output, direction: .output),
            target: PortAddress(node: to.id, port: input, direction: .input)))
    }
    try link(source, "value", pid, "setpoint")
    try link(pid, "output", actuator, "command")
    try link(actuator, "applied", plant, "input")
    // The loop closes here: what the plant reached is what the controller measures next pass.
    try link(plant, "output", pid, "measurement")
//# step 2

    return plant.id
}
//# step 4

/// Simulates `seconds` of the loop in steps of 10 ms and returns the plant's output at each step.
///
/// The scenario runner uses simulated time, not the clock, so it is as fast as the computer
/// allows and gives the same numbers on every machine.
func simulate(_ editor: GraphEditor, plant: NodeID, seconds: Double) async throws -> [Double] {
    let reading = ScenarioProbe(node: plant, port: "output")
    let trace = try await FixedStepScenario.run(
        graph: editor.graph, registry: editor.nodes,
        step: .milliseconds(10), ticks: Int(seconds * 100), probes: [reading])
    return trace.numbers(reading).compactMap { $0 }
}
//# step 5

/// How far the loop went past its target, and how far it ended from it.
func overshootAndFinalError(of readings: [Double], target: Double) -> (overshoot: Double, finalError: Double) {
    let highest = readings.max() ?? 0
    return (max(0, highest - target), abs((readings.last ?? 0) - target))
}
