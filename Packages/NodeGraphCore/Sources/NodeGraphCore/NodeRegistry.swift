import Collections

/// Maps node type ids to their definitions.
///
/// A value type, injected where needed rather than global. Packs register into it during setup.
public struct NodeRegistry: Hashable, Sendable {
    private var definitions: OrderedDictionary<NodeTypeID, NodeDefinition> = [:]

    public init() {}

    /// All definitions in registration order.
    public var registeredDefinitions: [NodeDefinition] { Array(definitions.values) }

    /// Registers a definition, replacing any earlier one with the same type id.
    public mutating func register(_ definition: NodeDefinition) {
        definitions[definition.typeID] = definition
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
