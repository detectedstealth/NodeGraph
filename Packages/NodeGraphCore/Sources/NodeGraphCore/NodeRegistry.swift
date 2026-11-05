import Collections

/// Maps node type ids to their definitions.
///
/// A value type, injected where needed rather than global. Packs register into it during setup.
///
/// Definitions are plain data (`Codable`, exportable as a schema); the code that runs a node
/// is registered beside its definition and kept separately, so a definition can be described
/// or shown without being executable.
public struct NodeRegistry: Sendable {
    private var definitions: OrderedDictionary<NodeTypeID, NodeDefinition> = [:]
    private var executors: [NodeTypeID: NodeExecutor] = [:]

    public init() {}

    /// All definitions in registration order.
    public var registeredDefinitions: [NodeDefinition] { Array(definitions.values) }

    /// Registers a definition, replacing any earlier one (and its executor) with the same type id.
    ///
    /// - Parameter execute: What runs the node. Nil for definitions that are only displayed.
    public mutating func register(_ definition: NodeDefinition, execute: NodeExecutor? = nil) {
        definitions[definition.typeID] = definition
        executors[definition.typeID] = execute
    }

    /// The code that runs nodes of this type, if any was registered.
    public func executor(for typeID: NodeTypeID) -> NodeExecutor? {
        executors[typeID]
    }

    public func definition(for typeID: NodeTypeID) -> NodeDefinition? {
        definitions[typeID]
    }

    /// A node's frame in graph space: its own size, else its definition's default size, else
    /// zero-sized when the type is unregistered.
    public func frame(of node: Node) -> GraphRect {
        let size = node.size ?? definition(for: node.typeID)?.defaultSize ?? GraphSize(width: 0, height: 0)
        return GraphRect(origin: node.position, size: size)
    }
}
