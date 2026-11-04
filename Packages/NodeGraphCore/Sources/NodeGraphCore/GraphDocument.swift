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
    /// Free-form document information (title, author, tool settings). Keys are chosen by the app.
    public var metadata: [String: GraphValue]

    public init(graph: Graph = Graph(), metadata: [String: GraphValue] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.graph = graph
        self.metadata = metadata
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
        Set(graph.nodes.values.map(\.typeID).filter { registry.definition(for: $0) == nil }).sorted()
    }
}
