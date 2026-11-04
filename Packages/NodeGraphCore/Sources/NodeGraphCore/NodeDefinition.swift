/// Identifies a node type registered by a pack, for example `"math.add"`.
public struct NodeTypeID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Describes one port of a node type.
public struct PortDefinition: Hashable, Sendable, Codable {
    public var id: PortID
    public var displayName: String
    public var direction: PortDirection
    public var kind: PortKind
    public var type: PortType
    /// Value an unconnected input falls back to. Ignored for outputs and trigger ports.
    public var defaultValue: GraphValue?
    /// Whether more than one link may attach. Inputs default to one link, outputs to many.
    public var allowsMultipleLinks: Bool

    public init(
        id: PortID,
        displayName: String? = nil,
        direction: PortDirection,
        kind: PortKind = .data,
        type: PortType = .any,
        defaultValue: GraphValue? = nil,
        allowsMultipleLinks: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.direction = direction
        self.kind = kind
        self.type = type
        self.defaultValue = defaultValue
        self.allowsMultipleLinks = allowsMultipleLinks ?? (direction == .output)
    }
}

/// Class-level description of a node type, registered by a pack.
///
/// Holds only data. The execution function is added in Phase 2.
public struct NodeDefinition: Hashable, Sendable, Codable {
    public var typeID: NodeTypeID
    public var displayName: String
    public var category: String
    public var ports: [PortDefinition]
    public var properties: [PropertyDefinition]
    public var defaultSize: GraphSize

    public init(
        typeID: NodeTypeID,
        displayName: String,
        category: String = "",
        ports: [PortDefinition] = [],
        properties: [PropertyDefinition] = [],
        defaultSize: GraphSize = GraphSize(width: 160, height: 80)
    ) {
        self.typeID = typeID
        self.displayName = displayName
        self.category = category
        self.ports = ports
        self.properties = properties
        self.defaultSize = defaultSize
    }

    /// Inputs in declaration order.
    public var inputs: [PortDefinition] { ports.filter { $0.direction == .input } }

    /// Outputs in declaration order.
    public var outputs: [PortDefinition] { ports.filter { $0.direction == .output } }

    /// Finds a port by id and direction. Ids are unique per direction, so both are needed.
    public func port(_ id: PortID, direction: PortDirection) -> PortDefinition? {
        ports.first { $0.id == id && $0.direction == direction }
    }

    public func property(_ id: PropertyID) -> PropertyDefinition? {
        properties.first { $0.id == id }
    }

    /// Reasons a definition is malformed, empty when it is well formed.
    public var problems: [String] {
        var problems: [String] = []
        var seenPorts = Set<PortKey>()
        for port in ports where !seenPorts.insert(PortKey(id: port.id, direction: port.direction)).inserted {
            problems.append("Duplicate \(port.direction.rawValue) port \"\(port.id)\"")
        }
        var seenProperties = Set<PropertyID>()
        for property in properties {
            if !seenProperties.insert(property.id).inserted {
                problems.append("Duplicate property \"\(property.id)\"")
            }
            if !property.isValid(property.defaultValue) {
                problems.append("Default of property \"\(property.id)\" does not satisfy its kind")
            }
        }
        return problems
    }
}

private struct PortKey: Hashable {
    var id: PortID
    var direction: PortDirection
}
