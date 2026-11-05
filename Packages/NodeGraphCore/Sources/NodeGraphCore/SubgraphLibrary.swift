import Collections
import Foundation

/// Names a library of subgraph definitions, for example `"acme.robotics-blocks"`.
public struct LibraryID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Where a document's copy of a definition came from, so it can be checked for updates.
public struct SubgraphOrigin: Hashable, Sendable, Codable {
    public var library: LibraryID
    /// The library revision the copy was taken from.
    public var revision: Int
    /// ``SubgraphDefinition/contentDigest`` of the copy when it was taken. If the document's copy
    /// no longer has this digest, it has been edited since.
    public var digest: String

    public init(library: LibraryID, revision: Int, digest: String) {
        self.library = library
        self.revision = revision
        self.digest = digest
    }
}

/// One published definition in a library.
public struct LibraryEntry: Hashable, Sendable, Codable {
    /// Starts at 1 and increases by one each time the content changes.
    public var revision: Int
    public var summary: String
    /// The definition as published. Never has an ``SubgraphDefinition/origin``.
    public var definition: SubgraphDefinition

    public init(revision: Int, summary: String = "", definition: SubgraphDefinition) {
        self.revision = revision
        self.summary = summary
        self.definition = definition
    }
}

/// Why a library operation failed.
public enum LibraryError: Error, Hashable, Sendable {
    /// A definition contains instances of another that the library does not have.
    case missingDependency(SubgraphID, needs: SubgraphID)
    /// Definitions that contain each other, in a loop.
    case recursive([SubgraphID])
    /// Other entries still contain instances of this one.
    case inUse(SubgraphID, by: [SubgraphID])
    case notFound(SubgraphID)
    case missingSchemaVersion
    case newerThanSupported(found: Int, supported: Int)
}

extension SubgraphDefinition {
    /// A stable fingerprint of the definition's content: its interface and inner graph, not its id
    /// or origin. Equal content gives an equal digest in any process, so it can be stored.
    ///
    /// It is a 64-bit FNV-1a hash of the deterministic JSON, for detecting edits, not for
    /// security.
    public var contentDigest: String {
        struct Content: Encodable {
            var interface: SubgraphInterface
            var graph: Graph
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = (try? encoder.encode(Content(interface: interface, graph: graph))) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// A set of reusable subgraph definitions that can be shared between documents.
///
/// A document never refers to a library at run time. Using a definition copies it into the
/// document (see ``GraphEditor/importCommand(_:from:)``), together with the definitions it
/// contains instances of, and records an ``SubgraphOrigin`` so the copy can later be compared with
/// the library and updated. Documents therefore stay self-contained: they open, run and save
/// without the library being available.
///
/// Libraries are plain values. Where they are stored (a file, a server) is up to the app; see
/// ``encoded()`` and ``decode(from:)`` for the file form.
public struct SubgraphLibrary: Hashable, Sendable {
    /// The file format version this build reads and writes.
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion = SubgraphLibrary.currentSchemaVersion
    public var id: LibraryID
    public var name: String
    /// Entries in publication order.
    public private(set) var entries: OrderedDictionary<SubgraphID, LibraryEntry> = [:]

    public init(id: LibraryID = LibraryID(UUID().uuidString), name: String) {
        self.id = id
        self.name = name
    }

    /// The published definitions, in publication order.
    public var definitions: [SubgraphDefinition] { entries.values.map(\.definition) }

    public func entry(for id: SubgraphID) -> LibraryEntry? { entries[id] }

    /// The origin to record on a document's copy of an entry, built from its current revision.
    public func origin(of id: SubgraphID) -> SubgraphOrigin? {
        entries[id].map { SubgraphOrigin(library: self.id, revision: $0.revision, digest: $0.definition.contentDigest) }
    }

    // MARK: Publishing

    /// Adds definitions, or new versions of ones already here. A definition whose content is
    /// unchanged keeps its revision; a changed one gets the next revision.
    ///
    /// Everything either succeeds or the library is left as it was.
    ///
    /// - Returns: The origin to record on each published definition in the source document.
    /// - Throws: ``LibraryError/missingDependency(_:needs:)`` if a definition contains instances of
    ///   one that is neither in the batch nor already in the library, and
    ///   ``LibraryError/recursive(_:)`` if the result would contain a loop.
    @discardableResult
    public mutating func publish(
        _ definitions: [SubgraphDefinition], summaries: [SubgraphID: String] = [:]
    ) throws -> [SubgraphID: SubgraphOrigin] {
        var updated = self
        var origins: [SubgraphID: SubgraphOrigin] = [:]
        for var definition in definitions {
            definition.origin = nil
            let digest = definition.contentDigest
            let existing = updated.entries[definition.id]
            let revision = existing.map { $0.definition.contentDigest == digest ? $0.revision : $0.revision + 1 } ?? 1
            updated.entries[definition.id] = LibraryEntry(
                revision: revision, summary: summaries[definition.id] ?? existing?.summary ?? "", definition: definition)
            origins[definition.id] = SubgraphOrigin(library: id, revision: revision, digest: digest)
        }
        _ = try updated.closure(of: Array(updated.entries.keys))   // checks dependencies and loops
        self = updated
        return origins
    }

    /// Removes an entry that no other entry contains instances of.
    public mutating func remove(_ id: SubgraphID) throws {
        guard entries[id] != nil else { throw LibraryError.notFound(id) }
        let users = entries.values.filter { $0.definition.directDependencies.contains(id) }.map(\.definition.id)
        guard users.isEmpty else { throw LibraryError.inUse(id, by: users) }
        entries.removeValue(forKey: id)
    }

    // MARK: Dependencies

    /// The entries for `ids` and everything they contain instances of, dependencies first, so
    /// adding them to a document in this order always finds each type already defined.
    public func closure(of ids: [SubgraphID]) throws -> [LibraryEntry] {
        var ordered: [LibraryEntry] = []
        var done = Set<SubgraphID>(), visiting: [SubgraphID] = []
        func visit(_ id: SubgraphID, neededBy parent: SubgraphID?) throws {
            if done.contains(id) { return }
            guard let entry = entries[id] else {
                if let parent { throw LibraryError.missingDependency(parent, needs: id) }
                throw LibraryError.notFound(id)
            }
            if let loop = visiting.firstIndex(of: id) { throw LibraryError.recursive(Array(visiting[loop...])) }
            visiting.append(id)
            for dependency in entry.definition.directDependencies.sorted() { try visit(dependency, neededBy: id) }
            visiting.removeLast()
            done.insert(id)
            ordered.append(entry)
        }
        for id in ids { try visit(id, neededBy: nil) }
        return ordered
    }
}

// MARK: - File form

extension SubgraphLibrary: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(LibraryID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        for entry in try container.decode([LibraryEntry].self, forKey: .entries) {
            guard entries.updateValue(entry, forKey: entry.definition.id) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .entries, in: container, debugDescription: "Duplicate entry \(entry.definition.id)")
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(Array(entries.values), forKey: .entries)
    }

    /// Deterministic, diff-friendly JSON: sorted keys, entries in publication order.
    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads a library file.
    ///
    /// - Throws: ``LibraryError`` for a missing or newer version, or `DecodingError`.
    public static func decode(from data: Data) throws -> SubgraphLibrary {
        struct Header: Decodable { var schemaVersion: Int }
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(Header.self, from: data).schemaVersion
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            throw LibraryError.missingSchemaVersion
        }
        guard version <= currentSchemaVersion else {
            throw LibraryError.newerThanSupported(found: version, supported: currentSchemaVersion)
        }
        return try decoder.decode(SubgraphLibrary.self, from: data)
    }
}

// MARK: - Using a library from a document

/// How a document's copy of a definition compares with a library.
public enum SubgraphLibraryStatus: Hashable, Sendable {
    /// The definition was written in this document, or came from a different library.
    case notFromLibrary
    /// It came from this library, which no longer has it.
    case missingFromLibrary
    case upToDate
    /// The library has a newer revision and the copy has not been edited.
    case updateAvailable(revision: Int)
    /// The copy was edited since it was taken. The library has nothing newer.
    case locallyModified
    /// Both: updating would replace the local edits.
    case modifiedAndUpdateAvailable(revision: Int)
}

extension GraphEditor {
    /// How the document's copy of a definition compares with `library`.
    public func libraryStatus(of id: SubgraphID, in library: SubgraphLibrary) -> SubgraphLibraryStatus {
        guard let definition = subgraphs[id], let origin = definition.origin, origin.library == library.id else {
            return .notFromLibrary
        }
        guard let entry = library.entry(for: id) else { return .missingFromLibrary }
        let modified = definition.contentDigest != origin.digest
        let newer = entry.revision > origin.revision
        switch (modified, newer) {
        case (false, false): return .upToDate
        case (false, true): return .updateAvailable(revision: entry.revision)
        case (true, false): return .locallyModified
        case (true, true): return .modifiedAndUpdateAvailable(revision: entry.revision)
        }
    }

    /// The command that copies library definitions into the document, along with everything they
    /// contain instances of, dependencies first. Definitions the document already has are left
    /// alone (use ``updateCommand(_:from:)`` to replace one). Each copy records its origin.
    ///
    /// The command does nothing if the document already has them all.
    public func importCommand(_ ids: [SubgraphID], from library: SubgraphLibrary) throws -> GraphCommand {
        let commands = try library.closure(of: ids)
            .filter { subgraphs[$0.definition.id] == nil }
            .map { entry -> GraphCommand in
                var definition = entry.definition
                definition.origin = SubgraphOrigin(
                    library: library.id, revision: entry.revision, digest: definition.contentDigest)
                return .addSubgraph(definition: definition)
            }
        return .batch(commands: commands)
    }

    /// The command that replaces the document's copy of a definition with the library's current
    /// version, adding any new definitions that version needs first. Links and property values on
    /// instances that the new interface no longer supports are removed, as for any interface
    /// change. Any edits made to the local copy are lost; check ``libraryStatus(of:in:)`` first.
    public func updateCommand(_ id: SubgraphID, from library: SubgraphLibrary) throws -> GraphCommand {
        guard subgraphs[id] != nil else { throw GraphEditError.subgraphNotFound(id) }
        let closure = try library.closure(of: [id])
        var commands: [GraphCommand] = []
        for entry in closure {
            var definition = entry.definition
            definition.origin = SubgraphOrigin(library: library.id, revision: entry.revision, digest: definition.contentDigest)
            if entry.definition.id == id {
                commands.append(.updateSubgraph(definition: definition))
            } else if subgraphs[entry.definition.id] == nil {
                commands.append(.addSubgraph(definition: definition))
            }
        }
        return .batch(commands: commands)
    }

    /// The document's definitions for `ids` and everything they contain instances of, dependencies
    /// first: what to pass to ``SubgraphLibrary/publish(_:summaries:)`` so the library gets a
    /// complete set.
    public func publishable(_ ids: [SubgraphID]) throws -> [SubgraphDefinition] {
        var ordered: [SubgraphDefinition] = []
        var done = Set<SubgraphID>(), visiting: [SubgraphID] = []
        func visit(_ id: SubgraphID) throws {
            if done.contains(id) { return }
            guard let definition = subgraphs[id] else { throw GraphEditError.subgraphNotFound(id) }
            if let loop = visiting.firstIndex(of: id) { throw LibraryError.recursive(Array(visiting[loop...])) }
            visiting.append(id)
            for dependency in definition.directDependencies.sorted() { try visit(dependency) }
            visiting.removeLast()
            done.insert(id)
            ordered.append(definition)
        }
        for id in ids { try visit(id) }
        return ordered
    }

    /// The command that records origins on definitions just published, so their status reads
    /// up to date. Changes nothing but the origin.
    public func adoptOriginsCommand(_ origins: [SubgraphID: SubgraphOrigin]) -> GraphCommand {
        .batch(commands: subgraphs.values.compactMap { definition in
            guard let origin = origins[definition.id], definition.origin != origin else { return nil }
            var adopted = definition
            adopted.origin = origin
            return .updateSubgraph(definition: adopted)
        })
    }
}
