import NodeGraphCore

/// The lints that need no domain knowledge. See ``GraphLinter/standardLints``.
public enum Lints {
    /// A node as a message names it: its title if it has one, and its type.
    static func name(of node: Node, in context: LintContext) -> String {
        let display = context.nodes.definition(for: node.typeID)?.displayName ?? node.typeID.rawValue
        return node.title.map { "\"\($0)\" (\(node.typeID.rawValue))" } ?? "\(display) (\(node.typeID.rawValue))"
    }

    /// Nodes that take part in a run, with their definitions as the node sees them.
    static func resolved(_ context: LintContext) -> [(node: Node, definition: NodeDefinition)] {
        context.graph.nodes.values.compactMap { node in
            context.nodes.definition(for: node).map { (node, $0) }
        }
    }

    /// A data input with no link and no default, so nothing can ever arrive there.
    public struct UnconnectedInput: GraphLint {
        public let id = "lint.unconnectedInput"
        public let summary = "A data input has no link and no default value."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            var found: [LintFinding] = []
            for (node, definition) in Lints.resolved(context)
            where node.mode != .never && !context.graph.links(attachedTo: node.id).isEmpty {  // an unlinked node is reported as isolated
                for port in definition.inputs where port.kind == .data && port.defaultValue == nil {
                    let address = PortAddress(node: node.id, port: port.id, direction: .input)
                    guard context.validation.links(into: address).isEmpty else { continue }
                    found.append(LintFinding(lint: id, level: .problem, diagnostic: GraphDiagnostic(
                        severity: .warning, code: .unconnectedInput,
                        message: "Input \"\(port.displayName)\" of \(Lints.name(of: node, in: context)) has no link and no default value.",
                        node: node.id, port: address)))
                }
            }
            return found
        }
    }

    /// A node with no links at all.
    public struct IsolatedNode: GraphLint {
        public let id = "lint.isolatedNode"
        public let summary = "A node is not linked to anything."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            Lints.resolved(context).compactMap { node, definition in
                guard !definition.ports.isEmpty, context.graph.links(attachedTo: node.id).isEmpty else { return nil }
                return LintFinding(
                    lint: id, level: .hint,
                    diagnostic: GraphDiagnostic(
                        severity: .warning, code: .isolatedNode,
                        message: "\(Lints.name(of: node, in: context)) is not linked to anything.", node: node.id),
                    fix: SuggestedFix(description: "Remove the node", command: .removeNode(id: node.id)))
            }
        }
    }

    /// A node whose outputs nothing reads, though it is linked on the input side.
    public struct UnusedOutput: GraphLint {
        public let id = "lint.unusedOutput"
        public let summary = "A node has outputs but nothing reads any of them."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            Lints.resolved(context).compactMap { node, definition in
                // A pass-through (watch, log, reroute) is there to be looked at, not read by another node.
                let isPassThrough = definition.inputs.count == 1 && definition.outputs.count == 1
                    && definition.inputs[0].type == definition.outputs[0].type
                guard !definition.outputs.isEmpty, !isPassThrough,
                      !context.graph.links(attachedTo: node.id).isEmpty,  // an unlinked node is reported as isolated
                      context.validation.outgoingLinks(of: node.id).isEmpty else { return nil }
                return LintFinding(lint: id, level: .hint, diagnostic: GraphDiagnostic(
                    severity: .warning, code: .unusedOutput,
                    message: "Nothing reads the outputs of \(Lints.name(of: node, in: context)).", node: node.id))
            }
        }
    }

    /// A switched-off or muted node that other nodes depend on.
    public struct InactiveNode: GraphLint {
        public let id = "lint.inactiveNode"
        public let summary = "A disabled or muted node feeds other nodes."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            context.graph.nodes.values.compactMap { node in
                guard node.mode == .never || node.mode == .muted else { return nil }
                let consumers = Set(context.validation.outgoingLinks(of: node.id).map(\.target.node))
                guard !consumers.isEmpty else { return nil }
                let state = node.mode == .never ? "disabled" : "muted"
                let effect = node.mode == .never
                    ? "so the nodes that depend on it are skipped"
                    : "so the nodes it feeds run with their inputs unlinked"
                return LintFinding(
                    lint: id, level: .problem,
                    diagnostic: GraphDiagnostic(
                        severity: .warning, code: .inactiveNode,
                        message: "\(Lints.name(of: node, in: context)) is \(state), \(effect).",
                        node: node.id),
                    fix: SuggestedFix(
                        description: "Set the node to run normally",
                        command: .setNodeAttribute(node: node.id, attribute: .mode(value: .always))))
            }
        }
    }

    /// A node whose result can never change, computed from constants.
    ///
    /// Only the last node of such a chain is reported. Nodes that read a graph variable are not
    /// constant, since a run can override a variable.
    public struct ConstantExpression: GraphLint {
        public let id = "lint.constantExpression"
        public let summary = "A node computes a result from constants only, which could be a single value."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            var memo: [NodeID: Bool] = [:]
            var visiting = Set<NodeID>()
            func isConstant(_ id: NodeID) -> Bool {
                if let known = memo[id] { return known }
                guard visiting.insert(id).inserted, let node = context.graph.nodes[id],
                      let definition = context.nodes.definition(for: node) else { return false }
                defer { visiting.remove(id) }
                var result = definition.isPure && !definition.isFeedback && node.mode == .always
                    && !definition.properties.contains { $0.kind == .variable }
                if result {
                    for link in context.graph.links.values where link.target.node == id && !isConstant(link.source.node) {
                        result = false
                        break
                    }
                }
                memo[id] = result
                return result
            }

            var found: [LintFinding] = []
            for node in Lints.resolved(context).map(\.node) {
                let feeders = context.graph.links.values.filter { $0.target.node == node.id }
                let consumers = context.validation.outgoingLinks(of: node.id)
                guard !feeders.isEmpty, !consumers.isEmpty, isConstant(node.id),
                      consumers.allSatisfy({ !isConstant($0.target.node) }) else { continue }
                found.append(LintFinding(lint: id, level: .hint, diagnostic: GraphDiagnostic(
                    severity: .warning, code: .constantExpression,
                    message: "\(Lints.name(of: node, in: context)) only depends on constants, so its result never changes. "
                        + "A constant node would do.", node: node.id)))
            }
            return found
        }
    }

    /// Two pure nodes that compute the same thing from the same inputs.
    public struct DuplicateNode: GraphLint {
        public let id = "lint.duplicateNode"
        public let summary = "Two nodes of the same type have the same settings and the same inputs."
        public init() {}

        private struct Key: Hashable {
            var type: NodeTypeID
            var properties: [PropertyID: GraphValue]
            var portCounts: [String: Int]
            var inputs: [String]
        }

        public func check(in context: LintContext) -> [LintFinding] {
            var first: [Key: Node] = [:]
            var found: [LintFinding] = []
            for (node, definition) in Lints.resolved(context) where definition.isPure && node.mode == .always {
                let incoming = context.graph.links.values.filter { $0.target.node == node.id }
                guard !incoming.isEmpty else { continue }  // equal constants are not worth a remark
                let key = Key(
                    type: node.typeID, properties: node.properties, portCounts: node.portCounts,
                    inputs: incoming.map { "\($0.target.port.rawValue)<\($0.source.node)/\($0.source.port.rawValue)" }.sorted())
                if first[key] != nil {
                    found.append(LintFinding(lint: id, level: .hint, diagnostic: GraphDiagnostic(
                        severity: .warning, code: .duplicateNode,
                        message: "\(Lints.name(of: node, in: context)) repeats another node with the same settings "
                            + "and inputs; one can feed both consumers.", node: node.id)))
                } else {
                    first[key] = node
                }
            }
            return found
        }
    }

    /// A group that frames no nodes.
    public struct EmptyGroup: GraphLint {
        public let id = "lint.emptyGroup"
        public let summary = "A group contains no nodes."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            context.graph.groups.values.compactMap { group in
                guard context.graph.members(of: group, frame: context.nodes.frame(of:)).isEmpty else { return nil }
                return LintFinding(
                    lint: id, level: .hint,
                    diagnostic: GraphDiagnostic(
                        severity: .warning, code: .emptyGroup, message: "Group \"\(group.title)\" contains no nodes."),
                    fix: SuggestedFix(description: "Remove the group", command: .removeGroup(id: group.id)))
            }
        }
    }

    /// A variable no node reads, in the root graph or in any subgraph.
    public struct UnusedVariable: GraphLint {
        public let id = "lint.unusedVariable"
        public let summary = "A graph variable is declared but no node reads it."
        public init() {}

        public func check(in context: LintContext) -> [LintFinding] {
            var used = Set<String>()
            for graph in [context.graph] + context.subgraphs.map(\.graph) {
                for node in graph.nodes.values {
                    guard let definition = context.nodes.definition(for: node) else { continue }
                    for property in definition.properties where property.kind == .variable {
                        if let name = node.value(of: property.id, in: definition)?.stringValue { used.insert(name) }
                    }
                }
            }
            return context.graph.variables.values.compactMap { variable in
                guard !used.contains(variable.name) else { return nil }
                return LintFinding(
                    lint: id, level: .hint,
                    diagnostic: GraphDiagnostic(
                        severity: .warning, code: .unusedVariable,
                        message: "Variable \"\(variable.name)\" is declared but no node reads it."),
                    fix: SuggestedFix(
                        description: "Remove the variable", command: .removeVariable(name: variable.name)))
            }
        }
    }
}
