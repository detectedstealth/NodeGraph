import Foundation
import NodeGraphCore
import NodeGraphSync

/// The editor's graph as JSON, ready to write to a file.
func saveToData(_ editor: GraphEditor) throws -> Data {
    try editor.makeDocument().encoded()
}

/// Reads JSON written by ``saveToData(_:)`` into a new editor.
func openFromData(_ data: Data) throws -> GraphEditor {
    let document = try GraphDocument.decode(from: data)
    let blank = makeEditor()
    return GraphEditor(document: document, nodes: blank.nodes, types: blank.types)
}

/// Keeps the graph in a store and returns its new revision.
func saveToStore(_ editor: GraphEditor, store: some GraphStore, id: GraphID) async throws -> GraphRevision {
    let summary = try await store.save(editor.makeDocument(), as: id, name: "Addition")
    return summary.revision
}

/// Saves only if nobody saved since `revision`. Returns false if someone did.
func saveIfUnchanged(
    _ editor: GraphEditor, store: some GraphStore, id: GraphID, since revision: GraphRevision
) async throws -> Bool {
    do {
        _ = try await store.save(
            editor.makeDocument(), as: id, name: "Addition", expecting: .revision(revision))
        return true
    } catch GraphStoreError.conflict {
        return false
    }
}
