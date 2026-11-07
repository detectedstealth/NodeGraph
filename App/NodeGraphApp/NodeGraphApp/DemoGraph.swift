import NodeGraphCore
import NodeGraphNodes
import NodeGraphUI

/// A small graph from the built-in packs, so the canvas has something to show until documents
/// are wired in (Phase 6).
@MainActor
enum DemoGraph {
    static func makeModel() -> GraphEditorModel {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        let editor = GraphEditor(nodes: nodes, types: types)
        let model = GraphEditorModel(editor: editor)

        func add(_ type: String, _ x: Double, _ y: Double, title: String? = nil) -> NodeID {
            let node = Node(typeID: NodeTypeID(type), position: GraphPoint(x: x, y: y), title: title)
            _ = try? model.perform(.addNode(node: node))
            return node.id
        }
        // Connects the first output of `from` to the input of `to` at `index`.
        func link(_ from: NodeID, _ to: NodeID, input index: Int = 0) {
            guard let source = model.layout(of: from)?.outputs.first,
                  let target = model.layout(of: to)?.inputs[safe: index] else { return }
            _ = try? model.connect(ConnectionProposal(source: source.address, target: target.address))
        }

        let a = add("util.number", 0, 0, title: "A")
        let b = add("util.number", 0, 140, title: "B")
        let sum = add("math.add", 300, 40)
        let scale = add("util.number", 300, 200, title: "Scale")
        let product = add("math.multiply", 560, 100)
        let compare = add("logic.compare", 820, 80)
        let sine = add("math.sin", 560, -80)
        link(a, sum, input: 0)
        link(b, sum, input: 1)
        link(sum, product, input: 0)
        link(scale, product, input: 1)
        link(product, compare, input: 0)
        link(a, sine)
        _ = try? model.perform(.addGroup(group: NodeGroup(
            title: "Arithmetic", bounds: GraphRect(x: 270, y: -20, width: 480, height: 300))))
        model.history.clear()
        return model
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
