/// A check on a whole graph, for domain constraints no single link can express, such as
/// "exactly one render node" or "every actuator needs a controller".
public protocol GraphRule: Sendable {
    /// Stable identifier, unique among rules.
    var id: String { get }
    /// One sentence describing the rule, suitable for showing to a user or an LLM.
    var summary: String { get }
    func check(in context: ValidationContext) -> [GraphDiagnostic]
}

/// Validates a complete graph: node types, property values, every link, and domain graph rules.
///
/// Use it on loaded documents and on graphs produced by tools or LLMs. Diagnostics are
/// structured so a generator can be shown exactly what to fix.
public struct GraphValidator: Sendable {
    public var connections: ConnectionValidator
    public var graphRules: [any GraphRule]

    public init(
        connections: ConnectionValidator = ConnectionValidator(),
        graphRules: [any GraphRule] = []
    ) {
        self.connections = connections
        self.graphRules = graphRules
    }

    /// All diagnostics for the graph in `context`, in a stable order: nodes, links, graph rules.
    public func validate(_ context: ValidationContext) -> [GraphDiagnostic] {
        var found: [GraphDiagnostic] = []
        for node in context.graph.nodes.values {
            found += validateProperties(of: node, in: context)
        }
        for link in context.graph.links.values {
            found += validate(link, in: context)
        }
        for rule in graphRules {
            found += rule.check(in: context)
        }
        return found
    }

    private func validateProperties(of node: Node, in context: ValidationContext) -> [GraphDiagnostic] {
        guard let definition = context.nodes.definition(for: node.typeID) else {
            return [GraphDiagnostic(
                code: .unknownNodeType, message: "Node type \"\(node.typeID)\" is not registered.",
                node: node.id)]
        }
        var found: [GraphDiagnostic] = []
        for (id, value) in node.properties.sorted(by: { $0.key < $1.key }) {
            guard let property = definition.property(id) else {
                found.append(GraphDiagnostic(
                    code: .unknownProperty,
                    message: "\(node.typeID) has no property \"\(id)\".", node: node.id))
                continue
            }
            do {
                try property.validate(value)
            } catch {
                found.append(GraphDiagnostic(
                    code: .invalidProperty,
                    message: "Value for property \"\(id)\" is invalid: \(error).", node: node.id))
            }
        }
        return found
    }

    /// Re-checks a link as if it were being added to the graph without itself.
    private func validate(_ link: Link, in context: ValidationContext) -> [GraphDiagnostic] {
        var others = context
        others.graph.removeLink(link.id)
        let result = connections.check(ConnectionProposal(source: link.source, target: link.target), in: others)
        var found = result.diagnostics.map { diagnostic in
            var tagged = diagnostic
            tagged.link = link.id
            return tagged
        }
        if !result.replacedLinks.isEmpty {
            found.append(GraphDiagnostic(
                code: .tooManyLinks,
                message: "A port that accepts one link has \(result.replacedLinks.count + 1).",
                node: link.target.node, port: link.target, link: link.id))
        }
        return found
    }
}
