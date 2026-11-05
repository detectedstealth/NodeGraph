import Foundation

/// Why a document could not be loaded.
public enum GraphDocumentError: Error, Hashable, Sendable {
    /// The file has no integer `schemaVersion`.
    case missingSchemaVersion
    /// The file was written by a newer version of the app.
    case newerThanSupported(found: Int, supported: Int)
    /// No migration is registered for this version, so the file is too old to open.
    case noMigrationPath(from: Int)
    case migrationFailed(from: Int, reason: String)
}

/// The serializable root of a saved graph: a schema version, the graph, and free-form metadata.
///
/// ## File format (version 1)
///
/// JSON with `schemaVersion`, `graph` (`nodes`, `links`, `groups`, each an array in storage
/// order) and `metadata`. Output is deterministic: keys are sorted and arrays keep storage
/// order, so saving an unchanged document produces identical bytes and clean diffs.
public struct GraphDocument: Hashable, Sendable, Codable {
    /// The format version this build reads and writes.
    public static let currentSchemaVersion = NodeGraphCore.documentSchemaVersion

    public private(set) var schemaVersion: Int
    public var graph: Graph
    /// Reusable subgraph definitions, in storage order. Instances in `graph` (and in other
    /// definitions) refer to them by node type. Omitted from the file when there are none.
    public var subgraphs: [SubgraphDefinition]
    /// Free-form document information (title, author, tool settings). Keys are chosen by the app.
    public var metadata: [String: GraphValue]

    public init(graph: Graph = Graph(), subgraphs: [SubgraphDefinition] = [], metadata: [String: GraphValue] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.graph = graph
        self.subgraphs = subgraphs
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, graph, subgraphs, metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        graph = try container.decode(Graph.self, forKey: .graph)
        subgraphs = try container.decodeIfPresent([SubgraphDefinition].self, forKey: .subgraphs) ?? []
        metadata = try container.decode([String: GraphValue].self, forKey: .metadata)
        guard Set(subgraphs.map(\.id)).count == subgraphs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .subgraphs, in: container, debugDescription: "Duplicate subgraph id")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(graph, forKey: .graph)
        if !subgraphs.isEmpty { try container.encode(subgraphs, forKey: .subgraphs) }
        try container.encode(metadata, forKey: .metadata)
    }

    // MARK: Writing

    /// Deterministic JSON for the document.
    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        try Self.makeEncoder(prettyPrinted: prettyPrinted).encode(self)
    }

    private static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: Reading

    /// Reads a document, migrating older versions first.
    ///
    /// - Throws: ``GraphDocumentError`` for version problems, or `DecodingError` if the JSON is
    ///   malformed for its version.
    public static func decode(
        from data: Data, migrations: MigrationChain = .standard
    ) throws -> GraphDocument {
        let decoder = JSONDecoder()
        let version = try readVersion(from: data, using: decoder)
        if version > migrations.targetVersion {
            throw GraphDocumentError.newerThanSupported(found: version, supported: migrations.targetVersion)
        }
        guard version < migrations.targetVersion else {
            return try decoder.decode(GraphDocument.self, from: data)
        }
        var tree = try decoder.decode(JSONValue.self, from: data)
        try migrations.migrate(&tree, from: version)
        return try decoder.decode(GraphDocument.self, from: makeEncoder(prettyPrinted: false).encode(tree))
    }

    private static func readVersion(from data: Data, using decoder: JSONDecoder) throws -> Int {
        struct Header: Decodable { var schemaVersion: Int }
        do {
            return try decoder.decode(Header.self, from: data).schemaVersion
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            throw GraphDocumentError.missingSchemaVersion
        }
    }

    // MARK: Unknown node types

    /// Node types used in the graph that `registry` does not define, sorted and without
    /// duplicates. Such nodes still load and save with all their data (position, properties,
    /// links); use ``NodeRegistry/addingPlaceholders(for:)`` so editors can display them.
    public func missingNodeTypes(in registry: NodeRegistry) -> [NodeTypeID] {
        let defined = Set(subgraphs.map(\.typeID))
        let used = graph.nodes.values.map(\.typeID) + subgraphs.flatMap { $0.graph.nodes.values.map(\.typeID) }
        return Set(used.filter { registry.definition(for: $0) == nil && !defined.contains($0) }).sorted()
    }
}
