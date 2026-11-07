import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct MiniMapGeometryTests {
    @Test func worldCoversContentAndViewport() {
        let world = MiniMapGeometry.world(
            content: GraphRect(x: 0, y: 0, width: 100, height: 50),
            viewport: GraphRect(x: 80, y: -20, width: 100, height: 40))
        #expect(world == GraphRect(x: 0, y: -20, width: 180, height: 70))
        #expect(MiniMapGeometry.world(content: nil, viewport: GraphRect(x: 1, y: 2, width: 3, height: 4))
            == GraphRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func fitsTheWorldCenteredWithEqualScale() {
        let geometry = MiniMapGeometry(
            world: GraphRect(x: 100, y: 100, width: 400, height: 100), size: CGSize(width: 200, height: 100), padding: 0)
        #expect(geometry.scale == 0.5)
        let rect = geometry.rect(forGraph: GraphRect(x: 100, y: 100, width: 400, height: 100))
        // Full width, and the extra height split above and below.
        #expect(rect == CGRect(x: 0, y: 25, width: 200, height: 50))
    }

    @Test func pointsRoundTrip() {
        let geometry = MiniMapGeometry(
            world: GraphRect(x: -300, y: 40, width: 900, height: 500), size: CGSize(width: 180, height: 120))
        let point = GraphPoint(x: 120, y: 333)
        let back = geometry.graphPoint(forMiniMap: geometry.point(forGraph: point))
        #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
    }

    @Test func centeringTheCameraPutsThePointInTheMiddle() {
        var camera = GraphCamera(origin: .zero, zoom: 2)
        let size = CGSize(width: 800, height: 600)
        camera.center(on: GraphPoint(x: 500, y: 300), in: size)
        let middle = camera.graphPoint(forScreen: CGPoint(x: 400, y: 300))
        #expect(abs(middle.x - 500) < 1e-9 && abs(middle.y - 300) < 1e-9)
        #expect(camera.zoom == 2)
    }
}

@MainActor
@Suite struct ExecutionOverlayTests {
    @Test func decorationFollowsRunState() {
        #expect(NodeRunDecoration(.idle) == nil)
        #expect(NodeRunDecoration(.finished(.bypassed, duration: .zero)) == nil)

        let running = NodeRunDecoration(.running(progress: 1.7, message: "half"))
        #expect(running?.badge == .running)
        #expect(running?.progress == 1)
        #expect(running?.tintsBorder == true)

        let failed = NodeRunDecoration(.finished(.failed(message: "boom"), duration: .zero))
        #expect(failed?.badge == .failed)
        #expect(failed?.message == "boom")
        #expect(failed?.tintsBorder == true)

        let cached = NodeRunDecoration(.finished(.cached, duration: .zero))
        #expect(cached?.badge == .cached)
        #expect(cached?.tintsBorder == false)
    }

    @Test func modelFoldsEventsIntoState() {
        let model = TestKit.makeModel()
        let node = NodeID()
        model.apply(.passStarted(tick: 1, time: ExecutionTime()))
        model.apply(.nodeStarted(node: node, tick: 1))
        model.apply(.nodeProgress(NodeProgress(node: node, fraction: 0.25, message: nil)))
        #expect(model.runDecoration(of: node)?.progress == 0.25)
        model.apply(.nodeFinished(node: node, tick: 1, status: .failed(message: "bad"), duration: .zero))
        #expect(model.runDecoration(of: node)?.badge == .failed)
        model.clearExecutionState()
        #expect(model.runDecoration(of: node) == nil)
    }

    @Test func observingAStreamAppliesItsEvents() async {
        let model = TestKit.makeModel()
        let node = NodeID()
        let (stream, continuation) = AsyncStream.makeStream(of: ExecutionEvent.self)
        let task = model.observeExecution(stream)
        continuation.yield(.nodeStarted(node: node, tick: 1))
        continuation.yield(.nodeFinished(node: node, tick: 1, status: .succeeded, duration: .zero))
        continuation.finish()
        await task.value
        #expect(model.runDecoration(of: node)?.badge == .succeeded)
    }
}
