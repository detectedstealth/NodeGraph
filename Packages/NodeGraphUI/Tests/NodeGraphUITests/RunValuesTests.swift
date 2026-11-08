import CoreGraphics
import SwiftUI
import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct RunValuesModelTests {
    private func rig() throws -> (model: GraphEditorModel, source: Node, sink: Node, link: GraphLink, runner: GraphRunner) {
        let model = TestKit.makeModel()
        let source = Node(typeID: TestKit.source, position: GraphPoint(x: 0, y: 0))
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 300, y: 0))
        try model.perform(.addNode(node: source))
        try model.perform(.addNode(node: sink))
        let link = GraphLink(sourceNode: source.id, sourcePort: "out", targetNode: sink.id, targetPort: "a")
        try model.perform(.addLink(link: link))

        var nodes = model.editor.nodes
        nodes.register(NodeDefinition(
            typeID: TestKit.source, displayName: "Source",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")])
        ) { _ in ["out": .double(2.5)] }
        nodes.register(NodeDefinition(
            typeID: TestKit.sink, displayName: "Sink",
            ports: [
                PortDefinition(id: "a", direction: .input, type: "number"),
                PortDefinition(id: "b", direction: .input, type: "number"),
            ])
        ) { _ in .empty }
        let runner = try GraphRunner(graph: model.editor.graph, registry: nodes)
        return (model, source, sink, link, runner)
    }

    @Test func aPassPublishesValuesToTheModelAndAClearRemovesThem() async throws {
        let (model, source, _, link, runner) = try rig()
        #expect(model.valueLabel(of: link) == nil)
        model.apply(await runner.step())
        #expect(model.runValues[source.id, "out"] == .double(2.5))
        #expect(model.valueLabel(of: link) == "2.5")
        model.clearExecutionState()
        #expect(model.runValues[source.id].isEmpty)
        #expect(model.valueLabel(of: link) == nil)
    }

    @Test func observingAResultStreamFillsTheValues() async throws {
        let (model, source, _, _, runner) = try rig()
        let task = model.observeResults(runner.run(.once))
        await task.value
        #expect(model.runValues[source.id, "out"] == .double(2.5))
    }

    @Test func longValuesAreCutInTheLabel() async throws {
        let (model, _, _, link, _) = try rig()
        let long = GraphValue.string(String(repeating: "x", count: 100))
        var nodes = model.editor.nodes
        nodes.register(NodeDefinition(
            typeID: TestKit.source, displayName: "Source",
            ports: [PortDefinition(id: "out", direction: .output, type: "number")])
        ) { _ in ["out": long] }
        model.apply(await (try GraphRunner(graph: model.editor.graph, registry: nodes)).step())
        #expect(model.valueLabel(of: link)?.count == 40)
    }
}

@Suite struct LinkMidpointTests {
    @Test func aStraightRouteHasItsMiddleHalfway() {
        let path = LinkPath(from: GraphPoint(x: 0, y: 0), to: GraphPoint(x: 100, y: 0), style: .linear)
        let middle = path.midpoint()
        #expect(abs(middle.x - 50) < 1e-9 && abs(middle.y) < 1e-9)
    }

    @Test func aSplineBetweenLevelPortsPassesThroughTheMiddle() {
        let path = LinkPath(from: GraphPoint(x: 0, y: 0), to: GraphPoint(x: 200, y: 100), style: .spline)
        let middle = path.midpoint()
        #expect(abs(middle.x - 100) < 1 && abs(middle.y - 50) < 1)
    }

    @Test func aWaypointMovesTheMiddleOntoTheLongerHalf() {
        // 100 to the waypoint, 300 beyond it: halfway by length is 100 into the second leg.
        let path = LinkPath(
            from: GraphPoint(x: 0, y: 0), to: GraphPoint(x: 400, y: 0),
            waypoints: [GraphPoint(x: 100, y: 0)], style: .orthogonal)
        #expect(path.midpoint().x > 100)
    }
}

@MainActor
@Suite struct ReadoutDrawingTests {
    private func render(_ values: [PortID: GraphValue]) throws -> Data {
        let drawing = NodeContentDrawing.readout(of: "result")
        let rect = CGRect(x: 0, y: 0, width: 160, height: drawing.height)
        let content = NodeContentContext(
            node: Node(typeID: TestKit.source), definition: nil, rect: rect, theme: .dark, zoom: 1, values: values)
        let renderer = ImageRenderer(content: Canvas { context, _ in
            var context = context
            drawing.draw(&context, content)
        }.frame(width: rect.width, height: rect.height))
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data as Data?)
    }

    @Test func showsTheValueOrADashWhenThereIsNone() throws {
        let blank = try render([:])
        let seven = try render(["result": .double(7)])
        let eight = try render(["result": .double(8)])
        #expect(blank != seven)
        #expect(seven != eight)
    }

    @Test func theDrawingReservesItsHeight() throws {
        #expect(NodeContentDrawing.readout(of: "result").height == 24)
        #expect(NodeContentDrawing.readout(of: "result", height: 40).height == 40)
    }
}
