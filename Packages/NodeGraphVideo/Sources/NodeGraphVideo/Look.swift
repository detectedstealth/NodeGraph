import NodeGraphCore

extension VideoPack {
    static let effectKinds = ["brightness", "contrast", "saturation", "blur"]

    static func registerLook(in nodes: inout NodeRegistry) {
        // `amount` is a port so it can be animated: wire it to a time-based node.
        nodes.register(NodeDefinition(
            typeID: "video.effect", displayName: "Effect", category: "Video",
            ports: [
                frameInput("frame"),
                PortDefinition(id: "amount", direction: .input, type: .number, defaultValue: 0.0),
                PortDefinition(id: "result", direction: .output, type: .frame),
            ],
            properties: [PropertyDefinition(
                id: "kind", displayName: "Effect",
                kind: .choice(effectKinds.map { PropertyChoice(value: $0, label: $0.capitalized) }),
                defaultValue: .string("brightness"))],
            isPure: true,
            help: "Adds an effect to every layer of the frame. Wire Amount to something that changes with time to animate it.")
        ) { ctx in
            let kind = try ctx.property("kind").stringValue ?? ""
            guard effectKinds.contains(kind) else { throw NodeExecutionError.failed("Unknown effect \(kind)") }
            let amount = try ctx.number("amount")
            guard amount.isFinite else { throw NodeExecutionError.failed("Amount is not a finite number") }
            var result = try frame(ctx, "frame")
            for index in result.layers.indices {
                result.layers[index].effects.append(VideoEffect(kind: kind, amount: amount))
            }
            return ["result": result.value]
        }

        // The end of the graph: sends the frame to the host's `FrameSink`, if there is one.
        nodes.register(NodeDefinition(
            typeID: "video.render", displayName: "Render", category: "Video",
            ports: [
                frameInput("frame"),
                PortDefinition(id: "result", direction: .output, type: .frame),
                PortDefinition(id: "layers", direction: .output, type: .number),
            ],
            help: "Delivers the frame for the current time to whatever draws or records it.")
        ) { ctx in
            let frame = try frame(ctx, "frame")
            ctx.services[FrameSinkBox.self]?.sink.consume(frame, at: ctx.time.elapsedSeconds)
            return ["result": frame.value, "layers": .int(Int64(frame.layers.count))]
        }
    }
}

/// How a `FrameSink` is stored in the service container, which looks services up by concrete type.
public struct FrameSinkBox: Sendable {
    public var sink: any FrameSink

    public init(_ sink: any FrameSink) { self.sink = sink }
}
