import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct MultiTouchTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @Test func twoFingersPanTogether() {
        let start = CGPoint(x: 300, y: 300)
        controller.multiTouchBegan(centroid: start)
        controller.multiTouchMoved(centroid: CGPoint(x: 350, y: 280), scale: 1)
        #expect(model.camera.origin == GraphPoint(x: -50, y: 20))
        #expect(model.camera.zoom == 1)
        #expect(controller.isMultiTouch)
        controller.multiTouchEnded()
        #expect(!controller.isMultiTouch)
        #expect(model.camera.origin == GraphPoint(x: -50, y: 20))
    }

    @Test func pinchZoomsAboutTheFingersAndDoesNotCompound() {
        let start = CGPoint(x: 300, y: 200)
        let fixed = model.camera.graphPoint(forScreen: start)
        controller.multiTouchBegan(centroid: start)
        for scale in [1.2, 1.5, 1.8, 2.0] { controller.multiTouchMoved(centroid: start, scale: scale) }
        #expect(model.camera.zoom == 2)
        let after = model.camera.graphPoint(forScreen: start)
        #expect(abs(after.x - fixed.x) < 1e-9 && abs(after.y - fixed.y) < 1e-9)
        controller.multiTouchEnded()
        controller.multiTouchBegan(centroid: start)
        controller.multiTouchMoved(centroid: start, scale: 1.5)
        #expect(model.camera.zoom == 3)
    }

    @Test func pinchAndPanCombine() {
        let start = CGPoint(x: 300, y: 200)
        let fixed = model.camera.graphPoint(forScreen: start)
        controller.multiTouchBegan(centroid: start)
        let moved = CGPoint(x: 340, y: 230)
        controller.multiTouchMoved(centroid: moved, scale: 2)
        // The graph point that was under the fingers when they landed follows their midpoint.
        let screen = model.camera.screenPoint(for: fixed)
        #expect(abs(screen.x - moved.x) < 1e-9 && abs(screen.y - moved.y) < 1e-9)
    }

    @Test func secondFingerCancelsAnEditInProgress() throws {
        let node = Node(typeID: TestKit.source, position: .zero)
        try model.perform(.addNode(node: node))
        let before = model.history.undoStack.count
        controller.pointerDown(at: CGPoint(x: 60, y: 40), kind: .touch)
        controller.pointerMoved(to: CGPoint(x: 160, y: 140))
        #expect(model.graph.nodes[node.id]?.position == GraphPoint(x: 100, y: 100))
        controller.multiTouchBegan(centroid: CGPoint(x: 100, y: 100))
        #expect(model.graph.nodes[node.id]?.position == .zero)
        #expect(model.history.undoStack.count == before)
    }

    @Test func pointerEventsAreIgnoredWhileTwoFingersAreDown() throws {
        let node = Node(typeID: TestKit.source, position: .zero)
        try model.perform(.addNode(node: node))
        controller.multiTouchBegan(centroid: CGPoint(x: 100, y: 100))
        controller.pointerMoved(to: CGPoint(x: 300, y: 300))
        controller.pointerUp(at: CGPoint(x: 300, y: 300))
        #expect(model.graph.nodes[node.id]?.position == .zero)
        #expect(controller.isMultiTouch)
    }

    @Test func cancellingTwoFingersPutsTheCameraBack() {
        controller.multiTouchBegan(centroid: CGPoint(x: 100, y: 100))
        controller.multiTouchMoved(centroid: CGPoint(x: 200, y: 200), scale: 2)
        controller.cancel()
        #expect(model.camera == GraphCamera())
    }
}

@MainActor
@Suite struct TouchReachTests {
    let model = TestKit.makeModel()
    let controller: GraphInteractionController

    init() {
        controller = GraphInteractionController(model: model)
    }

    @Test func aFingerHitsAPortFromFurtherAwayThanAMouse() throws {
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 400, y: 0))
        try model.perform(.addNode(node: sink))
        let port = try #require(model.layout(of: sink.id)?.inputs.first)
        // 20 units left of the port: outside the mouse reach (12), inside the finger's (24).
        let near = CGPoint(x: port.position.x - 20, y: port.position.y)
        controller.pointerDown(at: near, kind: .mouse)
        controller.pointerMoved(to: CGPoint(x: near.x - 40, y: near.y - 80))
        #expect(controller.draft == nil)  // a mouse press here is empty canvas, so a marquee
        controller.pointerUp(at: CGPoint(x: near.x - 40, y: near.y - 80))

        controller.pointerDown(at: near, kind: .touch)
        controller.pointerMoved(to: CGPoint(x: near.x - 40, y: near.y - 80))
        #expect(controller.draft?.anchor == port.address)
        controller.pointerUp(at: CGPoint(x: near.x - 40, y: near.y - 80))
    }

    @Test func aFingerPicksALinkFromFurtherAwayThanAMouse() throws {
        let source = Node(typeID: TestKit.source, position: .zero)
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 600, y: 300))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        try model.connect(ConnectionProposal(
            source: PortAddress(node: source.id, port: "out", direction: .output),
            target: PortAddress(node: sink.id, port: "a", direction: .input)))
        let link = model.graph.links.keys[0]
        let middle = try #require(model.linkPath(of: model.graph.links[link]!)).polyline(curveSteps: 32)[16]
        let off = CGPoint(x: middle.x, y: middle.y + 10)  // 10 away: past a mouse's 6, within a finger's 12
        controller.pointerDown(at: off, kind: .mouse)
        controller.pointerUp(at: off)
        #expect(model.selection.links.isEmpty)
        controller.pointerDown(at: off, kind: .touch)
        controller.pointerUp(at: off)
        #expect(model.selection.links == [link])
    }

    @Test func pencilUsesPrecisePointerTargetsAndMarquee() throws {
        let node = Node(typeID: TestKit.source, position: GraphPoint(x: 100, y: 100))
        try model.perform(.addNode(node: node))
        controller.pointerDown(at: CGPoint(x: 50, y: 50), kind: .pencil)
        controller.pointerMoved(to: CGPoint(x: 350, y: 300))
        #expect(controller.marquee != nil)
        controller.pointerUp(at: CGPoint(x: 350, y: 300))
        #expect(model.selection.nodes == [node.id])
    }
}
