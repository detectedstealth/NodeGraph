import Foundation
import NodeGraphCore

/// A ``GraphStore`` that keeps graphs in memory. For tests, previews and scratch work.
public actor InMemoryGraphStore: GraphStore {
    private var graphs: [GraphID: StoredGraph] = [:]
    private let now: @Sendable () -> Date

    /// - Parameter now: The clock used to stamp saves; tests pass a fixed one.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func list() -> [GraphSummary] {
        graphs.values.map(\.summary)
    }

    public func load(_ id: GraphID) throws -> StoredGraph {
        guard let stored = graphs[id] else { throw GraphStoreError.notFound(id) }
        return stored
    }

    public func save(
        _ document: GraphDocument, as id: GraphID, name: String, expecting expectation: SaveExpectation
    ) throws -> GraphSummary {
        try expectation.check(graphs[id]?.summary.revision, for: id)
        let revision = GraphRevision(rawValue: (graphs[id]?.summary.revision.rawValue ?? 0) + 1)
        let summary = GraphSummary(id: id, name: name, revision: revision, modified: now())
        graphs[id] = StoredGraph(summary: summary, document: document)
        return summary
    }

    public func delete(_ id: GraphID) throws {
        guard graphs.removeValue(forKey: id) != nil else { throw GraphStoreError.notFound(id) }
    }
}
