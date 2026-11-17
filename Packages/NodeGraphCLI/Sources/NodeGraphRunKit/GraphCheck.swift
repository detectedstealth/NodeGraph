import Foundation
import NodeGraphAssistant
import NodeGraphCore

/// What `validate` and `lint` found in a document, in a form that prints as JSON or as text.
public struct CheckReport: Codable, Hashable, Sendable {
    /// One thing found.
    public struct Finding: Codable, Hashable, Sendable {
        /// `validation` for something invalid, `lint` for something valid but suspicious.
        public var kind: String
        /// The diagnostic code for validation (`connection.typeMismatch`), the lint id for lints.
        public var id: String
        /// `error` or `warning` for validation; `problem` or `hint` for lints.
        public var severity: String
        public var message: String
        /// The node's id, when the finding is about one.
        public var node: String?
        /// The node's type, so a reader need not look the id up.
        public var nodeType: String?
        /// Whether a lint has a suggested edit. The tool never applies it.
        public var hasFix: Bool
    }

    public var findings: [Finding]

    /// Findings that should fail a check: validation errors and lint problems, and with `strict`
    /// everything else too.
    public func failing(strict: Bool = false) -> [Finding] {
        findings.filter { strict || $0.severity == "error" || $0.severity == "problem" }
    }

    /// JSON with sorted keys, so equal documents give equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// One line per finding, then a summary, for a terminal or a CI log.
    public var text: String {
        var lines = findings.map { finding in
            let place = finding.nodeType.map { " [\($0)]" } ?? ""
            return "\(finding.severity): \(finding.id)\(place): \(finding.message)"
        }
        lines.append(findings.isEmpty ? "No findings." : "\(findings.count) finding\(findings.count == 1 ? "" : "s").")
        return lines.joined(separator: "\n")
    }
}

/// Checks and summarizes a document without running it. Nothing here needs a model or a window.
public enum GraphCheck {
    /// An editor over `document` with the standard registries, which is what every check reads.
    private static func editor(for document: GraphDocument) -> GraphEditor {
        let (nodes, types) = GraphRun.standardRegistries()
        return GraphEditor(document: document, nodes: nodes, types: types)
    }

    /// Validates the root graph and every subgraph: node types, property values and every link.
    public static func validate(_ document: GraphDocument) -> CheckReport {
        let editor = editor(for: document)
        let validator = GraphValidator(connections: editor.connectionValidator)
        var diagnostics: [(GraphDiagnostic, Graph)] = []
        let root = editor.validationContext
        diagnostics += validator.validate(root).map { ($0, root.graph) }
        for id in editor.subgraphs.keys {
            guard let context = editor.validationContext(in: id) else { continue }
            diagnostics += validator.validate(context).map { ($0, context.graph) }
        }
        return CheckReport(findings: diagnostics.map { diagnostic, graph in
            finding(kind: "validation", id: diagnostic.code.rawValue, severity: diagnostic.severity.rawValue,
                    diagnostic: diagnostic, graph: graph, hasFix: false)
        })
    }

    /// Runs the standard lints on the root graph. They look at structure only and never run it.
    public static func lint(_ document: GraphDocument) -> CheckReport {
        let editor = editor(for: document)
        let findings = GraphLinter().run(in: LintContext(editor: editor))
        return CheckReport(findings: findings.map { found in
            finding(kind: "lint", id: found.lint, severity: found.level.rawValue,
                    diagnostic: found.diagnostic, graph: editor.graph, hasFix: found.fix != nil)
        })
    }

    /// The root graph as compact text: short names for the nodes, then the links.
    public static func digest(_ document: GraphDocument, detail: GraphDigest.Detail = .compact) -> String {
        let editor = editor(for: document)
        return GraphDigest(graph: editor.graph, registry: editor.nodes, detail: detail).text
    }

    private static func finding(
        kind: String, id: String, severity: String, diagnostic: GraphDiagnostic, graph: Graph, hasFix: Bool
    ) -> CheckReport.Finding {
        let node = diagnostic.node
        return CheckReport.Finding(
            kind: kind, id: id, severity: severity, message: diagnostic.message,
            node: node.map { $0.uuid.uuidString },
            nodeType: node.flatMap { graph.nodes[$0]?.typeID.rawValue }, hasFix: hasFix)
    }
}
