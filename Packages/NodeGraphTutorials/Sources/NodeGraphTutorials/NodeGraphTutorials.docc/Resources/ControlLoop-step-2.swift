import NodeGraphCore
import NodeGraphRobotics

/// An editor that knows the built-in nodes and the robotics pack.
func makeRoboticsEditor() -> GraphEditor {
    let registries = RoboticsPack.makeRegistries()
    return GraphEditor(nodes: registries.nodes, types: registries.types)
}

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

    return plant.id
}
