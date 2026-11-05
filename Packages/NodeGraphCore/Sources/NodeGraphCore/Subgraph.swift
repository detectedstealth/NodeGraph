import Foundation
import Collections

/// Identifies a subgraph definition. Stable across renames and saves.
public struct SubgraphID: GraphIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

extension NodeTypeID {
    /// Prefix shared by the node types of all subgraph instances.
    static let subgraphPrefix = "subgraph."

    /// The subgraph this node type is an instance of, or nil for any other node type.
    public var subgraphID: SubgraphID? {
        guard rawValue.hasPrefix(Self.subgraphPrefix),
              let uuid = UUID(uuidString: String(rawValue.dropFirst(Self.subgraphPrefix.count)))
        else { return nil }
        return SubgraphID(uuid: uuid)
    }
}

/// An input of a subgraph, as seen from outside. Values arriving at the instance node are
/// delivered to every inner input port in ``targets``.
public struct SubgraphInput: Hashable, Sendable, Codable {
    /// The port id on instance nodes. Stable: links to instances survive renames of the display name.
    public var id: PortID
    public var displayName: String
    public var kind: PortKind
    public var type: PortType
    /// Used when the instance's input is not linked. Data inputs only.
    public var defaultValue: GraphValue?
    public var allowsMultipleLinks: Bool
    /// Inner input ports that receive the value.
    public var targets: [PortAddress]

    public init(
        id: PortID, displayName: String? = nil, kind: PortKind = .data, type: PortType = .any,
        defaultValue: GraphValue? = nil, allowsMultipleLinks: Bool = false, targets: [PortAddress] = []
    ) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.kind = kind
        self.type = type
        self.defaultValue = defaultValue
        self.allowsMultipleLinks = allowsMultipleLinks
        self.targets = targets
    }
}

/// An output of a subgraph, as seen from outside, fed by one inner output port.
public struct SubgraphOutput: Hashable, Sendable, Codable {
    public var id: PortID
    public var displayName: String
    public var kind: PortKind
    public var type: PortType
    /// The inner output port whose value (or trigger) appears on the instance.
    public var source: PortAddress?

    public init(
        id: PortID, displayName: String? = nil, kind: PortKind = .data, type: PortType = .any,
        source: PortAddress? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.kind = kind
        self.type = type
        self.source = source
    }
}

/// An inner node's property that an instance exposes as its own.
public struct PropertyTarget: Hashable, Sendable, Codable {
    public var node: NodeID
    public var property: PropertyID

    public init(node: NodeID, property: PropertyID) {
        self.node = node
        self.property = property
    }
}

/// A property of the instance node that sets one or more inner node properties.
public struct PromotedProperty: Hashable, Sendable, Codable {
    /// The property id on instance nodes.
    public var id: PropertyID
    public var displayName: String
    public var kind: PropertyKind
    public var defaultValue: GraphValue
    /// Inner properties that take the instance's value. The instance's value, when set,
    /// replaces whatever the inner node has.
    public var targets: [PropertyTarget]

    public init(
        id: PropertyID, displayName: String? = nil, kind: PropertyKind, defaultValue: GraphValue,
        targets: [PropertyTarget] = []
    ) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.kind = kind
        self.defaultValue = defaultValue
        self.targets = targets
    }
}

/// What a subgraph shows to the outside: its name, ports and properties. Edited as a unit by
/// ``GraphCommand/setSubgraphInterface(id:interface:)`` so links to instances stay consistent.
public struct SubgraphInterface: Hashable, Sendable, Codable {
    public var name: String
    public var category: String
    public var inputs: [SubgraphInput]
    public var outputs: [SubgraphOutput]
    public var properties: [PromotedProperty]

    public init(
        name: String, category: String = "Subgraph", inputs: [SubgraphInput] = [],
        outputs: [SubgraphOutput] = [], properties: [PromotedProperty] = []
    ) {
        self.name = name
        self.category = category
        self.inputs = inputs
        self.outputs = outputs
        self.properties = properties
    }
}

/// A reusable graph with a defined interface. Instances are ordinary nodes whose type is
/// ``typeID``; their ports and properties come from ``interface``, and executing one runs
/// ``graph``.
public struct SubgraphDefinition: Hashable, Sendable, Codable {
    public var id: SubgraphID
    public var interface: SubgraphInterface
    /// The inner graph. Exposed ports and promoted properties point into it by node id.
    public var graph: Graph

    public init(id: SubgraphID = SubgraphID(), interface: SubgraphInterface, graph: Graph = Graph()) {
        self.id = id
        self.interface = interface
        self.graph = graph
    }

    /// The node type of this subgraph's instances.
    public var typeID: NodeTypeID { NodeTypeID("\(NodeTypeID.subgraphPrefix)\(id)") }

    /// The definition instance nodes are created from, built from ``interface``.
    public var nodeDefinition: NodeDefinition {
        NodeDefinition(
            typeID: typeID,
            displayName: interface.name,
            category: interface.category,
            ports: interface.inputs.map {
                PortDefinition(
                    id: $0.id, displayName: $0.displayName, direction: .input, kind: $0.kind, type: $0.type,
                    defaultValue: $0.kind == .data ? $0.defaultValue : nil,
                    allowsMultipleLinks: $0.allowsMultipleLinks)
            } + interface.outputs.map {
                PortDefinition(id: $0.id, displayName: $0.displayName, direction: .output, kind: $0.kind, type: $0.type)
            },
            properties: interface.properties.map {
                PropertyDefinition(id: $0.id, displayName: $0.displayName, kind: $0.kind, defaultValue: $0.defaultValue)
            })
    }

    /// Ways the definition is inconsistent, empty when it is sound. Checks that ids are unique,
    /// every binding points at a real inner node and, where the node type is registered, a real
    /// port or property of the right direction and kind.
    ///
    /// A binding left dangling by deleting an inner node is reported here but is harmless at run
    /// time, and goes away again if the deletion is undone.
    public func problems(nodes registry: NodeRegistry) -> [String] {
        var problems: [String] = []
        func duplicates<T: Hashable>(_ values: [T]) -> [T] {
            var seen = Set<T>(), repeated: [T] = []
            for value in values where !seen.insert(value).inserted { repeated.append(value) }
            return repeated
        }
        for id in duplicates(interface.inputs.map(\.id)) { problems.append("Duplicate input \"\(id)\"") }
        for id in duplicates(interface.outputs.map(\.id)) { problems.append("Duplicate output \"\(id)\"") }
        for id in duplicates(interface.properties.map(\.id)) { problems.append("Duplicate property \"\(id)\"") }

        func check(_ address: PortAddress, direction: PortDirection, kind: PortKind, as label: String) {
            guard let node = graph.nodes[address.node] else {
                problems.append("\(label) points at a node that does not exist")
                return
            }
            guard address.direction == direction else {
                problems.append("\(label) must be an \(direction.rawValue) port")
                return
            }
            guard let definition = registry.definition(for: node.typeID) else { return }
            guard let port = definition.port(address.port, direction: direction) else {
                problems.append("\(label): \(node.typeID) has no \(direction.rawValue) port \"\(address.port)\"")
                return
            }
            if port.kind != kind { problems.append("\(label): port \"\(address.port)\" is a \(port.kind.rawValue) port") }
        }
        for input in interface.inputs {
            if input.targets.isEmpty { problems.append("Input \"\(input.id)\" feeds nothing") }
            for target in input.targets { check(target, direction: .input, kind: input.kind, as: "Input \"\(input.id)\"") }
        }
        for output in interface.outputs {
            guard let source = output.source else { problems.append("Output \"\(output.id)\" has no source"); continue }
            check(source, direction: .output, kind: output.kind, as: "Output \"\(output.id)\"")
        }
        for property in interface.properties {
            if property.targets.isEmpty { problems.append("Property \"\(property.id)\" sets nothing") }
            for target in property.targets {
                guard let node = graph.nodes[target.node] else {
                    problems.append("Property \"\(property.id)\" points at a node that does not exist")
                    continue
                }
                if let definition = registry.definition(for: node.typeID), definition.property(target.property) == nil {
                    problems.append("Property \"\(property.id)\": \(node.typeID) has no property \"\(target.property)\"")
                }
            }
        }
        return problems
    }

    /// Subgraphs this one contains instances of, directly.
    public var directDependencies: Set<SubgraphID> {
        Set(graph.nodes.values.compactMap { $0.typeID.subgraphID })
    }
}
