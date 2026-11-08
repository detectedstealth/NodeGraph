import Foundation
import NodeGraphCore

/// Identifies a stored graph. Minted offline, so a server can accept it as is.
public struct GraphID: GraphIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// How many times a stored graph has been saved. The first save is revision 1.
public struct GraphRevision: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a store knows about a graph without loading its contents.
public struct GraphSummary: Hashable, Sendable, Codable, Identifiable {
    public var id: GraphID
    public var name: String
    public var revision: GraphRevision
    public var modified: Date

    public init(id: GraphID, name: String, revision: GraphRevision, modified: Date) {
        self.id = id
        self.name = name
        self.revision = revision
        self.modified = modified
    }
}

/// A stored graph: its summary and its document.
public struct StoredGraph: Hashable, Sendable {
    public var summary: GraphSummary
    public var document: GraphDocument

    public init(summary: GraphSummary, document: GraphDocument) {
        self.summary = summary
        self.document = document
    }
}

public enum GraphStoreError: Error, Hashable, Sendable {
    /// No graph with this id.
    case notFound(GraphID)
    /// The stored data for this graph cannot be read.
    case corrupt(GraphID)
    /// A save expected a different state than the store holds: someone saved in between, or the
    /// graph was created or deleted. `current` is the stored revision, nil if there is no graph.
    case conflict(GraphID, current: GraphRevision?)
}

/// What a save requires of the stored graph, checked and applied as one step.
public enum SaveExpectation: Hashable, Sendable {
    /// Save over whatever is stored, or create the graph.
    case any
    /// The graph must not exist yet.
    case new
    /// The stored graph must be at exactly this revision, the one the edit started from.
    case revision(GraphRevision)

    /// Throws ``GraphStoreError/conflict(_:current:)`` unless `current`, the stored revision (nil if
    /// there is none), satisfies the expectation.
    public func check(_ current: GraphRevision?, for id: GraphID) throws {
        switch self {
        case .any: return
        case .new: if current == nil { return }
        case .revision(let expected): if current == expected { return }
        }
        throw GraphStoreError.conflict(id, current: current)
    }
}

/// Somewhere graphs are kept: memory, a folder of files, and later a server.
///
/// A store keeps whole documents and numbers each save. Every call is `async` so a remote store
/// can implement the same protocol.
public protocol GraphStore: Sendable {
    /// The summaries of every stored graph, in no particular order.
    func list() async throws -> [GraphSummary]

    /// Loads a graph.
    /// - Throws: ``GraphStoreError/notFound(_:)`` or ``GraphStoreError/corrupt(_:)``.
    func load(_ id: GraphID) async throws -> StoredGraph

    /// Stores `document` under `id`, creating the graph or replacing its contents, and returns the
    /// new summary with the revision one higher than before.
    ///
    /// The check against `expectation` and the write happen as one step, so of two saves that start
    /// from the same revision only one succeeds. The loser gets
    /// ``GraphStoreError/conflict(_:current:)``, and nothing is written.
    func save(
        _ document: GraphDocument, as id: GraphID, name: String, expecting expectation: SaveExpectation
    ) async throws -> GraphSummary

    /// Removes a graph.
    /// - Throws: ``GraphStoreError/notFound(_:)``.
    func delete(_ id: GraphID) async throws
}

extension GraphStore {
    /// Saves without a check: creates the graph or replaces what is stored.
    @discardableResult
    public func save(_ document: GraphDocument, as id: GraphID, name: String) async throws -> GraphSummary {
        try await save(document, as: id, name: name, expecting: .any)
    }
}
