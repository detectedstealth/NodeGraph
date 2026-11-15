import Foundation
import NodeGraphCore
import NodeGraphSync

/// The editor's graph as JSON, ready to write to a file.
func saveToData(_ editor: GraphEditor) throws -> Data {
    try editor.makeDocument().encoded()
}
