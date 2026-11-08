import NodeGraphCore

extension VideoPack {
    static func registerTimeline(in nodes: inout NodeRegistry) {
        // Clips play one after another from `offset`. The node always shows one free clip input.
        nodes.register(NodeDefinition(
            typeID: "video.sequence", displayName: "Sequence", category: "Video",
            ports: [
                PortDefinition(id: "frame", direction: .output, type: .frame),
                PortDefinition(id: "duration", direction: .output, type: .number),
            ],
            dynamicPorts: [DynamicPortGroup(
                id: "clip", displayName: "Clip", type: .clip, minimum: 1, initialCount: 2, resizing: .keepOneFree)],
            properties: [number("offset", "Starts at (s)", 0)],
            help: "Plays clips one after another, starting at the offset. Shows the frame for the current time; before the start and after the end there are no layers.")
        ) { ctx in
            let clips = try ctx.values(inGroup: "clip").map { try clip($0, port: "clip") }
            let offset = try ctx.property("offset").numberValue ?? 0
            let local = ctx.time.elapsedSeconds - offset
            var layers: [VideoLayer] = []
            var start = 0.0
            for clip in clips {
                defer { start += clip.duration }
                if local >= start, local < start + clip.duration {
                    layers = [VideoLayer(asset: clip.asset, sourceTime: clip.sourceStart + (local - start))]
                    break
                }
            }
            return ["frame": VideoFrame(layers: layers).value, "duration": .double(clips.reduce(0) { $0 + $1.duration })]
        }

        // How far through the transition the current time is, 0 up to 1.
        nodes.register(NodeDefinition(
            typeID: "video.transition", displayName: "Transition", category: "Video",
            ports: [frameInput("a"), frameInput("b"), PortDefinition(id: "frame", direction: .output, type: .frame)],
            properties: [
                PropertyDefinition(
                    id: "kind", displayName: "Kind",
                    kind: .choice(Transition.allCases.map { PropertyChoice(value: $0.rawValue, label: $0.label) }),
                    defaultValue: .string(Transition.crossfade.rawValue)),
                number("start", "Starts at (s)", 0), number("duration", "Duration (s)", 1),
            ],
            help: "Moves from A to B between Starts at and Starts at + Duration. Before that it shows A, after it B.")
        ) { ctx in
            let name = try ctx.property("kind").stringValue ?? ""
            guard let kind = Transition(rawValue: name) else { throw NodeExecutionError.failed("Unknown transition \(name)") }
            let start = try ctx.property("start").numberValue ?? 0
            let length = try ctx.property("duration").numberValue ?? 0
            guard length > 0 else { throw NodeExecutionError.failed("Duration must be above zero") }
            let progress = min(max((ctx.time.elapsedSeconds - start) / length, 0), 1)
            return ["frame": kind.blend(try frame(ctx, "a"), try frame(ctx, "b"), progress).value]
        }
    }

    enum Transition: String, CaseIterable {
        case crossfade, dipToBlack, wipe

        var label: String {
            switch self {
            case .crossfade: "Crossfade"
            case .dipToBlack: "Dip to Black"
            case .wipe: "Wipe"
            }
        }

        func blend(_ a: VideoFrame, _ b: VideoFrame, _ progress: Double) -> VideoFrame {
            func scaled(_ frame: VideoFrame, by factor: Double) -> [VideoLayer] {
                frame.layers.compactMap { layer in
                    var layer = layer
                    layer.opacity *= factor
                    return layer.opacity > 0 ? layer : nil
                }
            }
            if progress <= 0 { return a }
            if progress >= 1 { return b }
            switch self {
            case .crossfade:
                return VideoFrame(layers: scaled(a, by: 1 - progress) + scaled(b, by: progress))
            case .dipToBlack:
                return VideoFrame(layers: progress < 0.5
                    ? scaled(a, by: 1 - 2 * progress) : scaled(b, by: 2 * progress - 1))
            case .wipe:
                // B slides in over A from the left.
                return VideoFrame(layers: a.layers + b.layers.map { layer in
                    var layer = layer
                    layer.reveal *= progress
                    return layer
                })
            }
        }
    }
}
