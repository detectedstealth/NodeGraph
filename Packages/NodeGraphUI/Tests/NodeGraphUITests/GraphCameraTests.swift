import CoreGraphics
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@Suite struct GraphCameraTests {
    @Test func screenAndGraphPointsRoundTrip() {
        let camera = GraphCamera(origin: GraphPoint(x: 40, y: -20), zoom: 2)
        let screen = CGPoint(x: 120, y: 80)
        let back = camera.screenPoint(for: camera.graphPoint(forScreen: screen))
        #expect(abs(back.x - screen.x) < 1e-9 && abs(back.y - screen.y) < 1e-9)
    }

    @Test func panFollowsThePointerAtAnyZoom() {
        var camera = GraphCamera(origin: .zero, zoom: 2)
        let grabbed = camera.graphPoint(forScreen: CGPoint(x: 100, y: 100))
        camera.pan(byScreen: CGSize(width: 30, height: -10))
        // The graph point under the pointer moved by the same screen distance.
        let moved = camera.screenPoint(for: grabbed)
        #expect(abs(moved.x - 130) < 1e-9 && abs(moved.y - 90) < 1e-9)
    }

    @Test func zoomKeepsTheAnchorStill() {
        var camera = GraphCamera(origin: GraphPoint(x: 10, y: 10), zoom: 1)
        let anchor = CGPoint(x: 300, y: 200)
        let before = camera.graphPoint(forScreen: anchor)
        camera.setZoom(2.5, anchoredAtScreen: anchor)
        let after = camera.graphPoint(forScreen: anchor)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        #expect(camera.zoom == 2.5)
    }

    @Test func zoomIsClampedAndDoesNotCompound() {
        var camera = GraphCamera()
        camera.setZoom(100, anchoredAtScreen: .zero)
        #expect(camera.zoom == GraphCamera.zoomRange.upperBound)
        camera.setZoom(0.0001, anchoredAtScreen: .zero)
        #expect(camera.zoom == GraphCamera.zoomRange.lowerBound)

        // A pinch applies its total magnification to the zoom at the start, however many
        // updates arrive.
        let start = GraphCamera(zoom: 1)
        var current = start
        for _ in 0..<5 {
            current = start
            current.setZoom(start.zoom * 1.5, anchoredAtScreen: .zero)
        }
        #expect(current.zoom == 1.5)
    }

    @Test func visibleRectShrinksWhenZoomedIn() {
        let camera = GraphCamera(origin: GraphPoint(x: 5, y: 6), zoom: 2)
        let rect = camera.visibleRect(in: CGSize(width: 400, height: 200))
        #expect(rect == GraphRect(x: 5, y: 6, width: 200, height: 100))
    }

    @Test func framingCentersTheRectAndShowsAllOfIt() {
        let rect = GraphRect(x: 1000, y: 1000, width: 2000, height: 1000)
        let size = CGSize(width: 800, height: 600)
        let camera = GraphCamera.framing(rect, in: size)
        let visible = camera.visibleRect(in: size)
        #expect(visible.contains(rect))
        let center = camera.graphPoint(forScreen: CGPoint(x: 400, y: 300))
        #expect(abs(center.x - 2000) < 1e-9 && abs(center.y - 1500) < 1e-9)
    }

    @Test func framingASmallRectDoesNotZoomIn() {
        let camera = GraphCamera.framing(
            GraphRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 800, height: 600))
        #expect(camera.zoom == 1)
    }
}
