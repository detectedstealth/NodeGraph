import Testing
import NodeGraphCore
@testable import NodeGraphUI

@MainActor
@Suite struct SubgraphLibraryEditingTests {
    let model = TestKit.makeModel()
    let instance: NodeID
    let subgraph: SubgraphID

    /// A sink wrapped as "Wrapped", at the root.
    init() throws {
        let sink = Node(typeID: TestKit.sink, position: GraphPoint(x: 400, y: 0))
        try model.perform(.addNode(node: sink))
        let conversion = try model.editor.convertToSubgraphCommand(nodes: [sink.id], name: "Wrapped")
        try model.perform(conversion.command)
        instance = conversion.instance
        subgraph = conversion.subgraph
    }

    private func origin() -> SubgraphOrigin? { model.editor.subgraphs[subgraph]?.origin }

    @Test func newLibrariesGetUniqueNamesAndAreReported() {
        var reported: [String] = []
        model.onLibraryChange = { reported.append($0.name) }
        let first = model.createLibrary()
        model.createLibrary()
        #expect(model.libraries.map(\.name) == ["Library", "Library 2"])
        #expect(reported == ["Library", "Library 2"])
        #expect(model.renameLibrary(first, to: "  Shared "))
        #expect(model.library(first)?.name == "Shared")
        #expect(reported.last == "Shared")
        #expect(!model.renameLibrary(first, to: "  "))
    }

    @Test func publishingRecordsTheOriginAsOneUndoStep() throws {
        let id = model.createLibrary()
        #expect(model.libraryStatus(of: subgraph) == .notFromLibrary)
        #expect(model.publishSubgraph(subgraph, to: id, summary: "A wrapper"))
        let library = try #require(model.library(id))
        #expect(library.entry(for: subgraph)?.revision == 1)
        #expect(library.entry(for: subgraph)?.summary == "A wrapper")
        #expect(origin()?.library == id)
        #expect(model.libraryStatus(of: subgraph) == .upToDate)
        try model.undo()
        #expect(origin() == nil)
    }

    @Test func publishingAgainAfterAnEditNumbersTheNextRevision() throws {
        let id = model.createLibrary()
        model.publishSubgraph(subgraph, to: id)
        model.enterSubgraph(of: instance)
        #expect(model.renameSubgraph(to: "Renamed"))
        #expect(model.libraryStatus(of: subgraph) == .locallyModified)
        #expect(model.publishSubgraph(subgraph, to: id))
        #expect(model.library(id)?.entry(for: subgraph)?.revision == 2)
        #expect(model.libraryStatus(of: subgraph) == .upToDate)
    }

    @Test func publishingReportsTheLibrary() {
        let id = model.createLibrary()
        var reported = 0
        model.onLibraryChange = { _ in reported += 1 }
        model.publishSubgraph(subgraph, to: id)
        #expect(reported == 1)
    }

    @Test func publishingToAnUnknownLibraryDoesNothing() {
        #expect(!model.publishSubgraph(subgraph, to: LibraryID("nope")))
        #expect(origin() == nil)
    }

    @Test func importingCopiesTheDefinitionAndRecordsItsOrigin() throws {
        let id = model.createLibrary()
        model.publishSubgraph(subgraph, to: id)
        // Start a second document from the library alone.
        let other = TestKit.makeModel()
        other.setLibraries(model.libraries)
        #expect(other.importSubgraphs([subgraph], from: id))
        #expect(other.editor.subgraphs[subgraph]?.origin?.library == id)
        #expect(other.libraryStatus(of: subgraph) == .upToDate)
        let typeID = try #require(other.editor.subgraphs[subgraph]).typeID
        #expect(other.makeNodeCatalog().entries.contains { $0.id == typeID })
        // A second import finds nothing to add.
        #expect(!other.importSubgraphs([subgraph], from: id))
        try other.undo()
        #expect(other.editor.subgraphs[subgraph] == nil)
    }

    @Test func updatingTakesTheLibrarysNewerVersion() throws {
        let id = model.createLibrary()
        model.publishSubgraph(subgraph, to: id)
        let other = TestKit.makeModel()
        other.setLibraries(model.libraries)
        other.importSubgraphs([subgraph], from: id)

        model.enterSubgraph(of: instance)
        model.renameSubgraph(to: "Newer")
        model.publishSubgraph(subgraph, to: id)
        other.setLibraries(model.libraries)

        #expect(other.libraryStatus(of: subgraph) == .updateAvailable(revision: 2))
        #expect(other.updateSubgraphFromLibrary(subgraph))
        #expect(other.editor.subgraphs[subgraph]?.interface.name == "Newer")
        #expect(other.libraryStatus(of: subgraph) == .upToDate)
    }

    @Test func aSubgraphWithoutALoadedLibraryHasNothingToUpdateFrom() {
        #expect(!model.updateSubgraphFromLibrary(subgraph))
        let id = model.createLibrary()
        model.publishSubgraph(subgraph, to: id)
        model.setLibraries([])
        #expect(model.libraryStatus(of: subgraph) == .notFromLibrary)
        #expect(!model.updateSubgraphFromLibrary(subgraph))
    }

    @Test func aReadOnlyCanvasPublishesNothing() {
        let id = model.createLibrary()
        model.isEditable = false
        #expect(!model.publishSubgraph(subgraph, to: id))
        #expect(model.library(id)?.entries.isEmpty == true)
    }
}
