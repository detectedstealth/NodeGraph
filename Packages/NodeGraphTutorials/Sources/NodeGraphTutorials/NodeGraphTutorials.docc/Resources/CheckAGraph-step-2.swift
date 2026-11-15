import NodeGraphAssistant
import NodeGraphCore

/// The graph as compact text, in the form a model or a person can read in one go.
func outline(of editor: GraphEditor) -> String {
    GraphDigest(graph: editor.graph, registry: editor.nodes, detail: .outline).text
}

/// What looks wrong or suspicious, without running the graph.
func findings(in editor: GraphEditor) -> [LintFinding] {
    GraphLinter().run(in: LintContext(editor: editor))
}
