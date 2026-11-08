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
    /// The ``DynamicPortGroup`` this port was generated from, or nil for a fixed port.
    public var group: String?
    /// The mark drawn for the port. Nil picks one: a diamond for triggers, else the port type's
    /// shape (``PortTypeInfo/shape``), else a circle.
    public var shape: PortShape?

    public init(
        id: PortID,
        displayName: String? = nil,
        direction: PortDirection,
        kind: PortKind = .data,
        type: PortType = .any,
        defaultValue: GraphValue? = nil,
        allowsMultipleLinks: Bool? = nil,
        group: String? = nil,
        shape: PortShape? = nil
    ) {
        self.shape = shape
        self.group = group
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.direction = direction
        self.kind = kind
        self.type = type
        self.defaultValue = defaultValue
        self.allowsMultipleLinks = allowsMultipleLinks ?? (direction == .output)
    }
}

/// A numbered run of similar ports whose length each node instance chooses, such as the inputs of
/// a sum node. The ports are named `<id>_1`, `<id>_2`, and so on, and always come after a
/// definition's fixed ports. Instances store only the count (see ``Node/portCounts``); links are
/// kept when the count changes, except links to ports that no longer exist.
public struct DynamicPortGroup: Hashable, Sendable, Codable {
    /// How the count follows the links.
    public enum Resizing: String, Hashable, Sendable, Codable {
        /// Only a ``GraphCommand/setPortCount(node:group:count:)`` changes it.
        case manual
        /// After every change to the node's links, keep exactly one unlinked port after the last
        /// linked one, and never fewer than ``initialCount`` or more than ``maximum``: connecting the
        /// last port adds another, and unlinking trailing ports removes them. A linked port is
        /// never removed.
        case keepOneFree
    }

    /// Names the group and prefixes its port ids. Must not contain a space.
    public var id: String
    /// Shown before the port number, for example `"Input"` gives "Input 1".
    public var displayName: String
    public var direction: PortDirection
    public var kind: PortKind
    public var type: PortType
    public var defaultValue: GraphValue?
    public var allowsMultipleLinks: Bool
    /// Fewest ports an instance may have.
    public var minimum: Int
    /// Most ports an instance may have, or nil for no limit.
    public var maximum: Int?
    /// Ports a new instance starts with.
    public var initialCount: Int
    public var resizing: Resizing

    public init(
        id: String,
        displayName: String? = nil,
        direction: PortDirection = .input,
        kind: PortKind = .data,
        type: PortType = .any,
        defaultValue: GraphValue? = nil,
        allowsMultipleLinks: Bool? = nil,
        minimum: Int = 1,
        maximum: Int? = nil,
        initialCount: Int? = nil,
        resizing: Resizing = .manual
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.direction = direction
        self.kind = kind
        self.type = type
        self.defaultValue = defaultValue
        self.allowsMultipleLinks = allowsMultipleLinks ?? (direction == .output)
        self.minimum = minimum
        self.maximum = maximum
        self.initialCount = initialCount ?? minimum
        self.resizing = resizing
    }

    /// The id of the `n`th port, counting from 1.
    public func portID(_ n: Int) -> PortID { PortID("\(id)_\(n)") }

    /// The count for an instance that asked for `requested`, kept within the limits.
    public func clamped(_ requested: Int?) -> Int {
        min(max(requested ?? initialCount, minimum), maximum ?? Int.max)
    }

    /// The `n`th port.
    public func port(_ n: Int) -> PortDefinition {
        PortDefinition(
            id: portID(n), displayName: "\(displayName) \(n)", direction: direction, kind: kind, type: type,
            defaultValue: kind == .data ? defaultValue : nil, allowsMultipleLinks: allowsMultipleLinks, group: id)
    }
}

/// Class-level description of a node type, registered by a pack.
///
/// Holds only data. The execution function is added in Phase 2.
public struct NodeDefinition: Hashable, Sendable, Codable {
    public var typeID: NodeTypeID
    public var displayName: String
    public var category: String
    /// The fixed ports. Instances with dynamic ports have more; see ``resolved(for:)``.
    public var ports: [PortDefinition]
    /// Groups of ports whose count each instance chooses.
    public var dynamicPorts: [DynamicPortGroup]
    public var properties: [PropertyDefinition]
    public var defaultSize: GraphSize
    /// Marks a delay or memory node whose outputs carry the value from the previous evaluation.
    /// Links leaving it do not order execution, so they may close a loop without being a cycle.
    public var isFeedback: Bool
    /// Declares that the node's outputs depend only on its inputs and properties: no clock, no
    /// randomness, no outside state. The runner may then reuse the previous outputs instead of
    /// running the node again when none of those changed. Defaults to false, which always runs.
    public var isPure: Bool
    /// The outline nodes of this type have unless a node overrides it. Nil means ``NodeShape/round``.
    public var shape: NodeShape?
    /// The title bar style nodes of this type have unless a node overrides it. Nil means ``NodeTitleMode/normal``.
    public var titleMode: NodeTitleMode?
    /// A sentence or two on what the node does, shown in the add-node palette and the inspector.
    /// Nil or empty means none.
    public var help: String?

    public init(
        typeID: NodeTypeID,
        displayName: String,
        category: String = "",
        ports: [PortDefinition] = [],
        dynamicPorts: [DynamicPortGroup] = [],
        properties: [PropertyDefinition] = [],
        defaultSize: GraphSize = GraphSize(width: 160, height: 80),
        isFeedback: Bool = false,
        isPure: Bool = false,
        shape: NodeShape? = nil,
        titleMode: NodeTitleMode? = nil,
        help: String? = nil
    ) {
        self.help = help
        self.shape = shape
        self.titleMode = titleMode
        self.dynamicPorts = dynamicPorts
        self.typeID = typeID
        self.displayName = displayName
        self.category = category
        self.ports = ports
        self.properties = properties
        self.defaultSize = defaultSize
        self.isFeedback = isFeedback
        self.isPure = isPure
    }

    /// The definition as one instance sees it: the fixed ports followed by each dynamic group's
    /// ports, as many as that instance's ``Node/portCounts`` asks for (within the group's limits).
    /// A definition without dynamic ports is returned as is.
    public func resolved(for node: Node) -> NodeDefinition {
        guard !dynamicPorts.isEmpty else { return self }
        var copy = self
        copy.ports = ports.filter { $0.group == nil }
            + dynamicPorts.flatMap { group -> [PortDefinition] in
                let count = group.clamped(node.portCounts[group.id])
                return count > 0 ? (1...count).map(group.port) : []
            }
        return copy
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
        var seenGroups = Set<String>()
        for group in dynamicPorts {
            if !seenGroups.insert(group.id).inserted { problems.append("Duplicate port group \"\(group.id)\"") }
            if group.id.isEmpty || group.id.contains(" ") { problems.append("Port group id \"\(group.id)\" must be non-empty and have no spaces") }
            if group.minimum < 0 { problems.append("Port group \"\(group.id)\" has a negative minimum") }
            if let maximum = group.maximum, maximum < group.minimum {
                problems.append("Port group \"\(group.id)\" has a maximum below its minimum")
            }
            if group.initialCount != group.clamped(group.initialCount) {
                problems.append("Port group \"\(group.id)\" starts outside its limits")
            }
            let generated = Set((1...max(group.maximum ?? group.initialCount, group.initialCount, 1)).map(group.portID))
            for port in ports where port.direction == group.direction && generated.contains(port.id) {
                problems.append("Fixed port \"\(port.id)\" collides with a port of group \"\(group.id)\"")
            }
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
