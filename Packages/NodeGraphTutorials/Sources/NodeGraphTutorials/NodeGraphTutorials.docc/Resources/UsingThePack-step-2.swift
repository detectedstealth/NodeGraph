import NodeGraphCore
import NodeGraphNodes

/// An editor with the built-in nodes and the temperature pack side by side.
func makeEditorWithTemperatures() -> GraphEditor {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    TemperaturePack.register(nodes: &nodes, types: &types)
    return GraphEditor(nodes: nodes, types: types)
}

/// Feeds a sensor into a built-in math node. Temperatures count as numbers, so this is allowed.
func addSensorToANumber() throws -> GraphEditor {
    let editor = makeEditorWithTemperatures()
    let sensor = Node(typeID: "temperature.sensor", properties: ["celsius": 21.5])
    let add = Node(typeID: "math.add")
    try editor.apply(.addNode(node: sensor))
    try editor.apply(.addNode(node: add))
    try editor.apply(.addLink(link: Link(
        sourceNode: sensor.id, sourcePort: "value", targetNode: add.id, targetPort: "a")))
    return editor
}
