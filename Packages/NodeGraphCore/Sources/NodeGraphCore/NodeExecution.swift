import Logging

/// The code that runs a node: reads its context, returns its outputs.
///
/// It runs concurrently with other nodes, so it must not touch shared mutable state; use
/// ``NodeContext/services`` for shared resources. Long work should call
/// ``NodeContext/checkCancellation()`` and ``NodeContext/reportProgress(_:message:)``.
public typealias NodeExecutor = @Sendable (NodeContext) async throws -> NodeOutputs

/// What a node produces: values on its data output ports and events on its trigger output ports.
///
/// The dictionary-literal form sets values only: `["sum": 3.0]`.
public struct NodeOutputs: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    /// Values by data output port.
    public var values: [PortID: GraphValue]
    /// Trigger output ports that fire this evaluation.
    public var triggers: Set<PortID>

    public init(_ values: [PortID: GraphValue] = [:], triggers: Set<PortID> = []) {
        self.values = values
        self.triggers = triggers
    }

    public init(dictionaryLiteral elements: (PortID, GraphValue)...) {
        values = Dictionary(elements, uniquingKeysWith: { _, last in last })
        triggers = []
    }

    /// No values and no triggers.
    public static let empty = NodeOutputs([:])

    public subscript(port: PortID) -> GraphValue? {
        get { values[port] }
        set { values[port] = newValue }
    }
}

/// Why a node's execution could not produce outputs. Executors may throw any error; these cover
/// the common cases.
public enum NodeExecutionError: Error, Hashable, Sendable {
    /// A required input has no link and no default.
    case missingInput(PortID)
    /// An input holds a value of the wrong kind.
    case invalidInput(PortID, expected: String)
    /// A required property is not defined for this node.
    case missingProperty(PropertyID)
    /// The node's type has no executor registered.
    case notExecutable(NodeTypeID)
    /// The executor returned a value for a port the definition does not declare.
    case undeclaredOutput(PortID)
    /// The executor wrote a value to a trigger port, or fired a data port.
    case wrongPortKind(PortID)
    case failed(String)
}

/// Where a node is in time during a run. Deterministic runs supply a fixed `delta`.
public struct ExecutionTime: Hashable, Sendable {
    /// Evaluation count, starting at 0.
    public var tick: Int
    /// Time since the run started.
    public var elapsed: Duration
    /// Time since the previous evaluation. Zero on the first evaluation of a real-time run;
    /// always the fixed step in a deterministic run.
    public var delta: Duration

    public init(tick: Int = 0, elapsed: Duration = .zero, delta: Duration = .zero) {
        self.tick = tick
        self.elapsed = elapsed
        self.delta = delta
    }

    /// `elapsed` in seconds.
    public var elapsedSeconds: Double { elapsed.seconds }
    /// `delta` in seconds.
    public var deltaSeconds: Double { delta.seconds }
}

extension Duration {
    /// The duration in seconds.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A progress report from a running node.
public struct NodeProgress: Hashable, Sendable {
    public var node: NodeID
    /// 0...1.
    public var fraction: Double
    public var message: String?
}

/// Shared resources available to executors, keyed by type: a clock, an asset store, a
/// connection to a robot. Values must be `Sendable`.
public struct ServiceContainer: Sendable {
    private var services: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Registers `service`, replacing any earlier service of the same type.
    public mutating func register<T: Sendable>(_ service: T) {
        services[ObjectIdentifier(T.self)] = service
    }

    /// The registered service of type `T`, or nil.
    public subscript<T: Sendable>(_ type: T.Type) -> T? {
        services[ObjectIdentifier(type)] as? T
    }
}

/// Everything a node's executor can see. Immutable and `Sendable`.
public struct NodeContext: Sendable {
    public let nodeID: NodeID
    public let definition: NodeDefinition
    /// Values arriving at input ports: linked values, else the port's default. Ports with
    /// neither are absent.
    public let inputs: [PortID: GraphValue]
    /// Property values: the node's overrides over the definition's defaults.
    public let properties: [PropertyID: GraphValue]
    /// Trigger input ports that received an event this evaluation.
    public let triggered: Set<PortID>
    public let time: ExecutionTime
    public let services: ServiceContainer
    /// Tagged with the node id and type.
    public let logger: Logger
    private let progressSink: @Sendable (NodeProgress) -> Void

    /// Builds the context for running `node`.
    ///
    /// - Parameters:
    ///   - linkedInputs: Values already delivered over links, keyed by input port.
    ///   - triggered: Trigger input ports that received an event.
    public init(
        node: Node,
        definition: NodeDefinition,
        linkedInputs: [PortID: GraphValue] = [:],
        triggered: Set<PortID> = [],
        time: ExecutionTime = ExecutionTime(),
        services: ServiceContainer = ServiceContainer(),
        logger: Logger = Logger(label: "NodeGraph.node"),
        onProgress: @escaping @Sendable (NodeProgress) -> Void = { _ in }
    ) {
        var inputs = linkedInputs
        for port in definition.inputs where port.kind == .data && inputs[port.id] == nil {
            if let value = port.defaultValue { inputs[port.id] = value }
        }
        var properties = Dictionary(uniqueKeysWithValues: definition.properties.map { ($0.id, $0.defaultValue) })
        properties.merge(node.properties) { _, override in override }

        var tagged = logger
        tagged[metadataKey: "node"] = "\(node.id)"
        tagged[metadataKey: "type"] = "\(definition.typeID)"

        self.nodeID = node.id
        self.definition = definition
        self.inputs = inputs
        self.properties = properties
        self.triggered = triggered
        self.time = time
        self.services = services
        self.logger = tagged
        self.progressSink = onProgress
    }

    /// The value at an input port.
    /// - Throws: ``NodeExecutionError/missingInput(_:)`` if there is none.
    public func input(_ port: PortID) throws -> GraphValue {
        guard let value = inputs[port] else { throw NodeExecutionError.missingInput(port) }
        return value
    }

    /// A number at an input port, accepting `.int` or `.double`.
    public func number(_ port: PortID) throws -> Double {
        guard let value = try input(port).numberValue else {
            throw NodeExecutionError.invalidInput(port, expected: "number")
        }
        return value
    }

    /// A bool at an input port.
    public func bool(_ port: PortID) throws -> Bool {
        guard let value = try input(port).boolValue else {
            throw NodeExecutionError.invalidInput(port, expected: "bool")
        }
        return value
    }

    /// A string at an input port.
    public func string(_ port: PortID) throws -> String {
        guard let value = try input(port).stringValue else {
            throw NodeExecutionError.invalidInput(port, expected: "string")
        }
        return value
    }

    /// Whether a trigger input port received an event this evaluation.
    public func didTrigger(_ port: PortID) -> Bool {
        triggered.contains(port)
    }

    /// A property value.
    /// - Throws: ``NodeExecutionError/missingProperty(_:)`` if the node has no such property.
    public func property(_ id: PropertyID) throws -> GraphValue {
        guard let value = properties[id] else { throw NodeExecutionError.missingProperty(id) }
        return value
    }

    /// Reports progress, clamped to 0...1. Cheap; safe to call often.
    public func reportProgress(_ fraction: Double, message: String? = nil) {
        let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        progressSink(NodeProgress(node: nodeID, fraction: clamped, message: message))
    }

    /// Throws `CancellationError` if the run was cancelled. Call in long loops.
    public func checkCancellation() throws {
        try Task.checkCancellation()
    }
}
