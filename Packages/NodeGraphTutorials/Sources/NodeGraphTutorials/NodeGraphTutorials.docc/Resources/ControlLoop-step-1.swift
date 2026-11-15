import NodeGraphCore
import NodeGraphRobotics

/// An editor that knows the built-in nodes and the robotics pack.
func makeRoboticsEditor() -> GraphEditor {
    let registries = RoboticsPack.makeRegistries()
    return GraphEditor(nodes: registries.nodes, types: registries.types)
}
