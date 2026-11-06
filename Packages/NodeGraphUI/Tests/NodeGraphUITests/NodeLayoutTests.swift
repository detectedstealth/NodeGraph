import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct NodeLayoutTests {
    let metrics = NodeLayoutMetrics.standard
    let registry = TestKit.registries().nodes

    private func layout(of node: Node) -> NodeLayout {
        NodeLayout(node: node, definition: registry.definition(for: node), metrics: metrics)
    }

    @Test func portsSitOnTheEdgesInDeclarationOrder() {
        let node = Node(typeID: TestKit.sink, position: GraphPoint(x: 100, y: 200))
        let layout = layout(of: node)
        #expect(layout.inputs.map(\.definition.id.rawValue) == ["a", "b"])
        let firstY = 200 + metrics.headerHeight + metrics.portInset + metrics.portRowHeight / 2
        #expect(layout.inputs[0].position == GraphPoint(x: 100, y: firstY))
        #expect(layout.inputs[1].position == GraphPoint(x: 100, y: firstY + metrics.portRowHeight))
    }

    @Test func outputsSitOnTheRightEdge() {
        let node = Node(typeID: TestKit.source, position: GraphPoint(x: 10, y: 20), size: GraphSize(width: 150, height: 90))
        let layout = layout(of: node)
        #expect(layout.outputs[0].position.x == 160)
    }

    @Test func frameGrowsToFitPorts() {
        // The sink's default height (40) is too short for its header and two port rows.
        let layout = layout(of: Node(typeID: TestKit.sink))
        let needed = metrics.headerHeight + 2 * metrics.portInset + 2 * metrics.portRowHeight
        #expect(layout.frame.size.height == needed)
        #expect(layout.minimumSize.height == needed)
    }

    @Test func frameKeepsALargerRequestedSize() {
        let layout = layout(of: Node(typeID: TestKit.sink, size: GraphSize(width: 300, height: 400)))
        #expect(layout.frame.size == GraphSize(width: 300, height: 400))
    }

    @Test func widthHasAFloor() {
        let layout = layout(of: Node(typeID: TestKit.sink, size: GraphSize(width: 10, height: 100)))
        #expect(layout.frame.size.width == metrics.minimumWidth)
    }

    @Test func headerAndBodyTileTheFrame() {
        let layout = layout(of: Node(typeID: TestKit.sink, position: GraphPoint(x: 5, y: 7)))
        #expect(layout.header.minY == layout.frame.minY)
        #expect(layout.body.minY == layout.header.maxY)
        #expect(layout.body.maxY == layout.frame.maxY)
    }

    @Test func collapsedNodeIsOnlyItsHeaderAndAttachesLinksAtTheMiddle() {
        let node = Node(typeID: TestKit.sink, position: GraphPoint(x: 0, y: 0), isCollapsed: true)
        let layout = layout(of: node)
        #expect(layout.frame.size.height == metrics.headerHeight)
        #expect(layout.body.size.height == 0)
        #expect(layout.inputs.allSatisfy { $0.position == GraphPoint(x: 0, y: metrics.headerHeight / 2) })
    }

    @Test func dynamicPortsFollowThePortCount() {
        let two = layout(of: Node(typeID: TestKit.merge, portCounts: ["in": 2]))
        #expect(two.inputs.map(\.definition.id.rawValue) == ["in_1", "in_2"])
        let four = layout(of: Node(typeID: TestKit.merge, portCounts: ["in": 4]))
        #expect(four.inputs.count == 4)
        #expect(four.frame.size.height > two.frame.size.height)
    }

    @Test func unregisteredTypeGetsAFrameAndNoPorts() {
        let layout = NodeLayout(
            node: Node(typeID: NodeTypeID("missing.type")), definition: nil, metrics: metrics)
        #expect(layout.inputs.isEmpty && layout.outputs.isEmpty)
        #expect(layout.frame.size.width > 0 && layout.frame.size.height > 0)
    }

    @Test func portLookupByAddress() {
        let node = Node(typeID: TestKit.sink)
        let layout = layout(of: node)
        let b = PortAddress(node: node.id, port: "b", direction: .input)
        #expect(layout.port(b)?.definition.id == "b")
        #expect(layout.port(PortAddress(node: node.id, port: "b", direction: .output)) == nil)
    }

    @Test func hitTestPicksTheNearestPortWithinRadius() {
        let node = Node(typeID: TestKit.sink)
        let layout = layout(of: node)
        let target = layout.inputs[1].position
        let near = GraphPoint(x: target.x + 3, y: target.y - 2)
        #expect(layout.port(at: near, radius: metrics.portHitRadius)?.definition.id == "b")
        #expect(layout.port(at: GraphPoint(x: 80, y: target.y), radius: metrics.portHitRadius) == nil)
    }

    @Test func resizeHandleIsInTheBottomRightCorner() {
        let layout = layout(of: Node(typeID: TestKit.sink))
        #expect(layout.resizeHandle.maxX == layout.frame.maxX)
        #expect(layout.resizeHandle.maxY == layout.frame.maxY)
        #expect(layout.frame.contains(layout.resizeHandle))
    }
}
