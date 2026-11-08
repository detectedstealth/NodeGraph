import CoreGraphics
import Foundation
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct DisplayExtrasTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @discardableResult
    private func add(_ type: NodeTypeID, x: Double, y: Double = 0) throws -> Node {
        let node = Node(typeID: type, position: GraphPoint(x: x, y: y))
        try model.perform(.addNode(node: node))
        return node
    }

    private func link(_ source: Node, _ sink: Node) throws {
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
    }

    @Test func linkPathReportsTheDirectionAtItsMiddle() {
        let level = LinkPath(from: GraphPoint(x: 0, y: 0), to: GraphPoint(x: 200, y: 0), style: .linear)
        let flat = level.midpointWithDirection()
        #expect(flat.point == GraphPoint(x: 100, y: 0))
        #expect(abs(flat.angle) < 1e-9)
        let falling = LinkPath(from: GraphPoint(x: 0, y: 0), to: GraphPoint(x: 200, y: 200), style: .linear)
        #expect(falling.midpointWithDirection().angle > 0)  // heads down and right
        let rising = LinkPath(from: GraphPoint(x: 0, y: 200), to: GraphPoint(x: 200, y: 0), style: .linear)
        #expect(rising.midpointWithDirection().angle < 0)
    }

    @Test func executionOrderCountsFromOneAlongTheLinks() throws {
        let a = try add(TestKit.source, x: 400)
        let b = try add(TestKit.sink, x: 0)
        try link(a, b)
        #expect(model.executionOrder[a.id] == 1)
        #expect(model.executionOrder[b.id] == 2)
    }

    @Test func executionOrderFollowsEdits() throws {
        let a = try add(TestKit.source, x: 0)
        #expect(model.executionOrder == [a.id: 1])
        let b = try add(TestKit.source, x: 100)
        #expect(model.executionOrder.count == 2)
        try model.perform(.removeNode(id: b.id))
        #expect(model.executionOrder == [a.id: 1])
    }

    @Test func statsCountNodesLinksAndVisibleItems() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.sink, x: 300)
        try link(a, b)
        try add(TestKit.source, x: 90_000)  // far outside the view
        model.camera = GraphCamera()
        let stats = model.stats
        #expect(stats.nodes == 3 && stats.links == 1)
        #expect(stats.visibleItems == 3)  // two nodes and the link
        #expect(stats.lines.last == "Zoom 100%")
    }

    @Test func togglesFlipTheDisplayOptions() {
        #expect(controller.perform(.toggleLinkArrows) && model.showsLinkArrows)
        #expect(controller.perform(.toggleExecutionOrder) && model.showsExecutionOrder)
        #expect(controller.perform(.toggleStats) && model.showsStats)
        #expect(controller.perform(.toggleStats) && !model.showsStats)
    }

    @Test func displayTogglesWorkOnAReadOnlyCanvas() {
        model.isEditable = false
        #expect(controller.perform(.toggleLinkArrows))
        #expect(model.showsLinkArrows)
    }

    @Test func exportNeedsAHostAndANode() throws {
        #expect(!controller.perform(.exportImage))
        var received: Data?
        model.onExportImage = { received = $0 }
        #expect(!controller.perform(.exportImage))  // no nodes yet
        try add(TestKit.source, x: 0)
        #expect(controller.perform(.exportImage))
        let png = try #require(received)
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func exportDoesNotMoveTheCamera() throws {
        try add(TestKit.source, x: 0)
        let camera = GraphCamera(origin: GraphPoint(x: 12, y: 34), zoom: 1.5)
        model.camera = camera
        let image = try #require(model.renderImage(scale: 1, padding: 20))
        #expect(model.camera == camera)
        #expect(image.width > 40 && image.height > 40)
    }

    @Test func theMenuOffersTheOptionsAndChecksTheOnesThatAreOn() {
        model.showsStats = true
        let items = controller.contextMenu(at: CGPoint(x: 900, y: 900))
        #expect(items.first { $0.title == "Show Statistics" }?.isChecked == true)
        #expect(items.first { $0.title == "Show Link Arrows" }?.isChecked == false)
        #expect(items.first { $0.title == "Export as Image…" }?.isEnabled == false)
    }

    @Test func drawingWithEveryExtraOnProducesADifferentPicture() throws {
        let a = try add(TestKit.source, x: 0)
        let b = try add(TestKit.sink, x: 300)
        try link(a, b)
        let plain = try #require(model.renderImage(scale: 1)?.dataProvider?.data as Data?)
        model.showsLinkArrows = true
        let arrows = try #require(model.renderImage(scale: 1)?.dataProvider?.data as Data?)
        model.showsExecutionOrder = true
        let order = try #require(model.renderImage(scale: 1)?.dataProvider?.data as Data?)
        #expect(plain != arrows)
        #expect(arrows != order)
    }
}
