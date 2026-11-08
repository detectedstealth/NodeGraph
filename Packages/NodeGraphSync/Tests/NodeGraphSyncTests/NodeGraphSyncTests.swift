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

    // A save that expects an older revision is refused and writes nothing.
    await #expect(throws: GraphStoreError.conflict(id, current: second.revision)) {
        try await store.save(GraphDocument(), as: id, name: "Stale", expecting: .revision(first.revision))
    }
    await #expect(throws: GraphStoreError.conflict(id, current: second.revision)) {
        try await store.save(GraphDocument(), as: id, name: "Again", expecting: .new)
    }
    #expect(try await store.load(id).summary == second)
    let third = try await store.save(changed, as: id, name: "Third", expecting: .revision(second.revision))
    #expect(third.revision == GraphRevision(rawValue: 3))
    let missing = GraphID()
    await #expect(throws: GraphStoreError.conflict(missing, current: nil)) {
        try await store.save(GraphDocument(), as: missing, name: "Gone", expecting: .revision(first.revision))
    }
    #expect(try await store.save(GraphDocument(), as: missing, name: "Fresh", expecting: .new).revision.rawValue == 1)
    try await store.delete(missing)

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

@Test func concurrentSavesFromOneRevisionHaveOneWinner() async throws {
    let store = InMemoryGraphStore(now: { stamp })
    let id = GraphID()
    let base = try await store.save(GraphDocument(), as: id, name: "Base").revision
    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for index in 0..<8 {
            group.addTask {
                (try? await store.save(GraphDocument(), as: id, name: "W\(index)", expecting: .revision(base))) != nil
            }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(try await store.load(id).summary.revision == GraphRevision(rawValue: 2))
}

// MARK: - Command log

private func logEditor() -> GraphEditor {
    var types = TypeRegistry()
    types.register(PortTypeInfo(type: "number", displayName: "Number", color: RGBAColor(red: 0, green: 0, blue: 0)))
    var nodes = NodeRegistry()
    nodes.register(NodeDefinition(
        typeID: "pass", displayName: "Pass",
        ports: [
            PortDefinition(id: "in", direction: .input, type: "number"),
            PortDefinition(id: "out", direction: .output, type: "number"),
        ]))
    return GraphEditor(nodes: nodes, types: types)
}

@Test func commandLogRoundTripsAndReplays() async throws {
    let editor = logEditor()
    let stream = editor.changes()
    let a = Node(typeID: "pass"), b = Node(typeID: "pass", position: GraphPoint(x: 100, y: 0))
    try editor.apply(.addNode(node: a))
    try editor.apply(.addNode(node: b))
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: a.id, port: "out", direction: .output),
        target: PortAddress(node: b.id, port: "in", direction: .input)))

    var log = CommandLog()
    for await change in stream {
        let appended = log.append(change)
        #expect(appended)
        if log.changes.count == 3 { break }
    }
    #expect(log.revision == 3)
    let repeated = log.append(log.changes[0])
    #expect(!repeated)
    #expect(log.changes(since: 2).map(\.revision) == [3])

    let decoded = try CommandLog.decode(from: log.encoded())
    #expect(decoded == log)
    #expect(try log.encoded() == decoded.encoded())

    let replica = logEditor()
    try decoded.replay(on: replica)
    #expect(replica.graph == editor.graph)
    #expect(replica.revision == 3)
    #expect(throws: CommandLogError.baseMismatch(expected: 0, actual: 3)) { try decoded.replay(on: replica) }
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
