import NodeGraphCore

/// How a value came to be: a port's value from the last run, and for each input of the node that
/// made it, the value that arrived and where it came from, back to the nodes that read nothing.
///
/// Built by ``ValueTracer``. This is the facts behind "why is this 0?": the assistant reads the
/// rendered text and explains it, instead of guessing from the graph.
public struct ValueTrace: Hashable, Sendable {
    /// One output port of one node and what produced it.
    public struct Step: Hashable, Sendable {
        public var node: NodeID
        public var typeID: NodeTypeID
        public var title: String?
        public var port: PortID
        /// What the node published at `port` in the last run, or nil if it published nothing.
        public var value: GraphValue?
        /// Why `value` is missing or may not follow from the inputs, such as a muted node.
        public var note: String?
        /// The node's properties that differ from their defaults, in the definition's order.
        public var properties: [Property]
        /// The data inputs, in port order.
        public var inputs: [Input]
    }

    public struct Property: Hashable, Sendable {
        public var id: PropertyID
        public var value: GraphValue
    }

    public struct Input: Hashable, Sendable {
        public var port: PortID
        public var origin: Origin
    }

    /// Where an input's value came from.
    public indirect enum Origin: Hashable, Sendable {
        /// A link from another node's output, traced further.
        case linked(Step)
        /// Not linked, so the port's default applies (nil when it has none).
        case unlinked(defaultValue: GraphValue?)
        /// A link whose source was not expanded because the trace hit its depth or size limit.
        case cutOff(node: NodeID, port: PortID, value: GraphValue?)
        /// A link from a node already shown on this path, which is a feedback loop.
        case loop(node: NodeID, port: PortID, value: GraphValue?)
    }

    public var root: Step
    /// Whether any part of the trace was cut off by a limit.
    public var isTruncated: Bool

    /// The trace as indented text, with the aliases of `digest` so it matches what the model has
    /// seen of the graph:
    /// ```
    /// n4.result = 12.0  math.add
    ///   a <- n2.value = 4.0  util.number value=4.0
    ///   b <- default 0.0
    /// ```
    public func rendered(aliases digest: GraphDigest, valueLimit: Int = 40) -> String {
        var lines: [String] = []
        func alias(_ node: NodeID) -> String { digest.alias(for: node) ?? "?" }
        func show(_ value: GraphValue?) -> String { value.map { GraphDigest.format($0, limit: valueLimit) } ?? "no value" }
        func describe(_ step: Step) -> String {
            var text = "\(alias(step.node)).\(step.port.rawValue) = \(show(step.value))  \(step.typeID.rawValue)"
            if let title = step.title, !title.isEmpty { text += " \"\(title)\"" }
            for property in step.properties {
                text += " \(property.id.rawValue)=\(GraphDigest.format(property.value, limit: valueLimit))"
            }
            if let note = step.note { text += " [\(note)]" }
            return text
        }
        func walk(_ step: Step, prefix: String, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + prefix + describe(step))
            for input in step.inputs {
                let label = input.port.rawValue + " <- "
                switch input.origin {
                case .linked(let source): walk(source, prefix: label, depth: depth + 1)
                case .unlinked(let value):
                    lines.append(indent + "  " + label + (value.map { "default \(show($0))" } ?? "nothing (no link, no default)"))
                case .cutOff(let node, let port, let value):
                    lines.append(indent + "  " + label + "\(alias(node)).\(port.rawValue) = \(show(value)) (not expanded)")
                case .loop(let node, let port, let value):
                    lines.append(indent + "  " + label + "\(alias(node)).\(port.rawValue) = \(show(value)) (loop back)")
                }
            }
        }
        walk(root, prefix: "", depth: 0)
        if isTruncated { lines.append("(trace cut off; ask for a deeper trace from a node above)") }
        return lines.joined(separator: "\n")
    }
}

/// Follows a value back through the graph using what the last run published.
///
/// It reads a ``RunValues``, so it never runs anything. Only the root graph is covered, as in
/// `RunValues`: a subgraph instance appears as one node with its inputs and outputs.
public struct ValueTracer: Sendable {
    public var graph: Graph
    public var registry: NodeRegistry
    public var values: RunValues

    public init(graph: Graph, registry: NodeRegistry, values: RunValues) {
        self.graph = graph
        self.registry = registry
        self.values = values
    }

    /// Traces the value at `port`: an output port (what that node published) or an input port (the
    /// output that feeds it, or its default). Returns nil if the node or port does not exist.
    ///
    /// - Parameters:
    ///   - maxDepth: How many links to follow back from the start.
    ///   - maxNodes: How many steps to expand in all, so a wide graph cannot flood a prompt.
    public func trace(_ port: PortAddress, maxDepth: Int = 8, maxNodes: Int = 40) -> ValueTrace? {
        guard graph.nodes[port.node] != nil else { return nil }
        var budget = maxNodes
        var truncated = false
        var path: [NodeID] = []

        func step(node id: NodeID, port: PortID, depth: Int) -> ValueTrace.Step? {
            guard let node = graph.nodes[id], let definition = registry.definition(for: node) else { return nil }
            budget -= 1
            path.append(id)
            defer { path.removeLast() }

            var inputs: [ValueTrace.Input] = []
            for input in definition.inputs where input.kind == .data {
                let address = PortAddress(node: id, port: input.id, direction: .input)
                guard let link = graph.links(into: address).first else {
                    inputs.append(.init(port: input.id, origin: .unlinked(defaultValue: input.defaultValue)))
                    continue
                }
                let value = values[link.source.node, link.source.port]
                if path.contains(link.source.node) {
                    inputs.append(.init(port: input.id, origin: .loop(node: link.source.node, port: link.source.port, value: value)))
                } else if depth >= maxDepth || budget <= 0 {
                    truncated = true
                    inputs.append(.init(port: input.id, origin: .cutOff(node: link.source.node, port: link.source.port, value: value)))
                } else if let source = step(node: link.source.node, port: link.source.port, depth: depth + 1) {
                    inputs.append(.init(port: input.id, origin: .linked(source)))
                }
            }

            let published = values[id, port]
            return ValueTrace.Step(
                node: id, typeID: node.typeID, title: node.title, port: port, value: published,
                note: Self.note(for: node, published: published),
                properties: definition.properties.compactMap { property in
                    guard let value = node.properties[property.id], value != property.defaultValue else { return nil }
                    return ValueTrace.Property(id: property.id, value: value)
                },
                inputs: inputs)
        }

        switch port.direction {
        case .output:
            guard let root = step(node: port.node, port: port.port, depth: 0) else { return nil }
            return ValueTrace(root: root, isTruncated: truncated)
        case .input:
            // Trace the output that feeds it; with no link there is nothing to explain but the default.
            guard let link = graph.links(into: port).first,
                  let root = step(node: link.source.node, port: link.source.port, depth: 0) else { return nil }
            return ValueTrace(root: root, isTruncated: truncated)
        }
    }

    private static func note(for node: Node, published: GraphValue?) -> String? {
        switch node.mode {
        case .never: return "disabled: did not run"
        case .muted: return "muted: publishes nothing"
        case .bypassed: return "bypassed: passes an input through, not computed"
        case .onTrigger: return published == nil ? "runs only on a trigger; has not run" : "runs only on a trigger; this is its last value"
        case .always: return published == nil ? "no value from the last run: not reached, failed or skipped" : nil
        }
    }
}
