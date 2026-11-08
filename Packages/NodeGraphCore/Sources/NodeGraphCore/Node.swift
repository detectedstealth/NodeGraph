/// Whether and how a node takes part in execution.
public enum NodeMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Runs every evaluation.
    case always
    /// Switched off. Does not run, and nodes that depend on it are skipped too.
    case never
    /// Does not run and publishes no outputs. Nodes after it still run, with their inputs
    /// unlinked (defaults apply).
    case muted
    /// Does not run. Each data output takes the value of the first unused data input of the same
    /// type; trigger inputs pass to trigger outputs in order. Works for any node, even one whose
    /// pack is missing.
    case bypassed
    /// Runs only in evaluations where at least one trigger input fired, and keeps publishing its
    /// last outputs in between.
    case onTrigger
}

/// A node instance. Holds placement and settings only; never runtime state.
public struct Node: Hashable, Sendable {
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
    /// Overrides the definition's outline when set.
    public var shape: NodeShape?
    /// Overrides the definition's title bar style when set.
    public var titleMode: NodeTitleMode?
    /// Values that differ from the definition's defaults, keyed by property id.
    public var properties: [PropertyID: GraphValue]
    /// How many ports each of the definition's dynamic port groups has on this node. Groups not
    /// listed have their initial count. Change it with ``GraphCommand/setPortCount(node:group:count:)``,
    /// which keeps this canonical by leaving out counts equal to the initial one.
    public var portCounts: [String: Int]
    /// Names this node shows for its ports instead of the definition's, keyed by
    /// ``portLabelKey(_:direction:)``. Only the shown name changes: links and execution use the port
    /// id. Change it with ``GraphCommand/setPortLabel(node:port:direction:label:)``. A label for a
    /// port that does not exist now (a dynamic port that was removed) is kept and shows again if
    /// the port returns.
    public var portLabels: [String: String]

    /// The key of a port's entry in ``portLabels``.
    public static func portLabelKey(_ port: PortID, direction: PortDirection) -> String {
        "\(direction.rawValue):\(port.rawValue)"
    }

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
        properties: [PropertyID: GraphValue] = [:],
        portCounts: [String: Int] = [:],
        shape: NodeShape? = nil,
        titleMode: NodeTitleMode? = nil,
        portLabels: [String: String] = [:]
    ) {
        self.portLabels = portLabels
        self.shape = shape
        self.titleMode = titleMode
        self.portCounts = portCounts
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

    /// The outline to draw: the node's own, else the definition's, else ``NodeShape/round``.
    public func resolvedShape(in definition: NodeDefinition?) -> NodeShape {
        shape ?? definition?.shape ?? .round
    }

    /// The title bar style to draw: the node's own, else the definition's, else ``NodeTitleMode/normal``.
    public func resolvedTitleMode(in definition: NodeDefinition?) -> NodeTitleMode {
        titleMode ?? definition?.titleMode ?? .normal
    }

    /// The stored value for a property, or the definition's default when unset.
    public func value(of property: PropertyID, in definition: NodeDefinition) -> GraphValue? {
        properties[property] ?? definition.property(property)?.defaultValue
    }
}

// MARK: - Codable

/// Properties encode as a JSON object keyed by property id. A dictionary keyed by a
/// string-backed type would otherwise encode as a flat key/value array in unspecified order.
extension Node: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, typeID, position, size, title, color, mode, isCollapsed, isPinned, properties, portCounts, shape, titleMode, portLabels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(NodeID.self, forKey: .id),
            typeID: try container.decode(NodeTypeID.self, forKey: .typeID),
            position: try container.decode(GraphPoint.self, forKey: .position),
            size: try container.decodeIfPresent(GraphSize.self, forKey: .size),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            color: try container.decodeIfPresent(RGBAColor.self, forKey: .color),
            mode: try container.decodeIfPresent(NodeMode.self, forKey: .mode) ?? .always,
            isCollapsed: try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            properties: Dictionary(
                uniqueKeysWithValues: (try container.decodeIfPresent(
                    [String: GraphValue].self, forKey: .properties) ?? [:])
                    .map { (PropertyID($0.key), $0.value) }),
            portCounts: try container.decodeIfPresent([String: Int].self, forKey: .portCounts) ?? [:],
            shape: try container.decodeIfPresent(NodeShape.self, forKey: .shape),
            titleMode: try container.decodeIfPresent(NodeTitleMode.self, forKey: .titleMode),
            portLabels: try container.decodeIfPresent([String: String].self, forKey: .portLabels) ?? [:]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(typeID, forKey: .typeID)
        try container.encode(position, forKey: .position)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encode(mode, forKey: .mode)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(
            Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) }),
            forKey: .properties)
        if !portCounts.isEmpty { try container.encode(portCounts, forKey: .portCounts) }
        try container.encodeIfPresent(shape, forKey: .shape)
        try container.encodeIfPresent(titleMode, forKey: .titleMode)
        if !portLabels.isEmpty { try container.encode(portLabels, forKey: .portLabels) }
    }
}
