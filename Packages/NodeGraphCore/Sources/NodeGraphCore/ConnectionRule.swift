/// A proposed link from an output port to an input port.
public struct ConnectionProposal: Hashable, Sendable, Codable {
    public var source: PortAddress
    public var target: PortAddress

    public init(source: PortAddress, target: PortAddress) {
        self.source = source
        self.target = target
    }

    /// Returns the proposal with the output end as `source`, for drags that start on an input.
    /// Unchanged unless the ends are clearly reversed.
    public func oriented() -> ConnectionProposal {
        source.direction == .input && target.direction == .output
            ? ConnectionProposal(source: target, target: source)
            : self
    }
}

/// Everything a rule may consult. Rules never mutate it.
public struct ValidationContext: Sendable {
    public var graph: Graph
    public var nodes: NodeRegistry
    public var types: TypeRegistry
    /// A link to pretend is absent. Set while re-checking an existing link as if it were being
    /// added, so the check does not collide with itself. Use the link queries below, which
    /// honour it, instead of reading `graph.links` directly in a rule.
    public var ignoredLink: LinkID?
    /// The names of the variables the document declares (they live on the root graph, so a
    /// subgraph's context needs them passed in). Nil when unknown, which skips the check that a
    /// node's ``PropertyKind/variable`` property names a declared variable.
    public var variableNames: Set<String>?

    public init(
        graph: Graph, nodes: NodeRegistry, types: TypeRegistry, ignoring ignoredLink: LinkID? = nil,
        variableNames: Set<String>? = nil
    ) {
        self.variableNames = variableNames
        self.graph = graph
        self.nodes = nodes
        self.types = types
        self.ignoredLink = ignoredLink
    }

    /// Links that end at the given input port, not counting ``ignoredLink``.
    public func links(into target: PortAddress) -> [Link] {
        graph.links(into: target).filter { $0.id != ignoredLink }
    }

    /// Links that start at the given output port, not counting ``ignoredLink``.
    public func links(from source: PortAddress) -> [Link] {
        graph.links(from: source).filter { $0.id != ignoredLink }
    }

    /// Links that start at any output port of `node`, not counting ``ignoredLink``.
    public func outgoingLinks(of node: NodeID) -> [Link] {
        graph.outgoingLinks(of: node).filter { $0.id != ignoredLink }
    }

    /// The definition for a node in the graph, or nil if the node or its type is unknown.
    public func definition(of node: NodeID) -> NodeDefinition? {
        graph.nodes[node].flatMap { nodes.definition(for: $0) }
    }

    /// The definition of the addressed port, or nil if the node, type or port is unknown.
    public func port(_ address: PortAddress) -> PortDefinition? {
        definition(of: address.node)?.port(address.port, direction: address.direction)
    }
}

/// A check on whether one proposed link is allowed.
///
/// Core ships structural rules (``ConnectionRules/standard``). A domain pack adds its own, for
/// example "a video clip output may only feed a timeline" for editing or "actuators accept only
/// one controller" for robotics. Rules must tolerate missing nodes and ports, since they run
/// together; the endpoint rule reports those.
public protocol ConnectionRule: Sendable {
    /// Stable identifier, unique among rules.
    var id: String { get }
    /// One sentence describing the rule, suitable for showing to a user or an LLM.
    var summary: String { get }
    /// Diagnostics for `proposal`. Empty means the rule has no objection.
    func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic]
}

/// The built-in structural connection rules.
public enum ConnectionRules {
    /// Endpoint existence, direction, no self-links, port kind, type compatibility, no
    /// duplicates, and no cycles. A domain that allows cycles (state machines) omits ``NoCycle``.
    public static var standard: [any ConnectionRule] {
        [EndpointsExist(), Direction(), NoSelfLink(), PortKindMatch(), PortTypeCompatible(),
         NoDuplicateLink(), NoCycle()]
    }

    /// Both nodes exist, their types are registered, and both ports are declared.
    public struct EndpointsExist: ConnectionRule {
        public let id = "endpoints"
        public let summary = "Both nodes and both ports must exist."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            var found: [GraphDiagnostic] = []
            for address in [proposal.source, proposal.target] {
                guard context.graph.nodes[address.node] != nil else {
                    found.append(GraphDiagnostic(
                        code: .missingNode, message: "Node \(address.node) does not exist.",
                        node: address.node, port: address))
                    continue
                }
                guard let definition = context.definition(of: address.node) else {
                    found.append(GraphDiagnostic(
                        code: .unknownNodeType,
                        message: "Node \(address.node) has an unregistered type.",
                        node: address.node, port: address))
                    continue
                }
                if definition.port(address.port, direction: address.direction) == nil {
                    found.append(GraphDiagnostic(
                        code: .missingPort,
                        message: "\(definition.typeID) has no \(address.direction.rawValue) port \"\(address.port)\".",
                        node: address.node, port: address))
                }
            }
            return found
        }
    }

    /// The link runs from an output to an input.
    public struct Direction: ConnectionRule {
        public let id = "direction"
        public let summary = "A link must run from an output port to an input port."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            var found: [GraphDiagnostic] = []
            if proposal.source.direction != .output {
                found.append(GraphDiagnostic(
                    code: .wrongDirection, message: "The link must start at an output port.",
                    node: proposal.source.node, port: proposal.source))
            }
            if proposal.target.direction != .input {
                found.append(GraphDiagnostic(
                    code: .wrongDirection, message: "The link must end at an input port.",
                    node: proposal.target.node, port: proposal.target))
            }
            return found
        }
    }

    /// A node may not link to itself.
    public struct NoSelfLink: ConnectionRule {
        public let id = "noSelfLink"
        public let summary = "A node cannot be linked to itself."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            proposal.source.node == proposal.target.node
                ? [GraphDiagnostic(code: .selfLink, message: "A node cannot be linked to itself.",
                                   node: proposal.source.node, port: proposal.target)]
                : []
        }
    }

    /// Data ports connect to data ports, trigger ports to trigger ports.
    public struct PortKindMatch: ConnectionRule {
        public let id = "portKind"
        public let summary = "Data ports connect only to data ports, and trigger ports only to trigger ports."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            guard let source = context.port(proposal.source), let target = context.port(proposal.target),
                  source.kind != target.kind else { return [] }
            return [GraphDiagnostic(
                code: .kindMismatch,
                message: "Cannot connect a \(source.kind.rawValue) port to a \(target.kind.rawValue) port.",
                node: proposal.target.node, port: proposal.target)]
        }
    }

    /// The output type may feed the input type according to the ``TypeRegistry``.
    public struct PortTypeCompatible: ConnectionRule {
        public let id = "portType"
        public let summary = "The output's type must be compatible with the input's type."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            guard let source = context.port(proposal.source), let target = context.port(proposal.target),
                  source.kind == .data, target.kind == .data,
                  !context.types.connectability(from: source.type, to: target.type).isConnectable
            else { return [] }
            return [GraphDiagnostic(
                code: .typeMismatch,
                message: "Cannot connect type \"\(source.type)\" to type \"\(target.type)\".",
                node: proposal.target.node, port: proposal.target)]
        }
    }

    /// The same two ports are not already linked.
    public struct NoDuplicateLink: ConnectionRule {
        public let id = "noDuplicate"
        public let summary = "The same two ports cannot be linked twice."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            guard let existing = context.links(into: proposal.target)
                .first(where: { $0.source == proposal.source }) else { return [] }
            return [GraphDiagnostic(
                code: .duplicateLink, message: "These ports are already linked.",
                node: proposal.target.node, port: proposal.target, link: existing.id)]
        }
    }

    /// The link must not create a cycle. Links leaving a feedback node
    /// (``NodeDefinition/isFeedback``) do not count, matching ``ExecutionPlan``: they carry the
    /// previous evaluation's value, so a loop through a feedback node is legal.
    public struct NoCycle: ConnectionRule {
        public let id = "noCycle"
        public let summary = "A link cannot create a cycle unless a feedback node breaks it."
        public init() {}

        public func check(_ proposal: ConnectionProposal, in context: ValidationContext) -> [GraphDiagnostic] {
            let start = proposal.target.node
            let goal = proposal.source.node
            // A self-link is NoSelfLink's concern.
            guard start != goal else { return [] }

            func isFeedback(_ node: NodeID) -> Bool { context.definition(of: node)?.isFeedback == true }
            guard !isFeedback(goal) else { return [] }

            // Walk downstream from the target; the link would close a loop if that reaches the source.
            var visited: Set<NodeID> = [start]
            var stack = [start]
            while let node = stack.popLast() {
                if isFeedback(node) { continue }
                for link in context.outgoingLinks(of: node) {
                    let next = link.target.node
                    if next == goal {
                        return [GraphDiagnostic(
                            code: .cycle, message: "This link would create a cycle.",
                            node: proposal.target.node, port: proposal.target)]
                    }
                    if visited.insert(next).inserted { stack.append(next) }
                }
            }
            return []
        }
    }
}
