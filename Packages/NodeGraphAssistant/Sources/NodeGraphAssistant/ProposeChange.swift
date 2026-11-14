import NodeGraphCore

extension AssistantWorkspace {
    /// A short text of the current graph for a model to read, and which nodes are selected, so a
    /// request like "connect a log to the append node" or "this node" can be understood (decision 237).
    ///
    /// The whole graph if it fits in `tokenBudget`; otherwise the selection and what is next to it.
    /// Names are the digest's `n1`, `n2`, ..., the same ones ``proposeChange(adding:connecting:edits:title:)``
    /// takes. Empty for an empty graph.
    public func currentGraphText(tokenBudget: Int) -> String {
        guard !graph.nodes.isEmpty else { return "" }
        let live = selection.filter { graph.nodes[$0] != nil }
        var digest = GraphDigest.fitting(tokenBudget: tokenBudget, graph: graph, registry: nodes, scope: .all)
        if digest.omittedNodeCount > 0, !live.isEmpty {
            digest = GraphDigest.fitting(tokenBudget: tokenBudget, graph: graph, registry: nodes, scope: .neighborhood(of: live, depth: 1))
        }
        var text = digest.text
        let chosen = live.compactMap { aliases.alias(for: $0) }
            .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
        if !chosen.isEmpty { text += "\nSelected: " + chosen.joined(separator: ", ") }
        return text
    }

    /// Proposes one change that may add new nodes, link them to nodes already in the graph, link or
    /// unlink existing nodes, and edit existing nodes, so "connect a log to the append node" is one
    /// proposal. Nothing is applied (decision 211).
    ///
    /// - Parameters:
    ///   - spec: The new nodes, and the links among them only. Their aliases must not look like the
    ///     digest's `n1`, `n2`, ...
    ///   - links: Links with at least one end on a node already in the graph. Each end is
    ///     `alias.port`, where the alias is a new node's or an existing node's digest name.
    ///   - edits: Edits of existing nodes, by their digest names.
    ///
    /// Whatever cannot be done is named in ``PendingChange/errors`` and the rest still goes ahead.
    /// New nodes that are linked to existing ones are placed to the right of those.
    public func proposeChange(
        adding spec: GraphSpec = GraphSpec(nodes: [], links: []), connecting links: [GraphSpec.LinkSpec] = [],
        edits: [EditOperation] = [], title: String = "Change the graph"
    ) -> PendingChange {
        let scratch = scratchEditor()
        var commands: [GraphCommand] = []
        var steps: [String] = []
        var errors: [String] = []
        var added: [NodeID] = []
        var newIDs: [String: NodeID] = [:]

        if !spec.nodes.isEmpty {
            let result = GraphSpecCompiler(nodes: nodes, types: types, connectionValidator: connectionValidator).compile(spec)
            errors += result.errors.map(\.message)
            if !result.fragment.isEmpty {
                do {
                    let paste = try scratch.pasteCommand(result.fragment, translatedBy: origin(for: links, avoiding: Set(spec.nodes.map(\.alias))))
                    try scratch.apply(paste.command)
                    commands.append(paste.command)
                    added = paste.nodes
                    // Pasting reports the new ids in the order of the fragment's nodes.
                    for (alias, fragmentID) in result.aliases {
                        if let index = result.fragment.nodes.firstIndex(where: { $0.id == fragmentID }), index < paste.nodes.count {
                            newIDs[alias] = paste.nodes[index]
                        }
                    }
                    let digest = GraphDigest(graph: scratch.graph, registry: nodes, scope: .nodes(Set(added)), detail: .compact)
                    var section = ""
                    for line in digest.text.split(separator: "\n").map(String.init) {
                        if line.hasSuffix(":") { section = line; continue }
                        steps.append((section == "nodes:" ? "Add " : "Link ") + line)
                    }
                } catch {
                    errors.append("The new nodes could not be added: \(error)")
                }
            }
        }

        for link in links {
            do {
                let source = try endpoint(link.from, direction: .output, newIDs: newIDs, newAliases: Set(spec.nodes.map(\.alias)))
                let target = try endpoint(link.to, direction: .input, newIDs: newIDs, newAliases: Set(spec.nodes.map(\.alias)))
                let replaced = scratch.graph.links(into: target).first
                let command: GraphCommand
                do {
                    command = try scratch.connectCommand(for: ConnectionProposal(source: source, target: target))
                } catch GraphEditError.invalidConnection(let diagnostics) {
                    throw AssistantToolError(
                        "\(link.from) -> \(link.to) is not allowed: "
                            + diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "; "))
                }
                try scratch.apply(command)
                commands.append(command)
                let note = replaced.map { " (replaces the link from \(name($0.source.node)).\($0.source.port.rawValue))" } ?? ""
                steps.append("Link \(link.from) -> \(link.to)\(note)")
            } catch let error as AssistantToolError {
                errors.append(error.message)
            } catch {
                errors.append("\(link.from) -> \(link.to): \(error)")
            }
        }

        for (index, operation) in edits.enumerated() {
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
        return pendingChange(title: title, steps: steps, commands: commands, errors: errors, added: added, scratch: scratch)
    }

    /// The port a link end names: a node added by this change, or one already in the graph. The editor's
    /// own connection check then says whether the port exists and fits.
    private func endpoint(
        _ reference: String, direction: PortDirection, newIDs: [String: NodeID], newAliases: Set<String>
    ) throws -> PortAddress {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw AssistantToolError("\"\(reference)\" is not a port reference. Write node.port, such as n3.result.")
        }
        if let id = newIDs[parts[0]] { return PortAddress(node: id, port: PortID(parts[1]), direction: direction) }
        if newAliases.contains(parts[0]) {
            throw AssistantToolError("The new node \"\(parts[0])\" could not be added, so \(reference) cannot be linked.")
        }
        let existing: Node
        do { existing = try node(parts[0]) } catch let error as AssistantToolError {
            let fresh = newAliases.sorted().joined(separator: ", ")
            throw AssistantToolError(error.message + (fresh.isEmpty ? "" : " New nodes: \(fresh)."))
        }
        return PortAddress(node: existing.id, port: PortID(parts[1]), direction: direction)
    }

    /// To the right of the existing nodes the links reach, level with their top; else beside the graph.
    private func origin(for links: [GraphSpec.LinkSpec], avoiding newAliases: Set<String>) -> GraphPoint {
        var frames: [GraphRect] = []
        for link in links {
            for end in [link.from, link.to] {
                guard let alias = end.split(separator: ".").first.map(String.init), !newAliases.contains(alias),
                      let node = try? node(alias) else { continue }
                frames.append(nodes.frame(of: node))
            }
        }
        guard let right = frames.map(\.maxX).max(), let top = frames.map(\.minY).min() else { return defaultOrigin() }
        return GraphPoint(x: right + 120, y: top)
    }
}
