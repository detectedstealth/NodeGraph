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
