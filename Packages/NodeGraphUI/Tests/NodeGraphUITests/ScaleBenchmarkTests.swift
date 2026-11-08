import CoreGraphics
import Foundation
import SwiftUI
import Testing
import NodeGraphCore
@testable import NodeGraphUI

/// Phase 4 benchmark: frame time and first-query cost at 1k, 5k and 10k nodes, used to decide
/// whether Metal is needed (docs/DECISIONS.md). Each run prints `BENCH` lines; the numbers worth
/// keeping are recorded in DECISIONS.md. Run in release for numbers that mean anything:
///
///     swift test -c release --package-path Packages/NodeGraphUI --filter ScaleBenchmarkTests
///
/// The asserted limits are loose guards (debug builds are several times slower than release).
@MainActor
@Suite struct ScaleBenchmarkTests {
    /// A grid of alternating source and sink nodes, each source linked to the sink after it.
    private func makeModel(nodeCount: Int) throws -> GraphEditorModel {
        let columns = 100
        var graph = Graph()
        var commands: [GraphCommand] = []
        var previous: Node?
        for i in 0..<nodeCount {
            let node = Node(
                typeID: i % 2 == 0 ? TestKit.source : TestKit.sink,
                position: GraphPoint(x: Double(i % columns) * 220, y: Double(i / columns) * 140))
            commands.append(.addNode(node: node))
            if let previous, previous.typeID == TestKit.source, node.typeID == TestKit.sink {
                commands.append(.addLink(link: Link(
                    sourceNode: previous.id, sourcePort: "out", targetNode: node.id, targetPort: "a")))
            }
            previous = node
        }
        let (nodes, types) = TestKit.registries()
        let editor = GraphEditor(graph: graph, nodes: nodes, types: types)
        try editor.apply(.batch(commands: commands), validation: .structural)
        graph = editor.graph
        let model = GraphEditorModel(editor: editor)
        model.viewSize = CGSize(width: 1400, height: 1000)
        return model
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    @Test(arguments: [1_000, 5_000, 10_000])
    func frameTime(nodeCount: Int) throws {
        let model = try makeModel(nodeCount: nodeCount)
        let timing = RenderTimingTests()
        let clock = ContinuousClock()

        // First query builds every layout and the spatial index.
        model.camera = GraphCamera(origin: .zero, zoom: 1)
        let cold = milliseconds(clock.measure { _ = model.items(in: GraphRect(x: 0, y: 0, width: 10, height: 10)) })
        print("BENCH \(nodeCount) nodes: cold layout + index \(String(format: "%.0f", cold)) ms")

        // Zoomed in (about 60 nodes visible), mid zoom, and the whole graph at the minimum zoom.
        let scenarios: [(String, GraphCamera)] = [
            ("zoom 1.0 (~60 visible)", GraphCamera(origin: .zero, zoom: 1)),
            ("zoom 0.3", GraphCamera(origin: .zero, zoom: 0.3)),
            ("zoom 0.1 (fit/overview)", GraphCamera(origin: .zero, zoom: 0.1)),
        ]
        for (label, camera) in scenarios {
            model.camera = camera
            let visible = model.items(in: camera.visibleRect(in: model.viewSize)).count
            let ms = timing.millisecondsPerFrame(model, frames: 3)
            print("BENCH \(nodeCount) nodes, \(label): \(String(format: "%.1f", ms)) ms/frame, \(visible) items drawn")
            #expect(ms < 2000)
        }
    }

    /// One drag step: move a node, then ask what is visible (which rebuilds the index).
    @Test(arguments: [1_000, 5_000, 10_000])
    func dragStep(nodeCount: Int) throws {
        let model = try makeModel(nodeCount: nodeCount)
        model.camera = GraphCamera(origin: .zero, zoom: 1)
        _ = model.items(in: model.camera.visibleRect(in: model.viewSize))
        guard let id = model.graph.nodes.keys.first else { return }
        let clock = ContinuousClock()
        let steps = 20
        let elapsed = try clock.measure {
            for i in 0..<steps {
                try model.perform(.setNodePositions(placements: [NodePlacement(node: id, position: GraphPoint(x: Double(i), y: 0))]))
                _ = model.items(in: model.camera.visibleRect(in: model.viewSize))
            }
        }
        let ms = milliseconds(elapsed) / Double(steps)
        print("BENCH \(nodeCount) nodes: drag step \(String(format: "%.1f", ms)) ms")
        #expect(ms < 500)
    }
}
