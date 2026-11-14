import NodeGraphCore

/// The propose tools. None of them changes the document; each returns a ``PendingChange``.
extension AssistantWorkspace {
    // MARK: Generation

    /// Proposes adding the graph `spec` describes. It goes to the right of the existing nodes
    /// unless `origin` says where its top-left corner should be.
    public func proposeGeneration(
        _ spec: GraphSpec, at origin: GraphPoint? = nil, title: String = "Add generated nodes"
    ) -> PendingChange {
        let result = GraphSpecCompiler(nodes: nodes, types: types, connectionValidator: connectionValidator).compile(spec)
        let scratch = scratchEditor()
        var errors = result.errors.map(\.message)
        var command: GraphCommand?
        var added: [NodeID] = []

        if !result.fragment.isEmpty {
            let place = origin ?? defaultOrigin()
            do {
                let paste = try scratch.pasteCommand(result.fragment, translatedBy: place)
                try scratch.apply(paste.command)
                command = paste.command
                added = paste.nodes
            } catch {
                errors.append("The generated graph could not be added: \(error)")
            }
        }

        var steps: [String] = []
        if command != nil {
            let digest = GraphDigest(graph: scratch.graph, registry: nodes, scope: .nodes(Set(added)), detail: .compact)
            var section = ""
            for line in digest.text.split(separator: "\n").map(String.init) {
                if line.hasSuffix(":") { section = line; continue }
                steps.append((section == "nodes:" ? "Add " : "Link ") + line)
            }
            steps += result.fragment.groups.map { "Group \"\($0.title)\"" }
        }
        return pendingChange(
            title: title, steps: steps, commands: command.map { [$0] } ?? [], errors: errors, added: added, scratch: scratch)
    }

    /// Right of everything already placed, level with its top; the origin for an empty graph.
    func defaultOrigin() -> GraphPoint {
        let frames = graph.nodes.values.map(nodes.frame(of:))
        guard let first = frames.first else { return .zero }
        let right = frames.map(\.maxX).max() ?? first.maxX, top = frames.map(\.minY).min() ?? first.minY
        return GraphPoint(x: right + 120, y: top)
    }

    // MARK: Edits

    /// Proposes the edits in `operations`, in order. An operation that cannot be done is left out
    /// and named in ``PendingChange/errors``; the others still go ahead.
    public func proposeEdit(_ operations: [EditOperation], title: String = "Edit nodes") -> PendingChange {
        let scratch = scratchEditor()
        var commands: [GraphCommand] = []
        var steps: [String] = []
        var errors: [String] = []

        for (index, operation) in operations.enumerated() {
            do {
                let (command, step) = try compile(operation, on: scratch)
                try scratch.apply(command)
                commands.append(command)
                steps.append(step)
            } catch let error as AssistantToolError {
                errors.append("Edit \(index + 1) (\(operation.op.rawValue)): \(error.message)")
            } catch {
                errors.append("Edit \(index + 1) (\(operation.op.rawValue)): \(error)")
            }
        }
        return pendingChange(title: title, steps: steps, commands: commands, errors: errors, added: [], scratch: scratch)
    }

    private func required(_ value: String?, _ field: String, _ operation: EditOperation) throws -> String {
        guard let value, !value.isEmpty else { throw AssistantToolError("\(operation.op.rawValue) needs \"\(field)\".") }
        return value
    }

    func compile(_ operation: EditOperation, on scratch: GraphEditor) throws -> (GraphCommand, String) {
        switch operation.op {
        case .setProperty:
            let alias = try required(operation.node, "node", operation)
            let node = try node(alias)
            let name = try required(operation.property, "property", operation)
            guard let definition = nodes.definition(for: node), let property = definition.property(PropertyID(name)) else {
                let valid = nodes.definition(for: node)?.properties.map(\.id.rawValue).joined(separator: ", ") ?? ""
                throw AssistantToolError("\(alias) (\(node.typeID.rawValue)) has no property \"\(name)\"."
                    + (valid.isEmpty ? " It has no properties." : " Properties: \(valid)."))
            }
            guard let raw = operation.value, raw != .null else {
                return (.setNodeProperty(node: node.id, property: property.id, value: nil),
                        "Reset \(alias).\(name) to its default")
            }
            let value = GraphSpecCompiler.coerced(GraphValue(json: raw), for: property)
            do { try property.validate(value) } catch {
                throw AssistantToolError("\(alias).\(name) cannot be \(GraphDigest.format(value, limit: 30)): \(error).")
            }
            // GraphValue is ExpressibleByNilLiteral, so spell out the optional or `nil` would become `.null`.
            let override: GraphValue? = value == property.defaultValue ? Optional<GraphValue>.none : value
            return (.setNodeProperty(node: node.id, property: property.id, value: override),
                    "Set \(alias).\(name) = \(GraphDigest.format(value, limit: 40))")

        case .setTitle:
            let alias = try required(operation.node, "node", operation)
            let node = try node(alias)
            var title: String?
            if case .string(let text)? = operation.value, !text.trimmingCharacters(in: .whitespaces).isEmpty { title = text }
            return (.setNodeAttribute(node: node.id, attribute: .title(value: title)),
                    title.map { "Rename \(alias) to \"\($0)\"" } ?? "Clear the title of \(alias)")

        case .setMode:
            let alias = try required(operation.node, "node", operation)
            let node = try node(alias)
            guard case .string(let text)? = operation.value, let mode = NodeMode(rawValue: text) else {
                let valid = NodeMode.allCases.map(\.rawValue).joined(separator: ", ")
                throw AssistantToolError("setMode needs \"value\" to be one of \(valid).")
            }
            return (.setNodeAttribute(node: node.id, attribute: .mode(value: mode)), "Set \(alias) to \(mode.rawValue)")

        case .connect:
            let from = try required(operation.from, "from", operation), to = try required(operation.to, "to", operation)
            let source = try port(from, direction: .output), target = try port(to, direction: .input)
            let replaced = scratch.graph.links(into: target).first
            let command: GraphCommand
            do {
                command = try scratch.connectCommand(for: ConnectionProposal(source: source, target: target))
            } catch GraphEditError.invalidConnection(let diagnostics) {
                throw AssistantToolError(
                    "\(from) -> \(to) is not allowed: " + diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "; "))
            }
            let note = replaced.map { " (replaces the link from \(name($0.source.node)).\($0.source.port.rawValue))" } ?? ""
            return (command, "Link \(from) -> \(to)\(note)")

        case .disconnect:
            let from = try required(operation.from, "from", operation), to = try required(operation.to, "to", operation)
            let source = try port(from, direction: .output), target = try port(to, direction: .input)
            guard let link = scratch.graph.links(from: source).first(where: { $0.target == target }) else {
                throw AssistantToolError("There is no link from \(from) to \(to).")
            }
            return (.removeLink(id: link.id), "Remove the link \(from) -> \(to)")

        case .removeNode:
            let alias = try required(operation.node, "node", operation)
            let node = try node(alias)
            let count = scratch.graph.links(attachedTo: node.id).count
            return (.removeNode(id: node.id), "Remove \(alias) (\(node.typeID.rawValue))" + (count > 0 ? " and \(count) link(s)" : ""))
        }
    }

    // MARK: Lint fixes

    /// Proposes the fixes of `findings`, as one change. Findings with no fix are skipped.
    public func proposeFixes(_ findings: [LintFinding], title: String? = nil) -> PendingChange {
        let scratch = scratchEditor()
        var commands: [GraphCommand] = []
        var steps: [String] = []
        var errors: [String] = []
        for finding in findings {
            guard let fix = finding.fix else { continue }
            let subject = finding.diagnostic.node.map { name($0) } ?? finding.lint
            do {
                try scratch.apply(fix.command)
                commands.append(fix.command)
                steps.append("\(fix.description): \(subject)")
            } catch {
                errors.append("\(fix.description) (\(subject)): \(error)")
            }
        }
        let heading = title ?? (steps.count == 1 ? steps[0] : "Apply \(steps.count) lint fixes")
        return pendingChange(title: heading, steps: steps, commands: commands, errors: errors, added: [], scratch: scratch)
    }

    /// Proposes the fix of one finding, or nil if it has none.
    public func proposeFix(_ finding: LintFinding) -> PendingChange? {
        finding.fix == nil ? nil : proposeFixes([finding])
    }
}

extension GraphValue {
    /// The value for plain JSON, as a model writes it: numbers stay ints when they are whole.
    init(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .array(let items): self = .array(items.map(GraphValue.init(json:)))
        case .object(let fields): self = .object(fields.mapValues(GraphValue.init(json:)))
        }
    }
}
