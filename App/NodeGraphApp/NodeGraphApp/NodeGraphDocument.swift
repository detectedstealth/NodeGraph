import NodeGraphCore
import NodeGraphNodes
import NodeGraphSync
import NodeGraphUI
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A node graph file: the JSON of a `GraphDocument`. Declared in the app's Info.plist.
    static let nodeGraph = UTType(exportedAs: "com.brucewadepersonalteam.nodegraph.document")
}

/// One open graph file. The editor, its undo history and the canvas camera live in
/// ``controller``; saving captures a `GraphDocument` from it and opening replaces it.
@Observable
final class NodeGraphDocument: Document {
    static let readableContentTypes = [UTType.nodeGraph]

    var controller: GraphInteractionController

    /// The file's free-form metadata, carried through so a save does not drop it.
    private var metadata: [String: GraphValue] = [:]

    init() {
        controller = GraphInteractionController(model: GraphModels.makeModel(from: nil))
    }

    nonisolated func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<GraphDocument> {
        FileWrapperDocumentReader(configuration) { @Sendable fileWrapper in
            guard let data = fileWrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            return try GraphDocument.decode(from: data)
        }
    }

    @MainActor
    func apply(snapshot: sending GraphDocument, previous: sending GraphDocument?) async throws {
        metadata = snapshot.metadata
        controller = GraphInteractionController(model: GraphModels.makeModel(from: snapshot))
    }

    nonisolated func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<GraphDocument> {
        FileWrapperDocumentWriter(configuration) { @Sendable snapshot, previous in
            FileWrapper(regularFileWithContents: try snapshot.encoded())
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending GraphDocument {
        controller.model.editor.makeDocument(metadata: metadata)
    }
}

/// The editor for an open document. SwiftUI decides a document has unsaved changes from its
/// undo manager, so the model is given the environment's, which makes every edit register an
/// undo action and so trigger autosave.
struct DocumentEditorView: View {
    let document: NodeGraphDocument
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ContentView(controller: document.controller)
            .id(ObjectIdentifier(document.controller))
            .onChange(of: undoManager, initial: true) { document.controller.model.undoManager = undoManager }
            .onChange(of: ObjectIdentifier(document.controller)) { document.controller.model.undoManager = undoManager }
    }
}

/// Builds editor models with the standard node packs.
@MainActor
enum GraphModels {
    /// An editor for `document`, or an empty graph. Node types the packs lack get placeholders, so
    /// a file from a build with more packs opens and saves without losing them.
    static func makeModel(from document: GraphDocument?) -> GraphEditorModel {
        var nodes = NodeRegistry()
        var types = TypeRegistry()
        StandardPack.register(nodes: &nodes, types: &types)
        let editor: GraphEditor
        if let document {
            editor = GraphEditor(
                document: document, nodes: nodes.addingPlaceholders(for: document.graph), types: types)
        } else {
            editor = GraphEditor(nodes: nodes, types: types)
        }
        let model = GraphEditorModel(editor: editor)
        model.registerContentDrawing(for: "util.watch", .readout(of: "result"))
        LibraryStorage.shared.attach(to: model)
        return model
    }
}

/// Subgraph libraries live in the app's Application Support folder, shared by every open
/// document. A model gets the libraries stored when it is created, and each change it makes to one
/// is saved at once. Another open document sees the change when it is next opened.
@MainActor
final class LibraryStorage {
    static let shared = LibraryStorage()

    private let store: FileSubgraphLibraryStore?

    private init() {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        store = support.map { FileSubgraphLibraryStore(directory: $0.appendingPathComponent("NodeGraph/Libraries")) }
    }

    func attach(to model: GraphEditorModel) {
        guard let store else { return }
        model.onLibraryChange = { library in
            Task { try? await store.save(library) }
        }
        Task {
            let libraries = (try? await store.libraries()) ?? []
            model.setLibraries(libraries.sorted { $0.name < $1.name })
        }
    }
}
