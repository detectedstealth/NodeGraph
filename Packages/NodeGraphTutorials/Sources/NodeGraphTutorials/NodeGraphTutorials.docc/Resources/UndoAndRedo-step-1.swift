import NodeGraphCore

/// Wraps the addition graph in a history, so edits made through it can be undone.
func makeHistory() throws -> GraphHistory {
    GraphHistory(editor: try makeAdditionGraph())
}
