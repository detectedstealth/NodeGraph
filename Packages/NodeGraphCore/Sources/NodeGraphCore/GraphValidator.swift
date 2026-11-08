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

        // Cycles are found in one pass over the whole graph. Asking `noCycle` about every link
        // separately would walk the graph once per link.
        let checksCycles = connections.rules.contains { $0.id == "noCycle" }
        let perLink = checksCycles ? connections.removing(ruleID: "noCycle") : connections
        let cyclic = checksCycles ? Self.linksInCycles(context) : []
        for link in context.graph.links.values {
            found += validate(link, in: context, using: perLink)
            if cyclic.contains(link.id) {
                found.append(GraphDiagnostic(
                    code: .cycle, message: "This link is part of a cycle.",
                    node: link.target.node, port: link.target, link: link.id))
            }
        }
        for rule in graphRules {
            found += rule.check(in: context)
        }
        return found
    }

    /// Links that run between two nodes of the same loop, ignoring links leaving feedback nodes.
    private static func linksInCycles(_ context: ValidationContext) -> Set<LinkID> {
        let components: [[NodeID]]
        do {
            _ = try ExecutionPlan.compile(context.graph, nodes: context.nodes)
            return []
        } catch ExecutionPlanError.cycle(let found) {
            components = found
        } catch {
            return []
        }
        var component: [NodeID: Int] = [:]
        for (index, members) in components.enumerated() { for node in members { component[node] = index } }
        return Set(context.graph.links.values.compactMap { link in
            guard link.source.node != link.target.node,
                  let from = component[link.source.node], from == component[link.target.node],
                  context.definition(of: link.source.node)?.isFeedback != true else { return nil }
            return link.id
        })
    }

    private func validateProperties(of node: Node, in context: ValidationContext) -> [GraphDiagnostic] {
        guard let definition = context.nodes.definition(for: node.typeID) else {
            return [GraphDiagnostic(
                code: .unknownNodeType, message: "Node type \"\(node.typeID)\" is not registered.",
                node: node.id)]
        }
        var found: [GraphDiagnostic] = []
        for (group, count) in node.portCounts.sorted(by: { $0.key < $1.key }) {
            guard let declared = definition.dynamicPorts.first(where: { $0.id == group }) else {
                found.append(GraphDiagnostic(
                    code: .invalidPortCount, message: "\(node.typeID) has no port group \"\(group)\".", node: node.id))
                continue
            }
            if count != declared.clamped(count) {
                found.append(GraphDiagnostic(
                    code: .invalidPortCount,
                    message: "Port group \"\(group)\" has \(count) ports, outside its limits.", node: node.id))
            }
        }
        // A variable name that no variable has makes the node fail when it runs. Blank only means
        // none was picked yet, so that is a warning.
        if let declared = context.variableNames {
            for property in definition.properties where property.kind == .variable {
                guard let name = node.value(of: property.id, in: definition)?.stringValue,
                      !declared.contains(name) else { continue }
                found.append(GraphDiagnostic(
                    severity: name.isEmpty ? .warning : .error, code: .undeclaredVariable,
                    message: name.isEmpty
                        ? "Property \"\(property.displayName)\" has no variable chosen."
                        : "The graph has no variable named \"\(name)\".",
                    node: node.id))
            }
        }
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
    private func validate(
        _ link: Link, in context: ValidationContext, using connections: ConnectionValidator
    ) -> [GraphDiagnostic] {
        var others = context
        others.ignoredLink = link.id
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
