import NodeGraphCore
import NodeGraphVideo

/// Two pieces of footage, described rather than decoded: a name and a length in seconds.
struct Footage {
    var library = AssetLibrary()
    let interview: HandleID
    let cutaway: HandleID

    init() {
        interview = library.add(AssetInfo(name: "interview.mov", duration: 10))
        cutaway = library.add(AssetInfo(name: "cutaway.mov", duration: 10))
    }
}

/// Builds a timeline: six seconds of the interview, with the cutaway arriving at three seconds.
func makeTimeline(using footage: Footage) throws -> GraphEditor {
    let registries = VideoPack.makeRegistries()
    let editor = GraphEditor(nodes: registries.nodes, types: registries.types)

    func add(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:]) throws -> NodeID {
        let node = Node(typeID: type, properties: properties)
        try editor.apply(.addNode(node: node))
        return node.id
    }
    func link(_ from: NodeID, _ output: PortID, _ to: NodeID, _ input: PortID) throws {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: from, port: output, direction: .output),
            target: PortAddress(node: to, port: input, direction: .input)))
    }

    // A sequence plays its clips one after another, starting at `offset` seconds on the timeline.
    func sequence(of asset: HandleID, offset: Double) throws -> NodeID {
        let clip = try add("video.clip", ["asset": .handle(asset)])
        let trim = try add("video.trim", ["start": 0.0, "end": 6.0])
        let sequence = try add("video.sequence", ["offset": .double(offset)])
        try link(clip, "clip", trim, "clip")
        try link(trim, "result", sequence, "clip_1")
        return sequence
    }
    let interview = try sequence(of: footage.interview, offset: 0)
    let cutaway = try sequence(of: footage.cutaway, offset: 3)

    // From 3 s to 4 s, fade from one to the other.
    let transition = try add("video.transition", ["kind": "crossfade", "start": 3.0, "duration": 1.0])
    try link(interview, "frame", transition, "a")
    try link(cutaway, "frame", transition, "b")
    let render = try add("video.render")
    try link(transition, "frame", render, "frame")

    return editor
}

/// Something that can say what the picture is at any moment.
func makeRenderer(for editor: GraphEditor, using footage: Footage) throws -> VideoRenderer {
    try VideoRenderer(
        graph: editor.graph, registry: editor.nodes, assets: footage.library, frameRate: 10)
}
