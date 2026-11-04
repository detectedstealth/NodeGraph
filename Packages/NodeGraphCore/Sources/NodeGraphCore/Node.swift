/// Whether and how a node takes part in execution.
public enum NodeMode: String, Hashable, Sendable, Codable, CaseIterable {
    case always
    case never
    /// Skipped; outputs are empty.
    case muted
    /// Skipped; inputs pass through to matching outputs.
    case bypassed
    case onTrigger
}

/// A node instance. Holds placement and settings only; never runtime state.
public struct Node: Hashable, Sendable, Codable {
    public var id: NodeID
    public var typeID: NodeTypeID
    public var position: GraphPoint
    /// Overrides the definition's default size when set.
    public var size: GraphSize?
    /// Overrides the definition's display name when set.
    public var title: String?
    public var color: RGBAColor?
    public var mode: NodeMode
    public var isCollapsed: Bool
    public var isPinned: Bool
    /// Values that differ from the definition's defaults, keyed by property id.
    public var properties: [PropertyID: GraphValue]

    public init(
        id: NodeID = NodeID(),
        typeID: NodeTypeID,
        position: GraphPoint = .zero,
        size: GraphSize? = nil,
        title: String? = nil,
        color: RGBAColor? = nil,
        mode: NodeMode = .always,
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        properties: [PropertyID: GraphValue] = [:]
    ) {
        self.id = id
        self.typeID = typeID
        self.position = position
        self.size = size
        self.title = title
        self.color = color
        self.mode = mode
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.properties = properties
    }

    /// The node's size, falling back to the definition's default.
    public func resolvedSize(in definition: NodeDefinition) -> GraphSize {
        size ?? definition.defaultSize
    }

    /// The node's frame in graph space.
    public func frame(in definition: NodeDefinition) -> GraphRect {
        GraphRect(origin: position, size: resolvedSize(in: definition))
    }

    /// The stored value for a property, or the definition's default when unset.
    public func value(of property: PropertyID, in definition: NodeDefinition) -> GraphValue? {
        properties[property] ?? definition.property(property)?.defaultValue
    }
}
