import NodeGraphCore
import NodeGraphNodes

/// Makes an editor that knows every built-in node type.
func makeEditor() -> GraphEditor {
    var nodes = NodeRegistry()
    var types = TypeRegistry()
    StandardPack.register(nodes: &nodes, types: &types)
    return GraphEditor(nodes: nodes, types: types)
}

/// Builds a graph that adds two numbers.
func makeAdditionGraph() throws -> GraphEditor {
    let editor = makeEditor()

    let first = Node(typeID: "util.number", position: GraphPoint(x: 0, y: 0), properties: ["value": 2.0])
    let second = Node(typeID: "util.number", position: GraphPoint(x: 0, y: 120), properties: ["value": 3.0])
    let add = Node(typeID: "math.add", position: GraphPoint(x: 260, y: 60))
    try editor.apply(.addNode(node: first))
    try editor.apply(.addNode(node: second))
    try editor.apply(.addNode(node: add))

    try editor.apply(.addLink(link: Link(
        sourceNode: first.id, sourcePort: "value", targetNode: add.id, targetPort: "a")))
    try editor.apply(.addLink(link: Link(
        sourceNode: second.id, sourcePort: "value", targetNode: add.id, targetPort: "b")))

    // Change your mind about the second number: 2 + 4 instead of 2 + 3.
    try editor.apply(.setNodeProperty(node: second.id, property: "value", value: 4.0))

    return editor
}
