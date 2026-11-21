import Foundation
import NodeGraphCore

/// Somewhere subgraph libraries are kept. A library already has its own id, file form and revision
/// numbers (``SubgraphLibrary``), so a store only holds them by id.
public protocol SubgraphLibraryStore: Sendable {
    /// Every stored library, in no particular order.
    func libraries() async throws -> [SubgraphLibrary]

    /// Stores a library, replacing the one with the same id.
    func save(_ library: SubgraphLibrary) async throws

    /// Removes a library. Removing one that is not stored does nothing.
    func delete(_ id: LibraryID) async throws
}

/// A ``SubgraphLibraryStore`` in memory, for tests and previews.
public actor InMemorySubgraphLibraryStore: SubgraphLibraryStore {
    private var stored: [LibraryID: SubgraphLibrary] = [:]

    public init(_ libraries: [SubgraphLibrary] = []) {
        stored = Dictionary(libraries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func libraries() -> [SubgraphLibrary] { Array(stored.values) }
    public func save(_ library: SubgraphLibrary) { stored[library.id] = library }
    public func delete(_ id: LibraryID) { stored.removeValue(forKey: id) }
}

/// A ``SubgraphLibraryStore`` that keeps one `.nodegraphlib` file per library in a folder: the
/// library's own JSON, written atomically. The folder is created on the first save. `libraries()`
/// skips files it cannot read, so one damaged file does not hide the rest.
public actor FileSubgraphLibraryStore: SubgraphLibraryStore {
    public static let fileExtension = "nodegraphlib"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func libraries() throws -> [SubgraphLibrary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.compactMap { url in
            guard url.pathExtension == Self.fileExtension, let data = try? Data(contentsOf: url) else { return nil }
            return try? SubgraphLibrary.decode(from: data)
        }
    }

    public func save(_ library: SubgraphLibrary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try library.encoded().writeAtomically(to: fileURL(for: library.id))
    }

    public func delete(_ id: LibraryID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    /// Library ids are free text, so the file name is the id with anything unsafe percent-encoded.
    private func fileURL(for id: LibraryID) -> URL {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = id.rawValue.addingPercentEncoding(withAllowedCharacters: safe) ?? "library"
        return directory.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }
}
