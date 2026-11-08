import Foundation
import NodeGraphCore
import Testing
@testable import NodeGraphSync

private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

/// A small document with an exact big integer and a whole double, built from JSON because graph
/// edits are not public outside Core.
private func sampleDocument(title: String = "Sample") throws -> GraphDocument {
    let json = """
    {"schemaVersion":1,"metadata":{"title":{"type":"string","value":"\(title)"}},"graph":{
    "groups":[],
    "links":[{"id":"00000000-0000-0000-0000-000000000010",
      "source":{"direction":"output","node":"00000000-0000-0000-0000-000000000001","port":"sum"},
      "target":{"direction":"input","node":"00000000-0000-0000-0000-000000000002","port":"a"}}],
    "nodes":[
     {"id":"00000000-0000-0000-0000-000000000001","isCollapsed":false,"isPinned":false,"mode":"always",
      "position":{"x":10,"y":20},"typeID":"math.add",
      "properties":{"offset":{"type":"int","value":9223372036854775807},"scale":{"type":"double","value":1}}},
     {"id":"00000000-0000-0000-0000-000000000002","isCollapsed":false,"isPinned":false,"mode":"always",
      "position":{"x":200,"y":20},"typeID":"math.add","properties":{}}]}}
    """
    return try GraphDocument.decode(from: Data(json.utf8))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("NodeGraphSyncTests-\(UUID().uuidString)")
}

/// Runs the same checks against every store, so they cannot drift apart.
private func exerciseStore(_ store: some GraphStore) async throws {
    let id = GraphID()
    #expect(try await store.list().isEmpty)

    let first = try await store.save(sampleDocument(), as: id, name: "One")
    #expect(first.revision == GraphRevision(rawValue: 1))
    #expect(first.name == "One")
    let changed = try sampleDocument(title: "Changed")
    let second = try await store.save(changed, as: id, name: "Renamed")
    #expect(second.revision == GraphRevision(rawValue: 2))

    let loaded = try await store.load(id)
    #expect(loaded.summary == second)
    #expect(loaded.document == changed)

    let other = GraphID()
    _ = try await store.save(GraphDocument(), as: other, name: "Other")
    #expect(Set(try await store.list().map(\.id)) == [id, other])

    try await store.delete(id)
    #expect(Set(try await store.list().map(\.id)) == [other])
    await #expect(throws: GraphStoreError.notFound(id)) { try await store.load(id) }
    await #expect(throws: GraphStoreError.notFound(id)) { try await store.delete(id) }
}

@Test func inMemoryStore() async throws {
    try await exerciseStore(InMemoryGraphStore(now: { stamp }))
}

@Test func fileStore() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await exerciseStore(FileGraphStore(directory: directory, now: { stamp }))
}

@Test func fileStoreRoundTripsADocumentExactly() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileGraphStore(directory: directory, now: { stamp })
    let document = try sampleDocument()
    let id = GraphID()
    _ = try await store.save(document, as: id, name: "Exact")
    let loaded = try await store.load(id)
    #expect(loaded.document == document)
    #expect(loaded.summary.modified == stamp)
}

@Test func fileStoreKeepsRevisionsAcrossInstances() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = GraphID()
    _ = try await FileGraphStore(directory: directory).save(GraphDocument(), as: id, name: "A")
    let again = try await FileGraphStore(directory: directory).save(GraphDocument(), as: id, name: "A")
    #expect(again.revision == GraphRevision(rawValue: 2))
}

@Test func fileStoreIgnoresStrangeFilesAndReportsCorruptOnes() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileGraphStore(directory: directory, now: { stamp })
    let good = GraphID(), bad = GraphID()
    _ = try await store.save(GraphDocument(), as: good, name: "Good")
    try Data("not json".utf8).write(to: directory.appendingPathComponent("\(bad).nodegraphrecord"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("readme.nodegraphrecord"))

    #expect(try await store.list().map(\.id) == [good])
    await #expect(throws: GraphStoreError.corrupt(bad)) { try await store.load(bad) }
}

// MARK: - Library stores

private func sampleLibrary(_ id: String, name: String) throws -> SubgraphLibrary {
    var library = SubgraphLibrary(id: LibraryID(id), name: name)
    try library.publish([SubgraphDefinition(interface: SubgraphInterface(name: "Wrapper"))])
    return library
}

private func exerciseLibraryStore(_ store: some SubgraphLibraryStore) async throws {
    #expect(try await store.libraries().isEmpty)
    let a = try sampleLibrary("team/a", name: "A"), b = try sampleLibrary("b", name: "B")
    try await store.save(a)
    try await store.save(b)
    var renamed = a
    renamed.name = "A2"
    try await store.save(renamed)
    let loaded = try await store.libraries()
    #expect(Set(loaded.map(\.name)) == ["A2", "B"])
    #expect(loaded.first { $0.id == a.id } == renamed)   // entries survive
    try await store.delete(a.id)
    try await store.delete(a.id)   // not stored: nothing happens
    #expect(try await store.libraries().map(\.name) == ["B"])
}

@Test func inMemoryLibraryStore() async throws {
    try await exerciseLibraryStore(InMemorySubgraphLibraryStore())
}

@Test func fileLibraryStore() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await exerciseLibraryStore(FileSubgraphLibraryStore(directory: directory))
}

@Test func fileLibraryStoreSkipsDamagedFiles() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSubgraphLibraryStore(directory: directory)
    try await store.save(try sampleLibrary("ok", name: "Ok"))
    try Data("nope".utf8).write(to: directory.appendingPathComponent("bad.nodegraphlib"))
    #expect(try await store.libraries().map(\.name) == ["Ok"])
}
