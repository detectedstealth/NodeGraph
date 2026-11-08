import Foundation
import NodeGraphCore

/// A ``GraphStore`` that keeps one file per graph in a folder.
///
/// Each graph is `<id>.nodegraphrecord`: JSON holding the name, revision and modification time beside the
/// document, written atomically so a crash leaves the old file or the new one. The folder is
/// created on the first save. Files whose names are not a graph id are ignored, and `list` skips
/// files it cannot read (`load` reports them as ``GraphStoreError/corrupt(_:)``).
public actor FileGraphStore: GraphStore {
    /// File extension of a stored graph.
    public static let fileExtension = "nodegraphrecord"

    private static let formatVersion = 1

    public let directory: URL
    private let now: @Sendable () -> Date
    private let migrations: MigrationChain

    /// - Parameters:
    ///   - directory: The folder holding the graph files.
    ///   - now: The clock used to stamp saves; tests pass a fixed one.
    ///   - migrations: Passed to ``GraphDocument/decode(from:migrations:)`` when loading.
    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        migrations: MigrationChain = .standard
    ) {
        self.directory = directory
        self.now = now
        self.migrations = migrations
    }

    public func list() throws -> [GraphSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.compactMap { url in
            guard let id = graphID(of: url), let data = try? Data(contentsOf: url) else { return nil }
            return try? readHeader(data, id: id)
        }
    }

    public func load(_ id: GraphID) throws -> StoredGraph {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: id))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw GraphStoreError.notFound(id)
        }
        do {
            let summary = try readHeader(data, id: id)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(File.self, from: data)
            let document = try GraphDocument.decode(
                from: try JSONEncoder().encode(file.document), migrations: migrations)
            return StoredGraph(summary: summary, document: document)
        } catch is DecodingError {
            throw GraphStoreError.corrupt(id)
        }
    }

    public func save(
        _ document: GraphDocument, as id: GraphID, name: String, expecting expectation: SaveExpectation
    ) throws -> GraphSummary {
        let url = fileURL(for: id)
        let previous = (try? Data(contentsOf: url)).flatMap { try? readHeader($0, id: id) }
        try expectation.check(previous?.revision, for: id)
        let summary = GraphSummary(
            id: id, name: name,
            revision: GraphRevision(rawValue: (previous?.revision.rawValue ?? 0) + 1),
            modified: now())
        let file = File(
            formatVersion: Self.formatVersion, id: id, name: name, revision: summary.revision,
            modified: summary.modified,
            document: try JSONDecoder().decode(JSONValue.self, from: document.encoded(prettyPrinted: false)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
        return summary
    }

    public func delete(_ id: GraphID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw GraphStoreError.notFound(id)
        }
    }

    // MARK: Files

    private struct File: Codable {
        var formatVersion: Int
        var id: GraphID
        var name: String
        var revision: GraphRevision
        var modified: Date
        var document: JSONValue
    }

    /// The same file without the document, so a listing does not build every graph.
    private struct Header: Decodable {
        var id: GraphID
        var name: String
        var revision: GraphRevision
        var modified: Date
    }

    private func fileURL(for id: GraphID) -> URL {
        directory.appendingPathComponent(id.description).appendingPathExtension(Self.fileExtension)
    }

    private func graphID(of url: URL) -> GraphID? {
        guard url.pathExtension == Self.fileExtension,
              let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        else { return nil }
        return GraphID(uuid: uuid)
    }

    private func readHeader(_ data: Data, id: GraphID) throws -> GraphSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.id == id else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "id mismatch")) }
        return GraphSummary(id: id, name: header.name, revision: header.revision, modified: header.modified)
    }
}
