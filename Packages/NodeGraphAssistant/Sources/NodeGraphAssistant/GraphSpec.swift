import Foundation
import NodeGraphCore

/// A graph written the way a model (or a person with a text editor) can write one: nodes with
/// short aliases, links as `"alias.port"` pairs, groups by alias. No ids, no positions.
/// ``GraphSpecCompiler`` checks it against a registry and turns it into a ``GraphFragment``.
/// ```json
/// {
///   "nodes": [
///     { "alias": "a", "type": "math.const", "properties": { "value": 4 } },
///     { "alias": "s", "type": "math.add" }
///   ],
///   "links": [ { "from": "a.out", "to": "s.a" } ]
/// }
/// ```
public struct GraphSpec: Hashable, Sendable, Codable {
    public struct NodeSpec: Hashable, Sendable, Codable {
        /// Names the node in ``LinkSpec`` and ``GroupSpec``. Unique in the spec, no dots or spaces.
        public var alias: String
        /// A registered node type id, such as `"math.add"`.
        public var type: String
        public var title: String?
        /// Property values by property id, as plain JSON (a number, a string, an array for a vector).
        /// Properties left out keep the type's defaults.
        public var properties: [String: JSONValue]
        /// How many ports each dynamic port group has, by group id.
        public var portCounts: [String: Int]
        public var mode: NodeMode?

        public init(
            alias: String, type: String, title: String? = nil, properties: [String: JSONValue] = [:],
            portCounts: [String: Int] = [:], mode: NodeMode? = nil
        ) {
            self.alias = alias
            self.type = type
            self.title = title
            self.properties = properties
            self.portCounts = portCounts
            self.mode = mode
        }

        private enum CodingKeys: String, CodingKey { case alias, type, title, properties, portCounts, mode }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            alias = try container.decode(String.self, forKey: .alias)
            type = try container.decode(String.self, forKey: .type)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            properties = try container.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
            portCounts = try container.decodeIfPresent([String: Int].self, forKey: .portCounts) ?? [:]
            mode = try container.decodeIfPresent(NodeMode.self, forKey: .mode)
        }
    }

    /// A link from an output port to an input port, each written `"alias.port"`.
    public struct LinkSpec: Hashable, Sendable, Codable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct GroupSpec: Hashable, Sendable, Codable {
        public var title: String
        /// Aliases of the nodes to frame.
        public var members: [String]

        public init(title: String, members: [String]) {
            self.title = title
            self.members = members
        }
    }

    public var nodes: [NodeSpec]
    public var links: [LinkSpec]
    public var groups: [GroupSpec]

    public init(nodes: [NodeSpec] = [], links: [LinkSpec] = [], groups: [GroupSpec] = []) {
        self.nodes = nodes
        self.links = links
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case nodes, links, groups }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([NodeSpec].self, forKey: .nodes) ?? []
        links = try container.decodeIfPresent([LinkSpec].self, forKey: .links) ?? []
        groups = try container.decodeIfPresent([GroupSpec].self, forKey: .groups) ?? []
    }

    /// Reads a spec from JSON.
    public static func decode(from data: Data) throws -> GraphSpec {
        try JSONDecoder().decode(GraphSpec.self, from: data)
    }

    /// The spec as JSON with sorted keys, so the same spec always gives the same text.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}
