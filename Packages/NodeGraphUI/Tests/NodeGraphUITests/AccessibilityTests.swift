import SwiftUI
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct AccessibilityTests {
    /// A source at the left feeding a sink, linked.
    private func linkedModel() throws -> (GraphEditorModel, Node, Node, GraphLink) {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        let link = GraphLink(sourceNode: source.id, sourcePort: "out", targetNode: sink.id, targetPort: "a")
        try model.perform(.addLink(link: link))
        return (model, source, sink, link)
    }

    @Test func elementsAreNodesThenLinksInReadingOrder() throws {
        let (model, source, sink, link) = try linkedModel()
        let elements = model.accessibilityElements()
        #expect(elements.map(\.subject) == [.node(source.id), .node(sink.id), .link(link.id)])
        #expect(elements[0].label == "Source")
        #expect(elements[0].value.contains("Outputs: out, 1 link"))
        #expect(elements[1].value.contains("Inputs: a, 1 link; b"))
        #expect(elements[2].label == "Link from Source, out to Sink, a")
    }

    @Test func nodeActionsReflectState() throws {
        let (model, source, _, _) = try linkedModel()
        func names() -> [String] {
            model.accessibilityElements().first { $0.subject == .node(source.id) }?.actions.map(\.name) ?? []
        }
        #expect(names().contains("Move Left"))
        #expect(names().contains("Collapse") && names().contains("Pin"))
        #expect(names().contains("Connect output out"))
        #expect(names().contains("Disconnect All"))
        #expect(!names().contains("Set Mode Always"))
        try model.perform(.setNodeAttribute(node: source.id, attribute: .isPinned(value: true)))
        #expect(!names().contains("Move Left"))
        #expect(names().contains("Unpin"))
    }

    @Test func actionsRunOnTheirOwnElement() throws {
        let (model, source, sink, _) = try linkedModel()
        let controller = GraphInteractionController(model: model)
        model.select(node: source.id)
        #expect(controller.perform(.command(.deleteSelection), on: .node(sink.id)))
        #expect(model.graph.nodes[sink.id] == nil)
        #expect(model.graph.nodes[source.id] != nil)
        #expect(model.graph.links.isEmpty)
    }

    @Test func connectionChooserListsValidPortsAndConnects() throws {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source)
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        let out = PortAddress(node: source.id, port: "out", direction: .output)
        #expect(model.beginConnection(from: out))
        let candidates = try #require(model.connectionRequest).candidates
        #expect(candidates.map(\.portName) == ["a", "b"])
        #expect(model.completeConnection(to: candidates[1].address))
        #expect(model.connectionRequest == nil)
        #expect(model.graph.links.count == 1)
        // Starting from the input side finds the output.
        let input = PortAddress(node: sink.id, port: "a", direction: .input)
        #expect(model.beginConnection(from: input))
        #expect(model.connectionRequest?.candidates.map(\.nodeTitle) == ["Source"])
        model.cancelConnection()
        #expect(model.connectionRequest == nil)
    }

    @Test func dynamicTypeScalesLayout() throws {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.sink)
        try model.perform(.addNode(node: node))
        let before = try #require(model.layout(of: node.id))
        model.textScale = GraphEditorModel.textScale(for: .accessibility3)
        let after = try #require(model.layout(of: node.id))
        #expect(after.header.size.height > before.header.size.height * 2)
        #expect(after.frame.size.height > before.frame.size.height)
        #expect(GraphEditorModel.textScale(for: .large) == 1)
        #expect(GraphEditorModel.textScale(for: .accessibility5) == 2.5)
        #expect(GraphEditorModel.textScale(for: .xSmall) < 1)
    }
}
