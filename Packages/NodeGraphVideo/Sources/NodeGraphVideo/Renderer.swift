import NodeGraphCore

/// Why a frame could not be produced.
public enum VideoRenderError: Error, Hashable, Sendable {
    /// The graph has no `video.render` node.
    case noRenderNode
    /// A node failed; the message is the node's.
    case nodeFailed(String)
}

/// Evaluates a video graph at chosen moments.
///
/// Each frame is one pass of the graph at that time (`GraphRunner.step(at:)`), so any frame can
/// be asked for in any order, which is what scrubbing and a parallel export need.
public final class VideoRenderer: Sendable {
    private let runner: GraphRunner
    private let renderNode: NodeID
    public let frameRate: Double

    /// - Throws: ``VideoRenderError/noRenderNode``, or `ExecutionPlanError` for a graph with a loop.
    public init(
        graph: Graph,
        registry: NodeRegistry,
        assets: AssetLibrary,
        sink: (any FrameSink)? = nil,
        frameRate: Double = 30
    ) throws {
        guard let render = graph.nodes.values.first(where: { $0.typeID == "video.render" }) else {
            throw VideoRenderError.noRenderNode
        }
        var services = ServiceContainer()
        services.register(assets)
        if let sink { services.register(FrameSinkBox(sink)) }
        renderNode = render.id
        self.frameRate = frameRate
        runner = try GraphRunner(graph: graph, registry: registry, services: services)
    }

    /// The frame at `seconds`.
    public func frame(at seconds: Double) async throws -> VideoFrame {
        let tick = await runner.step(at: .seconds(seconds), delta: .seconds(1 / frameRate))
        if let failed = tick.failedNodes.first, case .failure(let failure)? = tick.results[failed]?.outcome {
            throw VideoRenderError.nodeFailed(failure.message)
        }
        guard let value = tick.outputs(of: renderNode)?.values["result"], let frame = VideoFrame(value: value) else {
            throw VideoRenderError.nodeFailed("The render node produced no frame")
        }
        return frame
    }

    /// The frames from the start for `duration` seconds, one per frame period, in order.
    public func frames(duration: Double) async throws -> [VideoFrame] {
        var result: [VideoFrame] = []
        for index in 0..<Int((duration * frameRate).rounded(.down)) {
            result.append(try await frame(at: Double(index) / frameRate))
        }
        return result
    }
}
