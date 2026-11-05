import Foundation
import Testing
@testable import NodeGraphCore

// MARK: Fixture

private func editor() -> GraphEditor {
    let (nodes, types) = runnable()
    return GraphEditor(nodes: nodes, types: types)
}

/// A definition that contains one instance of `inner`, exposing nothing.
private func wrapper(of inner: SubgraphDefinition, name: String = "Wrapper") -> SubgraphDefinition {
    var graph = Graph()
    graph.insert(Node(typeID: inner.typeID))
    return SubgraphDefinition(interface: SubgraphInterface(name: name), graph: graph)
}

private func newLibrary() -> SubgraphLibrary { SubgraphLibrary(id: "test.lib", name: "Test") }

// MARK: Digest

@Test func theDigestIsStableAndIgnoresIdentityAndOrigin() {
    let adder = Adder().definition
    #expect(adder.contentDigest == adder.contentDigest)
    #expect(adder.contentDigest.count == 16 && adder.contentDigest.allSatisfy(\.isHexDigit))
    var copy = adder
    copy.origin = SubgraphOrigin(library: "x", revision: 3, digest: "abc")
    #expect(copy.contentDigest == adder.contentDigest, "origin is not content")
    var renamed = adder
    renamed.interface.name = "Other"
    #expect(renamed.contentDigest != adder.contentDigest)
    var edited = adder
    edited.graph.insert(Node(typeID: "const"))
    #expect(edited.contentDigest != adder.contentDigest)
}

@Test func theDigestOfFixedContentNeverChanges() {
    // Stored digests are compared across app versions, so this value must not move. If a change to
    // the file format moves it, existing origins will read as locally modified: migrate them.
    let node = Node(id: NodeID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), typeID: "t")
    var graph = Graph()
    graph.insert(node)
    let definition = SubgraphDefinition(interface: SubgraphInterface(name: "Fixed"), graph: graph)
    #expect(definition.contentDigest == definition.contentDigest)
    #expect(definition.contentDigest == "b74a0ea2611c3cce")
}

// MARK: Publishing

@Test func publishingNumbersRevisionsAndOnlyBumpsOnChange() throws {
    var library = newLibrary()
    var adder = Adder().definition
    adder.origin = SubgraphOrigin(library: "elsewhere", revision: 9, digest: "x")
    let first = try library.publish([adder], summaries: [adder.id: "Adds"])
    #expect(first[adder.id]?.revision == 1 && first[adder.id]?.library == "test.lib")
    #expect(first[adder.id]?.digest == adder.contentDigest)
    #expect(library.entry(for: adder.id)?.definition.origin == nil, "an origin is never stored in a library")
    #expect(library.entry(for: adder.id)?.summary == "Adds")

    #expect(try library.publish([adder])[adder.id]?.revision == 1, "unchanged content keeps its revision")
    #expect(library.entry(for: adder.id)?.summary == "Adds", "and its summary")

    adder.interface.name = "Adder 2"
    #expect(try library.publish([adder])[adder.id]?.revision == 2)
    #expect(library.entries.count == 1)
    #expect(library.origin(of: adder.id)?.revision == 2)
}

@Test func aDefinitionMissingItsDependencyIsRefusedAndNothingChanges() throws {
    var library = newLibrary()
    let inner = Adder().definition, outer = wrapper(of: inner)
    let before = library
    #expect(throws: LibraryError.missingDependency(outer.id, needs: inner.id)) { try library.publish([outer]) }
    #expect(library == before)
    try library.publish([outer, inner])                       // order within the batch does not matter
    #expect(library.entries.count == 2)
}

@Test func definitionsThatContainEachOtherAreRefused() throws {
    var library = newLibrary()
    var a = SubgraphDefinition(interface: SubgraphInterface(name: "A"))
    var b = SubgraphDefinition(interface: SubgraphInterface(name: "B"))
    a.graph.insert(Node(typeID: b.typeID))
    b.graph.insert(Node(typeID: a.typeID))
    let before = library
    do {
        try library.publish([a, b])
        Issue.record("expected a loop to be refused")
    } catch LibraryError.recursive(let loop) {
        #expect(Set(loop) == [a.id, b.id])
    }
    #expect(library == before)
}

@Test func theClosureListsDependenciesFirstAndOnlyWhatIsNeeded() throws {
    var library = newLibrary()
    let leaf = Adder().definition, middle = wrapper(of: leaf, name: "Middle"), top = wrapper(of: middle, name: "Top")
    let unrelated = Adder().definition
    try library.publish([top, middle, leaf, unrelated])
    #expect(try library.closure(of: [top.id]).map(\.definition.id) == [leaf.id, middle.id, top.id])
    #expect(try library.closure(of: [top.id, middle.id]).count == 3, "no repeats")
    let unknown = SubgraphID()
    #expect(throws: LibraryError.notFound(unknown)) { try library.closure(of: [unknown]) }
}

@Test func anEntryThatOthersUseCannotBeRemoved() throws {
    var library = newLibrary()
    let leaf = Adder().definition, top = wrapper(of: leaf)
    try library.publish([leaf, top])
    #expect(throws: LibraryError.inUse(leaf.id, by: [top.id])) { try library.remove(leaf.id) }
    try library.remove(top.id)
    try library.remove(leaf.id)
    #expect(library.entries.isEmpty)
    #expect(throws: LibraryError.notFound(leaf.id)) { try library.remove(leaf.id) }
}

// MARK: File form

@Test func aLibraryRoundTripsDeterministically() throws {
    var library = newLibrary()
    let leaf = Adder().definition
    try library.publish([leaf, wrapper(of: leaf)], summaries: [leaf.id: "Leaf"])
    let data = try library.encoded()
    #expect(try library.encoded() == data)
    let loaded = try SubgraphLibrary.decode(from: data)
    #expect(loaded == library)
    #expect(try loaded.encoded() == data)
    #expect(try SubgraphLibrary.decode(from: library.encoded(prettyPrinted: false)) == library)
    #expect(Array(loaded.entries.keys) == Array(library.entries.keys), "publication order is kept")
}

@Test func badLibraryFilesAreRejected() throws {
    #expect(throws: LibraryError.missingSchemaVersion) { try SubgraphLibrary.decode(from: Data(#"{"id":"x"}"#.utf8)) }
    #expect(throws: LibraryError.newerThanSupported(found: 9, supported: 1)) {
        try SubgraphLibrary.decode(from: Data(#"{"schemaVersion":9}"#.utf8))
    }
    var library = newLibrary()
    try library.publish([Adder().definition])
    let entry = try JSONEncoder().encode(try #require(library.entries.values.first))
    let text = String(decoding: entry, as: UTF8.self)
    let json = #"{"schemaVersion":1,"id":"x","name":"n","entries":[\#(text),\#(text)]}"#
    #expect(throws: DecodingError.self) { try SubgraphLibrary.decode(from: Data(json.utf8)) }
}

@Test func originsAreOmittedFromFilesWhenAbsentAndKeptWhenPresent() throws {
    let plain = Adder().definition
    #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("origin"))
    var tagged = plain
    tagged.origin = SubgraphOrigin(library: "lib", revision: 2, digest: "abc")
    #expect(try JSONDecoder().decode(SubgraphDefinition.self, from: JSONEncoder().encode(tagged)) == tagged)
}

// MARK: Using a library from a document

@Test func importingCopiesDefinitionsWithTheirDependenciesAndRecordsOrigins() throws {
    var library = newLibrary()
    let leaf = Adder().definition, top = wrapper(of: leaf, name: "Top")
    try library.publish([top, leaf])

    let editor = editor()
    let command = try editor.importCommand([top.id], from: library)
    try editor.apply(command)
    #expect(Array(editor.subgraphs.keys) == [leaf.id, top.id], "dependencies come first")
    #expect(editor.subgraphs[leaf.id]?.origin == library.origin(of: leaf.id))
    #expect(editor.subgraphs[top.id]?.origin?.revision == 1)
    #expect(editor.nodes.definition(for: top.typeID) != nil)
    #expect(editor.libraryStatus(of: top.id, in: library) == .upToDate)

    // Nothing to do the second time, and an unknown id is an error.
    #expect(try editor.importCommand([top.id], from: library) == .batch(commands: []))
    let unknown = SubgraphID()
    #expect(throws: LibraryError.notFound(unknown)) { try editor.importCommand([unknown], from: library) }
}

@Test func importingIsOneUndoStep() throws {
    var library = newLibrary()
    let leaf = Adder().definition, top = wrapper(of: leaf)
    try library.publish([leaf, top])
    let editor = editor()
    let history = GraphHistory(editor: editor)
    try history.perform(try editor.importCommand([top.id], from: library), name: "Import")
    try history.undo()
    #expect(editor.subgraphs.isEmpty && editor.nodes.definition(for: top.typeID) == nil)
}

@Test func statusFollowsEditsAndNewRevisions() throws {
    var library = newLibrary()
    let adder = Adder().definition
    try library.publish([adder])
    let editor = editor()
    try editor.apply(.addSubgraph(definition: SubgraphDefinition(id: SubgraphID(), interface: SubgraphInterface(name: "Mine"))))
    let local = try #require(editor.subgraphs.keys.first)
    #expect(editor.libraryStatus(of: local, in: library) == .notFromLibrary)

    try editor.apply(try editor.importCommand([adder.id], from: library))
    #expect(editor.libraryStatus(of: adder.id, in: library) == .upToDate)

    // An edit inside the copy.
    let extra = Node(typeID: "add")
    try editor.apply(.inSubgraph(id: adder.id, command: .addNode(node: extra)))
    #expect(editor.libraryStatus(of: adder.id, in: library) == .locallyModified)

    // The library moves on while the copy is edited.
    var newer = adder
    newer.interface.name = "Adder 2"
    try library.publish([newer])
    #expect(editor.libraryStatus(of: adder.id, in: library) == .modifiedAndUpdateAvailable(revision: 2))

    // Undo the local edit: now only the library is ahead.
    try editor.apply(.inSubgraph(id: adder.id, command: .removeNode(id: extra.id)))
    #expect(editor.libraryStatus(of: adder.id, in: library) == .updateAvailable(revision: 2))

    // Other libraries and removed entries.
    #expect(editor.libraryStatus(of: adder.id, in: SubgraphLibrary(id: "other", name: "Other")) == .notFromLibrary)
    var emptied = library
    try emptied.remove(adder.id)
    #expect(editor.libraryStatus(of: adder.id, in: emptied) == .missingFromLibrary)
}

@Test func updatingTakesTheNewVersionKeepsLinksWherePortsSurviveAndUndoes() throws {
    var library = newLibrary()
    let adder = Adder()
    try library.publish([adder.definition])
    let editor = editor()
    try editor.apply(try editor.importCommand([adder.definition.id], from: library))
    let source = Node(typeID: "const", properties: ["value": 2.0])
    let instance = Node(typeID: adder.definition.typeID, properties: ["offset": 5.0])
    let sink = Node(typeID: "add")
    for node in [source, instance, sink] { try editor.apply(.addNode(node: node)) }
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: source.id, port: "out", direction: .output),
        target: PortAddress(node: instance.id, port: "x", direction: .input)))
    try editor.connect(ConnectionProposal(
        source: PortAddress(node: instance.id, port: "result", direction: .output),
        target: PortAddress(node: sink.id, port: "a", direction: .input)))

    // Version 2 drops the output.
    var v2 = adder.definition
    v2.interface.outputs = []
    try library.publish([v2])
    #expect(editor.libraryStatus(of: v2.id, in: library) == .updateAvailable(revision: 2))

    let before = (editor.graph, editor.subgraphs)
    let change = try editor.apply(try editor.updateCommand(v2.id, from: library))
    #expect(editor.subgraphs[v2.id]?.interface.outputs.isEmpty == true)
    #expect(editor.subgraphs[v2.id]?.origin?.revision == 2)
    #expect(editor.libraryStatus(of: v2.id, in: library) == .upToDate)
    #expect(editor.graph.links.count == 1, "the link to the removed output went; the link into x stayed")
    #expect(editor.graph.nodes[instance.id]?.properties["offset"] == 5.0)

    try editor.revert(change)
    #expect(editor.graph == before.0 && editor.subgraphs == before.1)
}

@Test func updatingAlsoBringsInNewDependenciesAndDiscardsLocalEdits() throws {
    var library = newLibrary()
    let adder = Adder().definition
    try library.publish([adder])
    let editor = editor()
    try editor.apply(try editor.importCommand([adder.id], from: library))
    try editor.apply(.inSubgraph(id: adder.id, command: .addNode(node: Node(typeID: "const"))))

    // Version 2 contains an instance of a new helper subgraph.
    let helper = SubgraphDefinition(interface: SubgraphInterface(name: "Helper"))
    var v2 = adder
    v2.graph.insert(Node(typeID: helper.typeID))
    try library.publish([helper, v2])
    try editor.apply(try editor.updateCommand(adder.id, from: library))
    #expect(editor.subgraphs[helper.id] != nil, "the new dependency was added")
    #expect(editor.subgraphs[adder.id]?.graph.nodes.count == 3, "the local extra node is gone; the helper instance is in")
    #expect(editor.libraryStatus(of: adder.id, in: library) == .upToDate)

    let unknown = SubgraphID()
    #expect(throws: GraphEditError.subgraphNotFound(unknown)) { try editor.updateCommand(unknown, from: library) }
}

@Test func publishingFromADocumentGivesTheLibraryACompleteSetAndAdoptingOriginsMakesItUpToDate() throws {
    let source = editor()
    let leaf = Adder().definition, top = wrapper(of: leaf, name: "Top")
    try source.apply(.addSubgraph(definition: leaf))
    try source.apply(.addSubgraph(definition: top))
    let toPublish = try source.publishable([top.id])
    #expect(toPublish.map(\.id) == [leaf.id, top.id])

    var library = newLibrary()
    let origins = try library.publish(toPublish)
    #expect(source.libraryStatus(of: top.id, in: library) == .notFromLibrary)
    try source.apply(source.adoptOriginsCommand(origins))
    #expect(source.libraryStatus(of: top.id, in: library) == .upToDate)
    #expect(source.libraryStatus(of: leaf.id, in: library) == .upToDate)
    #expect(source.adoptOriginsCommand(origins) == .batch(commands: []), "already adopted: nothing to do")

    let unknown = SubgraphID()
    #expect(throws: GraphEditError.subgraphNotFound(unknown)) { try source.publishable([unknown]) }
}

@Test func aLibraryDefinitionRunsInAnotherDocument() async throws {
    var library = newLibrary()
    let adder = Adder().definition
    try library.publish([adder])

    // A different document imports it and uses it.
    let other = editor()
    try other.apply(try other.importCommand([adder.id], from: library))
    let source = Node(typeID: "const", properties: ["value": 4.0])
    let instance = Node(typeID: adder.typeID, properties: ["offset": 1.0])
    try other.apply(.addNode(node: source)); try other.apply(.addNode(node: instance))
    try other.connect(ConnectionProposal(
        source: PortAddress(node: source.id, port: "out", direction: .output),
        target: PortAddress(node: instance.id, port: "x", direction: .input)))

    // Save and reload the document with no library in sight.
    let document = try GraphDocument.decode(from: other.makeDocument().encoded())
    #expect(document.subgraphs.first?.origin == library.origin(of: adder.id))
    let runner = try GraphRunner(document: document, registry: runnable().0)
    #expect(await runner.step().outputs(of: instance.id)?["result"] == 5.0)
}

// MARK: The update command

@Test func updateSubgraphIsAWholeDefinitionReplacementWithRules() throws {
    let editor = editor()
    let adder = Adder().definition
    try editor.apply(.addSubgraph(definition: adder))
    var changed = adder
    changed.interface.name = "Renamed"
    let change = try editor.apply(.updateSubgraph(definition: changed))
    #expect(editor.subgraphs[adder.id]?.interface.name == "Renamed")
    try editor.revert(change)
    #expect(editor.subgraphs[adder.id] == adder)

    let unknown = SubgraphDefinition(interface: SubgraphInterface(name: "x"))
    #expect(throws: GraphEditError.subgraphNotFound(unknown.id)) { try editor.apply(.updateSubgraph(definition: unknown)) }
    #expect(throws: GraphEditError.invalidScope) {
        try editor.apply(.inSubgraph(id: adder.id, command: .updateSubgraph(definition: adder)))
    }
    var broken = adder
    broken.interface.inputs[0].targets = [PortAddress(node: NodeID(), port: "a", direction: .input)]
    #expect(throws: GraphEditError.self) { try editor.apply(.updateSubgraph(definition: broken)) }
    #expect(editor.subgraphs[adder.id] == adder, "a refused update changes nothing")

    let data = try JSONEncoder().encode(GraphCommand.updateSubgraph(definition: changed))
    #expect(try JSONDecoder().decode(GraphCommand.self, from: data) == .updateSubgraph(definition: changed))
}
