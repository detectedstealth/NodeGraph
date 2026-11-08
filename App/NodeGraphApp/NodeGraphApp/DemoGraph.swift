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
        // Watch nodes show the value they pass on, from the latest run.
        model.registerContentDrawing(for: "util.watch", .readout(of: "result"))

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
        for (id, value) in [(a, 3.0), (b, 4.0), (scale, 2.5)] {
            _ = try? model.perform(.setNodeProperty(node: id, property: "value", value: .double(value)))
        }
        link(a, sum, input: 0)
        link(b, sum, input: 1)
        link(sum, product, input: 0)
        link(scale, product, input: 1)
        link(product, compare, input: 0)
        link(a, sine)
        let sineWatch = add("util.watch", 820, -80)
        link(sine, sineWatch)
        let time = add("util.time", 0, -200)
        let timeWatch = add("util.watch", 300, -200, title: "Elapsed")
        link(time, timeWatch)
        // A graph variable, read by a Variable node. Edit it in the inspector with nothing selected.
        if let name = model.addVariable(named: "gain", kind: .number) {
            model.setVariable(name, to: .double(2.5))
            let read = add("util.variable", 560, -260, title: "Gain")
            _ = try? model.perform(.setNodeProperty(node: read, property: "name", value: .string(name)))
            let gainWatch = add("util.watch", 820, -260)
            link(read, gainWatch)
        }
        // A few nodes drawn differently, to show shapes and title bar styles.
        _ = try? model.perform(.setNodeAttribute(node: compare, attribute: .shape(value: .card)))
        _ = try? model.perform(.setNodeAttribute(node: timeWatch, attribute: .shape(value: .box)))
        _ = try? model.perform(.setNodeAttribute(node: timeWatch, attribute: .titleMode(value: .transparent)))
        _ = try? model.perform(.setNodeAttribute(node: sineWatch, attribute: .titleMode(value: .autohide)))
        _ = try? model.perform(.addGroup(group: NodeGroup(
            title: "Arithmetic", bounds: GraphRect(x: 270, y: -20, width: 480, height: 300))))
        // Turn the sum and the product into a subgraph, so there is one to open.
        if let conversion = try? model.editor.convertToSubgraphCommand(nodes: [sum, product], name: "Sum Times Scale") {
            _ = try? model.perform(conversion.command)
        }
        model.history.clear()
        return model
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
