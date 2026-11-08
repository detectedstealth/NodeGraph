import NodeGraphCore

/// What the graph knows about a media file. The file itself stays outside the graph; nodes refer
/// to it by `HandleID`.
public struct AssetInfo: Hashable, Sendable {
    public var name: String
    /// Length in seconds.
    public var duration: Double

    public init(name: String, duration: Double) {
        self.name = name
        self.duration = duration
    }
}

/// The assets a run can use, handed to the runner as a service. A host fills it from its media
/// library; tests fill it by hand.
public struct AssetLibrary: Sendable {
    private var assets: [HandleID: AssetInfo]

    public init(_ assets: [HandleID: AssetInfo] = [:]) { self.assets = assets }

    public subscript(handle: HandleID) -> AssetInfo? {
        get { assets[handle] }
        set { assets[handle] = newValue }
    }

    /// Adds an asset and returns the handle to put in a clip node.
    @discardableResult
    public mutating func add(_ info: AssetInfo) -> HandleID {
        let handle = HandleID()
        assets[handle] = info
        return handle
    }
}

/// Receives each frame a Render node produces, for example to draw it or write it to a file.
/// Optional: a run without one still returns the frames.
public protocol FrameSink: Sendable {
    func consume(_ frame: VideoFrame, at seconds: Double)
}

/// A filter applied to one layer.
public struct VideoEffect: Hashable, Sendable {
    public var kind: String
    public var amount: Double

    public init(kind: String, amount: Double) {
        self.kind = kind
        self.amount = amount
    }
}

/// One picture in a frame: a moment of an asset, with how it is blended.
public struct VideoLayer: Hashable, Sendable {
    public var asset: HandleID
    /// Seconds into the asset to show.
    public var sourceTime: Double
    public var opacity: Double
    /// How much of the layer shows, from the left: 1 is all of it. Wipes animate this.
    public var reveal: Double
    public var effects: [VideoEffect]

    public init(asset: HandleID, sourceTime: Double, opacity: Double = 1, reveal: Double = 1, effects: [VideoEffect] = []) {
        self.asset = asset
        self.sourceTime = sourceTime
        self.opacity = opacity
        self.reveal = reveal
        self.effects = effects
    }
}

/// What to show at one moment: layers from bottom to top. No layers is black.
public struct VideoFrame: Hashable, Sendable {
    public var layers: [VideoLayer]

    public init(layers: [VideoLayer] = []) { self.layers = layers }
}

/// A span of an asset, in seconds of the asset.
public struct VideoClip: Hashable, Sendable {
    public var asset: HandleID
    public var sourceStart: Double
    public var sourceEnd: Double
    /// The whole asset's length, kept so a trim can be checked without the library.
    public var sourceDuration: Double

    public var duration: Double { sourceEnd - sourceStart }

    public init(asset: HandleID, sourceStart: Double, sourceEnd: Double, sourceDuration: Double) {
        self.asset = asset
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.sourceDuration = sourceDuration
    }
}

// MARK: Graph values

extension VideoEffect {
    var value: GraphValue { .object(["kind": .string(kind), "amount": .double(amount)]) }

    init?(value: GraphValue) {
        guard case .object(let fields) = value, let kind = fields["kind"]?.stringValue,
              let amount = fields["amount"]?.numberValue else { return nil }
        self.init(kind: kind, amount: amount)
    }
}

extension VideoLayer {
    var value: GraphValue {
        .object([
            "asset": .handle(asset), "sourceTime": .double(sourceTime), "opacity": .double(opacity),
            "reveal": .double(reveal), "effects": .array(effects.map(\.value)),
        ])
    }

    init?(value: GraphValue) {
        guard case .object(let fields) = value, case .handle(let asset)? = fields["asset"],
              let time = fields["sourceTime"]?.numberValue, let opacity = fields["opacity"]?.numberValue,
              let reveal = fields["reveal"]?.numberValue, case .array(let effects)? = fields["effects"]
        else { return nil }
        self.init(
            asset: asset, sourceTime: time, opacity: opacity, reveal: reveal,
            effects: effects.compactMap(VideoEffect.init(value:)))
    }
}

extension VideoFrame {
    /// The frame as a graph value: what flows over `video.frame` links.
    public var value: GraphValue { .object(["layers": .array(layers.map(\.value))]) }

    public init?(value: GraphValue) {
        guard case .object(let fields) = value, case .array(let layers)? = fields["layers"] else { return nil }
        self.init(layers: layers.compactMap(VideoLayer.init(value:)))
    }
}

extension VideoClip {
    var value: GraphValue {
        .object([
            "asset": .handle(asset), "start": .double(sourceStart), "end": .double(sourceEnd),
            "sourceDuration": .double(sourceDuration),
        ])
    }

    init?(value: GraphValue) {
        guard case .object(let fields) = value, case .handle(let asset)? = fields["asset"],
              let start = fields["start"]?.numberValue, let end = fields["end"]?.numberValue,
              let length = fields["sourceDuration"]?.numberValue else { return nil }
        self.init(asset: asset, sourceStart: start, sourceEnd: end, sourceDuration: length)
    }
}

extension PortType {
    /// A span of an asset: `GraphValue.object`, read with ``VideoClip``.
    public static let clip: PortType = "video.clip"
    /// What to show at the current time: read with ``VideoFrame``.
    public static let frame: PortType = "video.frame"
}
