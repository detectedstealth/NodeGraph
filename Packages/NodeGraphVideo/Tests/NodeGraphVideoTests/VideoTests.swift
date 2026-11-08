import Foundation
import NodeGraphCore
import Synchronization
import Testing
@testable import NodeGraphVideo

private let registries = VideoPack.makeRegistries()

/// Collects what the render node delivers.
private final class Recorder: FrameSink {
    private let log = Mutex<[(frame: VideoFrame, seconds: Double)]>([])
    func consume(_ frame: VideoFrame, at seconds: Double) { log.withLock { $0.append((frame, seconds)) } }
    var frames: [(frame: VideoFrame, seconds: Double)] { log.withLock { $0 } }
}

private struct Rig {
    let editor = GraphEditor(nodes: registries.nodes, types: registries.types)
    var assets = AssetLibrary()
    /// Two ten-second assets.
    let a: HandleID, b: HandleID

    init() {
        var library = AssetLibrary()
        a = library.add(AssetInfo(name: "a.mov", duration: 10))
        b = library.add(AssetInfo(name: "b.mov", duration: 10))
        assets = library
    }

    @discardableResult
    func add(_ type: NodeTypeID, _ properties: [PropertyID: GraphValue] = [:]) throws -> NodeID {
        let node = Node(typeID: type, properties: properties)
        try editor.apply(.addNode(node: node))
        return node.id
    }

    func link(_ a: NodeID, _ out: PortID, _ b: NodeID, _ input: PortID) throws {
        try editor.connect(ConnectionProposal(
            source: PortAddress(node: a, port: out, direction: .output),
            target: PortAddress(node: b, port: input, direction: .input)))
    }

    /// A clip of `asset`, optionally trimmed.
    func clip(_ asset: HandleID, trim: ClosedRange<Double>? = nil) throws -> NodeID {
        let clip = try add("video.clip", ["asset": .handle(asset)])
        guard let trim else { return clip }
        let trimmed = try add("video.trim", ["start": .double(trim.lowerBound), "end": .double(trim.upperBound)])
        try link(clip, "clip", trimmed, "clip")
        return trimmed
    }

    func port(of node: NodeID) -> PortID { editor.graph.nodes[node]?.typeID == "video.clip" ? "clip" : "result" }

    /// A sequence of the clips, from `offset`.
    func sequence(_ clips: [NodeID], offset: Double = 0) throws -> NodeID {
        let sequence = try add("video.sequence", ["offset": .double(offset)])
        for (n, clip) in clips.enumerated() { try link(clip, port(of: clip), sequence, PortID("clip_\(n + 1)")) }
        return sequence
    }

    func render(_ source: NodeID, _ port: PortID = "frame", sink: (any FrameSink)? = nil) throws -> VideoRenderer {
        let render = try add("video.render")
        try link(source, port, render, "frame")
        return try VideoRenderer(
            graph: editor.graph, registry: editor.nodes, assets: assets, sink: sink, frameRate: 10)
    }
}

/// The layer at `index`; records an issue and returns a blank one if there is none, so `#expect`
/// lines stay free of `try`.
private func layer(_ frame: VideoFrame, _ index: Int = 0) -> VideoLayer {
    if frame.layers.indices.contains(index) { return frame.layers[index] }
    Issue.record("The frame has \(frame.layers.count) layers, not \(index + 1)")
    return VideoLayer(asset: HandleID(uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))), sourceTime: -1)
}

// MARK: Sequence

@Test func aSequencePlaysTrimmedClipsOneAfterAnother() async throws {
    let rig = Rig()
    let first = try rig.clip(rig.a, trim: 2...6), second = try rig.clip(rig.b)
    let renderer = try rig.render(rig.sequence([first, second]))

    let start = try await renderer.frame(at: 0)
    #expect(layer(start).asset == rig.a && layer(start).sourceTime == 2)
    let late = try await renderer.frame(at: 3.5)
    #expect(layer(late).sourceTime == 5.5)
    // The first clip is 4 s long, so the second starts at 4.
    let next = try await renderer.frame(at: 4.5)
    #expect(layer(next).asset == rig.b && layer(next).sourceTime == 0.5)
    #expect(try await renderer.frame(at: 14).layers.isEmpty)
}

@Test func aSequenceOffsetMovesItOnTheTimeline() async throws {
    let rig = Rig()
    let renderer = try rig.render(rig.sequence([rig.clip(rig.a, trim: 0...2)], offset: 5))
    #expect(try await renderer.frame(at: 4.9).layers.isEmpty)
    #expect(layer(try await renderer.frame(at: 5.5)).sourceTime == 0.5)
    #expect(try await renderer.frame(at: 7).layers.isEmpty)
}

@Test func aSequenceReportsItsDuration() async throws {
    let rig = Rig()
    let sequence = try rig.sequence([rig.clip(rig.a, trim: 2...6), rig.clip(rig.b, trim: 1...3)])
    var services = ServiceContainer()
    services.register(rig.assets)
    let runner = try GraphRunner(graph: rig.editor.graph, registry: rig.editor.nodes, services: services)
    let tick = await runner.step(at: .zero)
    #expect(tick.outputs(of: sequence)?.values["duration"] == .double(6))
}

// MARK: Transitions

/// A plays 0...6 s of asset a, B plays from 3 s on asset b; the transition runs 3 s to 4 s.
private func transitionRig(_ kind: String) throws -> (Rig, VideoRenderer) {
    let rig = Rig()
    let a = try rig.sequence([rig.clip(rig.a, trim: 0...6)])
    let b = try rig.sequence([rig.clip(rig.b, trim: 0...6)], offset: 3)
    let transition = try rig.add("video.transition", ["kind": .string(kind), "start": 3.0, "duration": 1.0])
    try rig.link(a, "frame", transition, "a")
    try rig.link(b, "frame", transition, "b")
    return (rig, try rig.render(transition))
}

@Test func aCrossfadeBlendsByProgress() async throws {
    let (rig, renderer) = try transitionRig("crossfade")
    let before = try await renderer.frame(at: 2)
    #expect(before.layers.count == 1 && (layer(before).asset) == rig.a && (layer(before).opacity) == 1)
    let middle = try await renderer.frame(at: 3.5)
    #expect(middle.layers.count == 2)
    #expect(layer(middle, 0).asset == rig.a && layer(middle, 0).opacity == 0.5 && layer(middle, 0).sourceTime == 3.5)
    #expect(layer(middle, 1).asset == rig.b && layer(middle, 1).opacity == 0.5 && layer(middle, 1).sourceTime == 0.5)
    let after = try await renderer.frame(at: 5)
    #expect(after.layers.count == 1 && (layer(after).asset) == rig.b)
}

@Test func dipToBlackFadesOutThenIn() async throws {
    let (rig, renderer) = try transitionRig("dipToBlack")
    let early = try await renderer.frame(at: 3.25)
    #expect(early.layers.count == 1 && (layer(early).asset) == rig.a && abs(layer(early).opacity - 0.5) < 1e-12)
    #expect(try await renderer.frame(at: 3.5).layers.isEmpty)
    let late = try await renderer.frame(at: 3.75)
    #expect(late.layers.count == 1 && (layer(late).asset) == rig.b && abs(layer(late).opacity - 0.5) < 1e-12)
}

@Test func aWipeRevealsTheNextClipFromTheLeft() async throws {
    let (rig, renderer) = try transitionRig("wipe")
    let middle = try await renderer.frame(at: 3.25)
    #expect(middle.layers.count == 2)
    #expect(layer(middle, 0).asset == rig.a && layer(middle, 0).reveal == 1)
    #expect(layer(middle, 1).asset == rig.b && layer(middle, 1).reveal == 0.25)
}

// MARK: Effects and rendering

@Test func anEffectIsAddedToEveryLayerAndCanBeAnimated() async throws {
    let rig = Rig()
    let sequence = try rig.sequence([rig.clip(rig.a)])
    let effect = try rig.add("video.effect", ["kind": "blur"])
    // Amount follows the clock, so the effect ramps up over the run.
    let time = try rig.add("util.time")
    try rig.link(sequence, "frame", effect, "frame")
    try rig.link(time, "elapsed", effect, "amount")
    let renderer = try rig.render(effect, "result")
    #expect(layer(try await renderer.frame(at: 0)).effects == [VideoEffect(kind: "blur", amount: 0)])
    #expect(layer(try await renderer.frame(at: 2)).effects == [VideoEffect(kind: "blur", amount: 2)])
}

@Test func theRenderNodeDeliversEachFrameToTheSink() async throws {
    let rig = Rig()
    let recorder = Recorder()
    let renderer = try rig.render(rig.sequence([rig.clip(rig.a, trim: 0...1)]), sink: recorder)
    let frames = try await renderer.frames(duration: 1.5)
    // 10 frames per second for 1.5 s; the clip is only 1 s long.
    #expect(frames.count == 15)
    #expect(frames.prefix(10).allSatisfy { $0.layers.count == 1 } && frames.suffix(5).allSatisfy { $0.layers.isEmpty })
    #expect(recorder.frames.map(\.seconds) == (0..<15).map { Double($0) / 10 })
    #expect(recorder.frames.map(\.frame) == frames)
}

@Test func framesDoNotDependOnTheOrderTheyAreAskedFor() async throws {
    let (_, renderer) = try transitionRig("crossfade")
    let times = [0.0, 3.5, 1, 4.5, 3.25, 0]
    var forward: [VideoFrame] = [], backward: [VideoFrame] = []
    for t in times { forward.append(try await renderer.frame(at: t)) }
    for t in times.reversed() { backward.append(try await renderer.frame(at: t)) }
    #expect(forward == backward.reversed())
}

// MARK: Errors

@Test func aTrimOutsideTheClipFails() async throws {
    let rig = Rig()
    let renderer = try rig.render(rig.sequence([rig.clip(rig.a, trim: 4...12)]))
    await #expect(throws: VideoRenderError.self) { try await renderer.frame(at: 0) }
}

@Test func aClipNeedsAnAssetTheLibraryKnows() async throws {
    let rig = Rig()
    let none = try rig.add("video.clip")
    await #expect(throws: VideoRenderError.nodeFailed("No asset chosen")) {
        try await rig.render(rig.sequence([none])).frame(at: 0)
    }

    var other = Rig()
    let unknown = try other.add("video.clip", ["asset": .handle(other.a)])
    other.assets = AssetLibrary()
    await #expect(throws: VideoRenderError.nodeFailed("The asset is not in the library")) {
        try await other.render(other.sequence([unknown])).frame(at: 0)
    }
}

@Test func aGraphWithoutARenderNodeIsRefused() async throws {
    let rig = Rig()
    #expect(throws: VideoRenderError.noRenderNode) {
        try VideoRenderer(graph: rig.editor.graph, registry: rig.editor.nodes, assets: rig.assets)
    }
}

@Test func frameValuesRoundTripThroughGraphValues() throws {
    let frame = VideoFrame(layers: [VideoLayer(
        asset: HandleID(), sourceTime: 1.5, opacity: 0.25, reveal: 0.5, effects: [VideoEffect(kind: "blur", amount: 3)])])
    #expect(VideoFrame(value: frame.value) == frame)
    #expect(VideoFrame(value: .int(1)) == nil)
}
