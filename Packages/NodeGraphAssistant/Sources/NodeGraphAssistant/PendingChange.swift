import NodeGraphCore

/// What running a graph before and after a proposed change shows: values that changed and nodes
/// that started or stopped failing.
public struct RunComparison: Sendable {
    public struct Change: Sendable {
        public var node: NodeID
        public var port: PortID
        public var before: GraphValue?
        public var after: GraphValue?
    }

    public var changes: [Change]
    /// Nodes that fail after the change and did not before, with the error.
    public var newFailures: [NodeID: String]
    /// Nodes that failed before and no longer do (or are gone).
    public var resolvedFailures: [NodeID: String]

    public var isUnchanged: Bool { changes.isEmpty && newFailures.isEmpty && resolvedFailures.isEmpty }

    /// Compares two runs. `graph` is the one `after` ran, which orders the changes.
    public static func between(before: RunReport, after: RunReport, in graph: Graph) -> RunComparison {
        var changes: [Change] = []
        for id in graph.nodes.keys {
            let published = after.values[id]
            for port in published.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let was = before.values[id, port], now = published[port]
                if was != now { changes.append(Change(node: id, port: port, before: was, after: now)) }
            }
        }
        return RunComparison(
            changes: changes,
            newFailures: after.failures.filter { before.failures[$0.key] == nil },
            resolvedFailures: before.failures.filter { after.failures[$0.key] == nil })
    }

    /// Lines such as `n5.result: 12.0 -> 24.0`, at most `limit` of them.
    public func rendered(aliases: GraphDigest, limit: Int = 12) -> String {
        func alias(_ node: NodeID) -> String { aliases.alias(for: node) ?? "?" }
        func show(_ value: GraphValue?) -> String { value.map { GraphDigest.format($0, limit: 30) } ?? "none" }
        if isUnchanged { return "No value changed and no node started or stopped failing." }
        var lines = changes.prefix(limit).map {
            "\(alias($0.node)).\($0.port.rawValue): \(show($0.before)) -> \(show($0.after))"
        }
        if changes.count > limit { lines.append("(\(changes.count - limit) more changes)") }
        for (node, message) in newFailures.sorted(by: { alias($0.key) < alias($1.key) }) {
            lines.append("\(alias(node)) now fails: \(message)")
        }
        for (node, message) in resolvedFailures.sorted(by: { alias($0.key) < alias($1.key) }) {
            lines.append("\(alias(node)) no longer fails (it did: \(message))")
        }
        return lines.joined(separator: "\n")
    }
}

/// An edit the assistant proposes, for the person to preview and accept or reject.
///
/// Nothing has been applied. The command is one batch, so accepting it is a single undo step
/// (decision 211). Before showing it, the proposal was tried on a copy: ``errors`` are what could
/// not be done, and ``introducedDiagnostics`` and ``introducedFindings`` are the problems the
/// result has that the document did not.
public struct PendingChange: Sendable {
    public var title: String
    /// What the change does, one line per step, in order.
    public var steps: [String]
    public var command: GraphCommand
    /// What was asked for and could not be done. The rest of the change is still here.
    public var errors: [String]
    /// The nodes the change creates, so a preview can highlight and select them.
    public var addedNodes: [NodeID]
    /// Validation errors and warnings the result has and the document does not.
    public var introducedDiagnostics: [GraphDiagnostic]
    /// Lint findings the result has and the document does not.
    public var introducedFindings: [LintFinding]
    /// Lint findings the document has and the result does not.
    public var resolvedFindings: [LintFinding]
    /// The editor revision the proposal was made against.
    public var baseRevision: Int
    /// The document as it would be after the change, for previews and for running it.
    public var resultGraph: Graph
    public var resultSubgraphs: [SubgraphDefinition]
    /// Set by ``withRunComparison(in:variables:)``.
    public var runComparison: RunComparison?

    /// Whether there is nothing to apply.
    public var isEmpty: Bool { steps.isEmpty }

    /// Whether it is worth offering: it does something and adds no validation errors.
    public var canApply: Bool { !isEmpty && !introducedDiagnostics.containsErrors }

    /// Whether the editor has changed since the proposal was made, so it may no longer fit.
    public func isStale(for editor: GraphEditor) -> Bool { editor.revision != baseRevision }

    /// Applies the change to `editor` as one undoable step. Prefer the editor model's own apply so
    /// the history sees it; this is for headless use and tests.
    @discardableResult
    public func apply(to editor: GraphEditor) throws -> GraphChange {
        try editor.apply(command)
    }

    /// Runs the document and the result, and records what differs.
    public func withRunComparison(
        in workspace: AssistantWorkspace, variables: [String: GraphValue] = [:]
    ) async throws -> PendingChange {
        let before = try await workspace.run(variables: variables)
        let after = try await AssistantWorkspace.run(
            graph: resultGraph, subgraphs: resultSubgraphs, nodes: workspace.nodes, variables: variables)
        var copy = self
        copy.runComparison = .between(before: before, after: after, in: resultGraph)
        return copy
    }

    /// The proposal as text: title, steps, what could not be done, and what it changes.
    public func rendered(in workspace: AssistantWorkspace) -> String {
        var lines = [title]
        lines += steps.map { "- " + $0 }
        if !errors.isEmpty { lines.append("Could not do:") ; lines += errors.map { "- " + $0 } }
        if !introducedDiagnostics.isEmpty { lines.append("It would introduce:") ; lines += workspace.render(introducedDiagnostics).split(separator: "\n").map { "- " + $0 } }
        if !introducedFindings.isEmpty { lines.append("New lint findings:") ; lines += workspace.render(introducedFindings).split(separator: "\n").map { "- " + $0 } }
        if !resolvedFindings.isEmpty { lines.append("Resolves \(resolvedFindings.count) lint finding(s).") }
        if let runComparison {
            let result = GraphDigest(graph: resultGraph, registry: workspace.nodes, scope: .nodes([]))
            lines.append("Running it:")
            lines += runComparison.rendered(aliases: result).split(separator: "\n").map { "- " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

extension AssistantWorkspace {
    /// What identifies a finding across two versions of a document.
    private struct FindingKey: Hashable {
        var lint: String
        var node: NodeID?
        var port: PortAddress?
        var message: String

        init(_ finding: LintFinding) {
            lint = finding.lint
            node = finding.diagnostic.node
            port = finding.diagnostic.port
            message = finding.diagnostic.message
        }
    }

    /// Builds the proposal for `commands`, which `scratch` (a copy of the document) has already had
    /// applied. Compares the result with the document, so reviewers see only what is new.
    func pendingChange(
        title: String, steps: [String], commands: [GraphCommand], errors: [String], added: [NodeID],
        scratch: GraphEditor
    ) -> PendingChange {
        let beforeDiagnostics = Set(diagnostics())
        let afterDiagnostics = GraphValidator(connections: connectionValidator).validate(scratch.validationContext)
        let beforeFindings = lint()
        let afterFindings = linter.run(in: LintContext(editor: scratch))
        let beforeKeys = Set(beforeFindings.map(FindingKey.init)), afterKeys = Set(afterFindings.map(FindingKey.init))
        return PendingChange(
            title: title, steps: steps,
            command: commands.count == 1 ? commands[0] : .batch(commands: commands),
            errors: errors, addedNodes: added,
            introducedDiagnostics: afterDiagnostics.filter { !beforeDiagnostics.contains($0) },
            introducedFindings: afterFindings.filter { !beforeKeys.contains(FindingKey($0)) },
            resolvedFindings: beforeFindings.filter { !afterKeys.contains(FindingKey($0)) },
            baseRevision: revision, resultGraph: scratch.graph,
            resultSubgraphs: Array(scratch.subgraphs.values))
    }
}
