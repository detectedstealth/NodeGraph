import NodeGraphCore
import NodeGraphNodes

/// Nodes for editing video as a graph: clips, trims, a sequence on a timeline, transitions,
/// effects and a render node.
///
/// Evaluation is by time. A pass at time t gives the frame for t: the sequence picks the clip
/// playing then, a transition blends by how far t is through it, and the render node hands the
/// result on. Nodes that depend on t read `ctx.time.elapsedSeconds`, so they are not pure.
/// No pixels are touched here: a frame is a description (which asset, which moment, how
/// blended), and a host draws it.
public enum VideoPack: NodePack {
    public static func register(nodes: inout NodeRegistry, types: inout TypeRegistry) {
        StandardTypes.register(in: &types)
        types.register(PortTypeInfo(
            type: .clip, displayName: "Clip", color: RGBAColor(red: 0.30, green: 0.75, blue: 0.75), shape: .square))
        types.register(PortTypeInfo(
            type: .frame, displayName: "Frame", color: RGBAColor(red: 0.85, green: 0.55, blue: 0.30), shape: .grid))
        registerClips(in: &nodes)
        registerTimeline(in: &nodes)
        registerLook(in: &nodes)
    }

    /// The standard packs together with this one.
    public static func makeRegistries() -> (nodes: NodeRegistry, types: TypeRegistry) {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        register(nodes: &nodes, types: &types)
        return (nodes, types)
    }

    static let emptyFrame = VideoFrame().value

    static func frameInput(_ id: PortID) -> PortDefinition {
        PortDefinition(id: id, direction: .input, type: .frame, defaultValue: emptyFrame)
    }

    static func number(_ id: PropertyID, _ name: String, _ value: Double) -> PropertyDefinition {
        PropertyDefinition(id: id, displayName: name, kind: .double(), defaultValue: .double(value))
    }

    static func frame(_ ctx: NodeContext, _ port: PortID) throws -> VideoFrame {
        guard let frame = VideoFrame(value: try ctx.input(port)) else {
            throw NodeExecutionError.invalidInput(port, expected: "frame")
        }
        return frame
    }

    static func clip(_ value: GraphValue, port: PortID) throws -> VideoClip {
        guard let clip = VideoClip(value: value) else {
            throw NodeExecutionError.invalidInput(port, expected: "clip")
        }
        return clip
    }
}
