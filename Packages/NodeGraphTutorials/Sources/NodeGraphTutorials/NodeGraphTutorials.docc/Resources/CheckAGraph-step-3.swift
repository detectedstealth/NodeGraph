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

/// A lint is a type that looks at a graph's structure and reports what is valid but suspicious.
/// A pack adds its own, because only it knows what is suspicious in its domain.
struct UnfedConverter: GraphLint {
    let id = "temperature.unfedConverter"
    let summary = "A Convert Temperature node has nothing linked to it and shows its default of 20 degrees."

    func check(in context: LintContext) -> [LintFinding] {
        context.graph.nodes.values.compactMap { node in
            guard node.typeID == "temperature.convert" else { return nil }
            let input = PortAddress(node: node.id, port: "temperature", direction: .input)
            guard context.validation.links(into: input).isEmpty else { return nil }
            return LintFinding(
                lint: id, level: .hint,
                diagnostic: GraphDiagnostic(
                    severity: .warning, code: "temperature.unfed",
                    message: "Convert Temperature has no sensor linked, so it always shows 20 degrees Celsius.",
                    node: node.id, port: input),
                fix: SuggestedFix(description: "Remove the node", command: .removeNode(id: node.id)))
        }
    }
}
