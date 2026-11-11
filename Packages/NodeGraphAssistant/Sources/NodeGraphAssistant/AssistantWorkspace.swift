import NodeGraphCore

/// A problem with a tool call, worded so a model can fix its next call.
public struct AssistantToolError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }

    public init(_ message: String) { self.message = message }
}

/// What the run tools produce: the values every node published and the nodes that failed.
public struct RunReport: Sendable {
    public var values: RunValues
    /// The message of each node that threw an error.
    public var failures: [NodeID: String]
}

/// A frozen view of the document the assistant is working on, and the tools that read it.
///
/// Everything here is a plain function of the snapshot. Read tools return facts, run tools
/// evaluate a copy, and propose tools return a ``PendingChange`` rather than editing anything
/// (decision 211). Nodes are named by the aliases of ``aliases`` (`n3`, and `n3.out` for a port),
/// the same ones ``GraphDigest`` prints, so what a model reads and what it asks for line up.
///
/// A snapshot goes stale when the document changes. Make a new one after each edit.
public struct AssistantWorkspace: Sendable {
    public var graph: Graph
    public var subgraphs: [SubgraphDefinition]
    public var nodes: NodeRegistry
    public var types: TypeRegistry
    public var connectionValidator: ConnectionValidator
    public var linter: GraphLinter
    /// What the last run published, empty if the graph has not run.
    public var runValues: RunValues
    public var selection: Set<NodeID>
    /// The editor's revision when the snapshot was taken, for spotting a stale proposal.
    public var revision: Int
    /// The alias of every node in the graph.
    public let aliases: GraphDigest

    public init(
        editor: GraphEditor, runValues: RunValues = RunValues(), selection: Set<NodeID> = [],
        linter: GraphLinter = GraphLinter()
    ) {
        graph = editor.graph
        subgraphs = Array(editor.subgraphs.values)
        nodes = editor.nodes
        types = editor.types
        connectionValidator = editor.connectionValidator
        self.linter = linter
        self.runValues = runValues
        self.selection = selection
        revision = editor.revision
        aliases = GraphDigest(graph: editor.graph, registry: editor.nodes, scope: .nodes([]))
    }

    /// A private editor holding a copy of the document, to try edits on.
    func scratchEditor() -> GraphEditor {
        GraphEditor(
            graph: graph, subgraphs: subgraphs, revision: revision, nodes: nodes, types: types,
            connectionValidator: connectionValidator)
    }

    // MARK: Names

    /// The node an alias names.
    public func node(_ alias: String) throws -> Node {
        guard let id = aliases.node(for: alias), let node = graph.nodes[id] else {
            throw AssistantToolError(
                graph.nodes.isEmpty
                    ? "No node \"\(alias)\": the graph is empty."
                    : "No node \"\(alias)\". Nodes are n1 to n\(graph.nodes.count).")
        }
        return node
    }

    /// The port a reference like `n3.out` names. With no `direction`, an output is preferred when
    /// the node has an output and an input of that name.
    public func port(_ reference: String, direction: PortDirection? = nil) throws -> PortAddress {
        guard let dot = reference.firstIndex(of: "."), dot != reference.startIndex,
              reference.index(after: dot) != reference.endIndex else {
            throw AssistantToolError("\"\(reference)\" is not a port reference. Write node.port, such as n3.out.")
        }
        let node = try node(String(reference[..<dot]))
        let id = PortID(String(reference[reference.index(after: dot)...]))
        guard let definition = nodes.definition(for: node) else {
            throw AssistantToolError("Node \(reference) has the unregistered type \(node.typeID.rawValue).")
        }
        let tried = direction.map { [$0] } ?? [.output, .input]
        if let found = tried.first(where: { definition.port(id, direction: $0) != nil }) {
            return PortAddress(node: node.id, port: id, direction: found)
        }
        func list(_ direction: PortDirection?) -> String {
            definition.ports.filter { direction == nil || $0.direction == direction }
                .map { "\($0.id.rawValue) (\($0.direction.rawValue))" }.joined(separator: ", ")
        }
        let name = "\(aliases.alias(for: node.id) ?? "?") (\(node.typeID.rawValue))"
        let valid = list(direction)
        if valid.isEmpty, let direction {
            // Name what it does have, so "no inputs" is not read as "no ports".
            let all = list(nil)
            throw AssistantToolError(
                "\(name) has no \(direction.rawValue) ports.\(all.isEmpty ? "" : " Its ports: \(all).")")
        }
        throw AssistantToolError("\(name) has no port \"\(id.rawValue)\". Ports: \(valid).")
    }

    func name(_ node: NodeID) -> String { aliases.alias(for: node) ?? "?" }

    // MARK: Read: the node library

    /// A node type, in short.
    public struct NodeSummary: Hashable, Sendable {
        public var typeID: NodeTypeID
        public var displayName: String
        public var category: String
        public var help: String
        public var inputs: [String]
        public var outputs: [String]

        /// One line: `math.add (Add, Math): Adds two numbers. in: a number, b number; out: result number`.
        public var rendered: String {
            var text = "\(typeID.rawValue) (\(displayName)\(category.isEmpty ? "" : ", \(category)"))"
            if !help.isEmpty { text += ": \(help)" }
            text += " in: \(inputs.isEmpty ? "none" : inputs.joined(separator: ", ")); out: \(outputs.isEmpty ? "none" : outputs.joined(separator: ", "))"
            return text
        }
    }

    private func summary(of definition: NodeDefinition) -> NodeSummary {
        func label(_ port: PortDefinition) -> String { "\(port.id.rawValue) \(port.type.rawValue)" }
        func label(_ group: DynamicPortGroup) -> String { "\(group.id)_1... \(group.type.rawValue)" }
        return NodeSummary(
            typeID: definition.typeID, displayName: definition.displayName, category: definition.category,
            help: definition.help ?? "",
            inputs: definition.inputs.filter { $0.group == nil }.map(label) + definition.dynamicPorts.filter { $0.direction == .input }.map(label),
            outputs: definition.outputs.filter { $0.group == nil }.map(label) + definition.dynamicPorts.filter { $0.direction == .output }.map(label))
    }

    /// Node types matching `query`, best first. Words are matched against the type id, the name,
    /// the category and the help text, so "smooth a signal" finds a filter.
    public func searchNodes(_ query: String, category: String? = nil, limit: Int = 8) -> [NodeSummary] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var scored: [(score: Int, order: Int, definition: NodeDefinition)] = []
        for (order, definition) in nodes.registeredDefinitions.enumerated() {
            if let category, definition.category.caseInsensitiveCompare(category) != .orderedSame { continue }
            guard !definition.typeID.rawValue.hasPrefix("subgraph.") else { continue }
            let id = definition.typeID.rawValue.lowercased(), name = definition.displayName.lowercased()
            let group = definition.category.lowercased(), help = (definition.help ?? "").lowercased()
            let score = words.reduce(0) { total, word in
                total + (id.contains(word) ? 5 : 0) + (name.contains(word) ? 4 : 0)
                    + (group.contains(word) ? 2 : 0) + (help.contains(word) ? 1 : 0)
            }
            if score > 0 || words.isEmpty { scored.append((score, order, definition)) }
        }
        scored.sort { ($1.score, $0.order) < ($0.score, $1.order) }
        return scored.prefix(max(limit, 0)).map { summary(of: $0.definition) }
    }

    /// Everything about one node type: ports with their types and defaults, dynamic port groups,
    /// and properties with their kinds and defaults. Nil if the type is not registered.
    public func describeNode(type: String) -> String? {
        guard let definition = nodes.definition(for: NodeTypeID(type)) else { return nil }
        var lines = ["\(definition.typeID.rawValue) (\(definition.displayName))"]
        if let help = definition.help, !help.isEmpty { lines.append(help) }
        for port in definition.ports where port.group == nil {
            var line = "\(port.direction.rawValue) \(port.id.rawValue): \(port.kind == .trigger ? "trigger" : port.type.rawValue)"
            if let value = port.defaultValue { line += ", default \(GraphDigest.format(value, limit: 30))" }
            if port.direction == .input && port.defaultValue == nil && port.kind == .data { line += ", no default" }
            if port.allowsMultipleLinks && port.direction == .input { line += ", takes several links" }
            lines.append(line)
        }
        for group in definition.dynamicPorts {
            let limit = group.maximum.map { "\(group.minimum)...\($0)" } ?? "at least \(group.minimum)"
            lines.append("\(group.direction.rawValue) ports \(group.id)_1, \(group.id)_2, ...: \(group.type.rawValue), \(limit) of them, \(group.initialCount) at first")
        }
        for property in definition.properties {
            lines.append("property \(property.id.rawValue): \(Self.describe(property.kind)), default \(GraphDigest.format(property.defaultValue, limit: 30))")
        }
        if definition.isPure { lines.append("pure: the same inputs and properties always give the same outputs") }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ kind: PropertyKind) -> String {
        func range<T>(_ low: T?, _ high: T?) -> String {
            switch (low, high) {
            case (let low?, let high?): " from \(low) to \(high)"
            case (let low?, nil): " at least \(low)"
            case (nil, let high?): " at most \(high)"
            default: ""
            }
        }
        switch kind {
        case .bool: return "true or false"
        case .int(let low, let high, _): return "whole number" + range(low, high)
        case .double(let low, let high, _): return "number" + range(low, high)
        case .string: return "text"
        case .choice(let choices): return "one of " + choices.map(\.value).joined(separator: ", ")
        case .variable: return "the name of a graph variable"
        case .color: return "color"
        case .vector(let dimension): return "vector of \(dimension) numbers"
        case .custom(let name): return name
        }
    }

    // MARK: Read: the document

    /// The digest of the given nodes and everything within `depth` links of them, in at most
    /// `tokenBudget` estimated tokens. An empty `aliases` means the selection, or the whole graph
    /// when nothing is selected.
    public func digest(around aliases: [String] = [], depth: Int = 1, tokenBudget: Int = 1500) throws -> GraphDigest {
        var seeds = Set(try aliases.map { try node($0).id })
        let scope: GraphDigest.Scope
        if seeds.isEmpty { seeds = selection.filter { graph.nodes[$0] != nil } }
        scope = seeds.isEmpty ? .all : .neighborhood(of: seeds, depth: depth)
        return GraphDigest.fitting(tokenBudget: tokenBudget, graph: graph, registry: nodes, scope: scope)
    }

    /// The problems Core's validator finds: invalid links, property values and cycles.
    public func diagnostics() -> [GraphDiagnostic] {
        GraphValidator(connections: connectionValidator).validate(scratchEditor().validationContext)
    }

    /// The lint findings for the document.
    public func lint() -> [LintFinding] {
        linter.run(in: LintContext(editor: scratchEditor()))
    }

    /// Findings as text, one per line: `[problem] n3: message (fix: description)`.
    public func render(_ findings: [LintFinding]) -> String {
        findings.map { finding in
            var line = "[\(finding.level.rawValue)] "
            if let node = finding.diagnostic.node { line += name(node) + ": " }
            line += finding.diagnostic.message
            if let fix = finding.fix { line += " (fix: \(fix.description))" }
            return line
        }.joined(separator: "\n")
    }

    /// Diagnostics as text, one per line: `[error] n3: message`.
    public func render(_ diagnostics: [GraphDiagnostic]) -> String {
        diagnostics.map { diagnostic in
            "[\(diagnostic.severity.rawValue)] " + (diagnostic.node.map { name($0) + ": " } ?? "") + diagnostic.message
        }.joined(separator: "\n")
    }

    // MARK: Read: the last run

    /// The value the last run published at a port, such as `n3.out`; nil if it published none.
    public func value(of reference: String) throws -> GraphValue? {
        let address = try port(reference)
        guard address.direction == .output else {
            throw AssistantToolError("\(reference) is an input. Ask for the output that feeds it, or use traceUpstream.")
        }
        return runValues[address.node, address.port]
    }

    /// How the value at a port came to be, back through the nodes that made it.
    public func traceUpstream(_ reference: String, maxDepth: Int = 8, maxNodes: Int = 40) throws -> ValueTrace {
        let address = try port(reference)
        let tracer = ValueTracer(graph: graph, registry: nodes, values: runValues)
        guard let trace = tracer.trace(address, maxDepth: maxDepth, maxNodes: maxNodes) else {
            throw AssistantToolError("\(reference) is an input with nothing linked to it, so there is nothing to trace.")
        }
        return trace
    }

    // MARK: Run

    /// Runs the graph once on a copy and reports what every node published. `variables` replace
    /// declared graph variables for this run only.
    public func run(variables: [String: GraphValue] = [:]) async throws -> RunReport {
        try await Self.run(graph: graph, subgraphs: subgraphs, nodes: nodes, variables: variables)
    }

    static func run(
        graph: Graph, subgraphs: [SubgraphDefinition], nodes: NodeRegistry, variables: [String: GraphValue] = [:]
    ) async throws -> RunReport {
        let runner: GraphRunner
        do {
            runner = try GraphRunner(graph: graph, registry: nodes, subgraphs: subgraphs, variables: variables)
        } catch let error as VariableOverrideError {
            throw AssistantToolError("Cannot set the variable: \(error)")
        } catch {
            throw AssistantToolError("The graph cannot run: \(error)")
        }
        let tick = await runner.step()
        var values = RunValues()
        values.apply(tick)
        var failures: [NodeID: String] = [:]
        for result in tick.results.values {
            if case .failure(let failure) = result.outcome { failures[result.node] = failure.message }
        }
        return RunReport(values: values, failures: failures)
    }
}
