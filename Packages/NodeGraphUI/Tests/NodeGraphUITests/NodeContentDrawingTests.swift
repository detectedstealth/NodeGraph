import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct NodeContentDrawingTests {
    private func model(contentHeight: Double? = nil) -> (GraphEditorModel, NodeID) {
        let model = TestKit.makeModel()
        let node = Node(typeID: TestKit.widgets, position: GraphPoint(x: 10, y: 20))
        try? model.perform(.addNode(node: node))
        if let contentHeight {
            model.registerContentDrawing(for: TestKit.widgets, NodeContentDrawing(height: contentHeight) { _, _ in })
        }
        return (model, node.id)
    }

    @Test func nodesWithoutADrawingHaveNoContentArea() throws {
        let (model, id) = model()
        #expect(try #require(model.layout(of: id)).content == nil)
    }

    @Test func contentAreaSitsBelowTheWidgetsInsideTheNode() throws {
        let (model, id) = model(contentHeight: 50)
        let layout = try #require(model.layout(of: id))
        let area = try #require(layout.content)
        let lastWidget = try #require(layout.widgets.last)
        #expect(area.size.height == 50)
        #expect(area.minY >= lastWidget.frame.maxY)
        #expect(area.maxY <= layout.frame.maxY)
        #expect(area.minX >= layout.frame.minX && area.maxX <= layout.frame.maxX)
    }

    @Test func registeringAfterLayoutGrowsTheNode() throws {
        let (model, id) = model()
        let before = try #require(model.layout(of: id))
        model.registerContentDrawing(for: TestKit.widgets, NodeContentDrawing(height: 100) { _, _ in })
        let after = try #require(model.layout(of: id))
        #expect(after.minimumSize.height >= before.minimumSize.height + 100)
        #expect(after.frame.size.height >= before.frame.size.height + 100)
    }

    @Test func collapsedNodesHaveNoContentArea() throws {
        let (model, id) = model(contentHeight: 50)
        try model.perform(.setNodeAttribute(node: id, attribute: .isCollapsed(value: true)))
        #expect(try #require(model.layout(of: id)).content == nil)
    }
}
