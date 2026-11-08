import CoreGraphics
import SwiftUI
import Testing
import NodeGraphCore
@testable import NodeGraphUI

/// Times how long the canvas takes to draw one frame, so drawing regressions show up.
@MainActor
@Suite struct RenderTimingTests {
    private func makeModel(nodeCount: Int) throws -> GraphEditorModel {
        let model = TestKit.makeModel()
        var previous: Node?
        for i in 0..<nodeCount {
            let node = Node(
                typeID: i % 2 == 0 ? TestKit.source : TestKit.sink,
                position: GraphPoint(x: Double(i % 10) * 220, y: Double(i / 10) * 140))
            try model.perform(.addNode(node: node))
            if let previous, previous.typeID == TestKit.source, node.typeID == TestKit.sink {
                try model.connect(ConnectionProposal(
                    source: PortAddress(node: previous.id, port: "out", direction: .output),
                    target: PortAddress(node: node.id, port: "a", direction: .input)))
            }
            previous = node
        }
        model.viewSize = CGSize(width: 1400, height: 1000)
        model.camera = GraphCamera(origin: .zero, zoom: 1)
        return model
    }

    func millisecondsPerFrame(_ model: GraphEditorModel, frames: Int) -> Double {
        let controller = GraphInteractionController(model: model)
        let canvas = Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            var context = context
            MainActor.assumeIsolated {
                GraphCanvasRenderer(model: model, controller: controller).draw(&context, size: size)
            }
        }
        .frame(width: 1400, height: 1000)
        // A renderer caches its image, so each frame needs a fresh one.
        func renderOnce() {
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            _ = renderer.cgImage
        }
        renderOnce()  // warm up
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<frames { renderOnce() } }
        let parts = elapsed.components
        return (Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15) / Double(frames)
    }

    @Test func frameTimeAtVariousSizes() throws {
        for count in [10, 60] {
            let model = try makeModel(nodeCount: count)
            let ms = millisecondsPerFrame(model, frames: 10)
            print("RENDER \(count) nodes: \(String(format: "%.1f", ms)) ms/frame")
            // Generous: this only catches a drawing change that makes frames many times slower.
            #expect(ms < 100)
        }
    }
}
