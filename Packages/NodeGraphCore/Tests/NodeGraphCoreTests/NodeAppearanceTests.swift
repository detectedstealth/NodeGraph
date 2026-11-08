import Foundation
import Testing
@testable import NodeGraphCore

@Suite struct NodeAppearanceTests {
    private func editor() throws -> (GraphEditor, NodeID) {
        var nodes = NodeRegistry()
        nodes.register(NodeDefinition(typeID: "t", displayName: "T", shape: .card, titleMode: .transparent)) { _ in .empty }
        nodes.register(NodeDefinition(typeID: "plain", displayName: "Plain")) { _ in .empty }
        let editor = GraphEditor(nodes: nodes, types: TypeRegistry())
        let node = Node(typeID: "t")
        try editor.apply(.addNode(node: node))
        return (editor, node.id)
    }

    @Test func aNodeUsesItsOwnThenTheDefinitionsThenTheBuiltInLook() {
        let styled = NodeDefinition(typeID: "a", displayName: "A", shape: .card, titleMode: .hidden)
        let plain = NodeDefinition(typeID: "b", displayName: "B")
        var node = Node(typeID: "a")
        #expect(node.resolvedShape(in: styled) == .card && node.resolvedTitleMode(in: styled) == .hidden)
        #expect(node.resolvedShape(in: plain) == .round && node.resolvedTitleMode(in: plain) == .normal)
        #expect(node.resolvedShape(in: nil) == .round, "an unregistered type still draws")
        node.shape = .box
        node.titleMode = .autohide
        #expect(node.resolvedShape(in: styled) == .box && node.resolvedTitleMode(in: styled) == .autohide)
    }

    @Test func attributesSetAndInvertThroughTheEditor() throws {
        let (editor, id) = try editor()
        let history = GraphHistory(editor: editor)
        try history.perform(.setNodeAttribute(node: id, attribute: .shape(value: .box)))
        try history.perform(.setNodeAttribute(node: id, attribute: .titleMode(value: .autohide)))
        #expect(editor.graph.nodes[id]?.shape == .box && editor.graph.nodes[id]?.titleMode == .autohide)
        try history.undo()
        try history.undo()
        #expect(editor.graph.nodes[id]?.shape == nil && editor.graph.nodes[id]?.titleMode == nil)
        try history.redo()
        #expect(editor.graph.nodes[id]?.shape == .box)
        // nil goes back to the definition's look.
        try history.perform(.setNodeAttribute(node: id, attribute: .shape(value: nil)))
        #expect(editor.graph.nodes[id]?.shape == nil)
    }

    @Test func sameFieldEditsCoalesceAndDifferentFieldsDoNot() {
        #expect(NodeAttribute.shape(value: .box).field == "shape")
        #expect(NodeAttribute.titleMode(value: .hidden).field == "titleMode")
        #expect(NodeAttribute.shape(value: .box).field != NodeAttribute.titleMode(value: .hidden).field)
    }

    @Test func unsetAppearanceIsLeftOutOfTheFileAndSetAppearanceRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = try String(decoding: encoder.encode(Node(typeID: "t")), as: UTF8.self)
        #expect(!plain.contains("shape") && !plain.contains("titleMode"), "old files stay byte-identical")

        let styled = Node(typeID: "t", shape: .card, titleMode: .transparent)
        let decoded = try JSONDecoder().decode(Node.self, from: encoder.encode(styled))
        #expect(decoded == styled)
        #expect(try String(decoding: encoder.encode(styled), as: UTF8.self).contains(#""shape":"card""#))
    }

    @Test func portAndDefinitionAppearanceRoundTrip() throws {
        let definition = NodeDefinition(
            typeID: "d", displayName: "D", ports: [PortDefinition(id: "p", direction: .input, shape: .square)],
            shape: .box, titleMode: .hidden)
        #expect(try JSONDecoder().decode(NodeDefinition.self, from: JSONEncoder().encode(definition)) == definition)
        let info = PortTypeInfo(type: "x", displayName: "X", color: RGBAColor(red: 0, green: 0, blue: 0), shape: .grid)
        #expect(try JSONDecoder().decode(PortTypeInfo.self, from: JSONEncoder().encode(info)) == info)
    }

    @Test func definitionsWrittenBeforeAppearanceStillDecode() throws {
        let old = Data(#"{"typeID":"d","displayName":"D","category":"","ports":[],"dynamicPorts":[],"properties":[],"defaultSize":{"width":1,"height":1},"isFeedback":false,"isPure":false}"#.utf8)
        let definition = try JSONDecoder().decode(NodeDefinition.self, from: old)
        #expect(definition.shape == nil && definition.titleMode == nil)
    }
}
