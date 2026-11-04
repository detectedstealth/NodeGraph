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
}
