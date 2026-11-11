import NodeGraphCore

/// One thing wrong with a ``GraphSpec``. The message names the alias or link and says what would
/// have been valid, so it can go back to a model as it is.
public struct SpecError: Hashable, Sendable, Error, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        case duplicateAlias, invalidAlias, unknownNodeType, unknownProperty, invalidProperty
        case unknownPortGroup, malformedEndpoint, unknownAlias, unknownPort, linkRejected, emptyGroup
    }

    public var kind: Kind
    public var message: String
    public var description: String { message }
}

/// Turns a ``GraphSpec`` into a ``GraphFragment`` the editor can paste.
///
/// Compiling never throws: it keeps what is valid and reports the rest in
/// ``Compilation/errors``, so a caller can paste a partly right answer or send the errors back
/// to the model and ask again. Every link is checked by the editor's own ``ConnectionValidator``
/// (types, directions, cycles, single-link inputs), so a clean result pastes without surprises.
public struct GraphSpecCompiler: Sendable {
    public var nodes: NodeRegistry
    public var types: TypeRegistry
    public var connectionValidator: ConnectionValidator

    public init(
        nodes: NodeRegistry, types: TypeRegistry, connectionValidator: ConnectionValidator = ConnectionValidator()
    ) {
        self.nodes = nodes
        self.types = types
        self.connectionValidator = connectionValidator
    }

    /// What compiling produced.
    public struct Compilation: Sendable {
        /// The valid part of the spec, laid out left to right, the nodes' top-left corner at the origin (a group's frame reaches a little above and left of it).
        public var fragment: GraphFragment
        /// The node each alias became, for the aliases that compiled.
        public var aliases: [String: NodeID]
        public var errors: [SpecError]

        public var isClean: Bool { errors.isEmpty }
    }

    public func compile(_ spec: GraphSpec) -> Compilation {
        var errors: [SpecError] = []
        func fail(_ kind: SpecError.Kind, _ message: String) { errors.append(SpecError(kind: kind, message: message)) }

        // The editor is scratch space: it applies the same rules a paste would, link by link.
        let editor = GraphEditor(nodes: nodes, types: types, connectionValidator: connectionValidator)
        var ids: [String: NodeID] = [:]
        var order: [NodeID] = []

        for spec in spec.nodes {
            guard Self.isValid(alias: spec.alias) else {
                fail(.invalidAlias, "Alias \"\(spec.alias)\" must be non-empty with no dots or spaces.")
                continue
            }
            guard ids[spec.alias] == nil else {
                fail(.duplicateAlias, "Alias \"\(spec.alias)\" is used by more than one node.")
                continue
            }
            let typeID = NodeTypeID(spec.type)
            guard let definition = nodes.definition(for: typeID) else {
                fail(.unknownNodeType, "\(spec.alias): unknown node type \"\(spec.type)\"." + similar(to: spec.type))
                continue
            }

            var properties: [PropertyID: GraphValue] = [:]
            for (name, raw) in spec.properties.sorted(by: { $0.key < $1.key }) {
                guard let property = definition.property(PropertyID(name)) else {
                    let valid = definition.properties.map(\.id.rawValue).joined(separator: ", ")
                    fail(.unknownProperty, "\(spec.alias) (\(spec.type)): no property \"\(name)\"."
                        + (valid.isEmpty ? " It has no properties." : " Properties: \(valid)."))
                    continue
                }
                let value = Self.coerced(GraphValue(json: raw), for: property)
                do {
                    try property.validate(value)
                    if value != property.defaultValue { properties[property.id] = value }
                } catch {
                    fail(.invalidProperty, "\(spec.alias) (\(spec.type)): property \"\(name)\" cannot be "
                        + "\(value.summary(limit: 30)): \(error).")
                }
            }

            var portCounts: [String: Int] = [:]
            for (group, count) in spec.portCounts.sorted(by: { $0.key < $1.key }) {
                guard let declared = definition.dynamicPorts.first(where: { $0.id == group }) else {
                    let valid = definition.dynamicPorts.map(\.id).joined(separator: ", ")
                    fail(.unknownPortGroup, "\(spec.alias) (\(spec.type)): no port group \"\(group)\"."
                        + (valid.isEmpty ? " It has none." : " Groups: \(valid)."))
                    continue
                }
                let allowed = declared.clamped(count)
                if allowed != count {
                    let limit = declared.maximum.map { "\(declared.minimum)...\($0)" } ?? "at least \(declared.minimum)"
                    fail(.unknownPortGroup, "\(spec.alias): port group \"\(group)\" takes \(limit) ports, not \(count).")
                }
                if allowed != declared.initialCount { portCounts[group] = allowed }
            }

            let node = Node(
                typeID: typeID, title: spec.title, mode: spec.mode ?? .always, properties: properties,
                portCounts: portCounts)
            // Properties and counts were checked above, so adding cannot fail.
            guard (try? editor.apply(.addNode(node: node))) != nil else { continue }
            ids[spec.alias] = node.id
            order.append(node.id)
        }

        let skipped = Set(spec.nodes.map(\.alias)).subtracting(ids.keys)
        for link in spec.links {
            guard let source = endpoint(link.from, direction: .output, ids: ids, skipped: skipped, editor: editor, link: link, fail: fail),
                  let target = endpoint(link.to, direction: .input, ids: ids, skipped: skipped, editor: editor, link: link, fail: fail)
            else { continue }
            let proposal = ConnectionProposal(source: source, target: target)
            let check = connectionValidator.check(proposal, in: editor.validationContext)
            if !check.isAllowed {
                let reasons = check.diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "; ")
                fail(.linkRejected, "Link \(link.from) -> \(link.to) rejected: \(reasons).")
            } else if !check.replacedLinks.isEmpty {
                fail(.linkRejected, "Link \(link.from) -> \(link.to) rejected: \(link.to) already has a link, "
                    + "and it takes only one.")
            } else {
                _ = try? editor.connect(proposal)
            }
        }

        var fragment = (try? editor.fragment(nodes: order)) ?? GraphFragment()
        // Keep the order the spec gave, which the layout and the paste both follow.
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        fragment.nodes.sort { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
        let places = layout(fragment.nodes, links: fragment.links)
        for index in fragment.nodes.indices { fragment.nodes[index].position = places[fragment.nodes[index].id] ?? .zero }

        for group in spec.groups {
            var members: [NodeID] = []
            for alias in group.members {
                if let id = ids[alias] { members.append(id) } else if !skipped.contains(alias) {
                    fail(.unknownAlias, "Group \"\(group.title)\": no node with alias \"\(alias)\".")
                }
            }
            let frames = fragment.nodes.filter { members.contains($0.id) }.map(nodes.frame(of:))
            guard let first = frames.first else {
                if group.members.isEmpty { fail(.emptyGroup, "Group \"\(group.title)\" has no members.") }
                continue
            }
            let box = frames.dropFirst().reduce(first) { union, frame in
                let minX = min(union.minX, frame.minX), minY = min(union.minY, frame.minY)
                return GraphRect(
                    x: minX, y: minY, width: max(union.maxX, frame.maxX) - minX,
                    height: max(union.maxY, frame.maxY) - minY)
            }
            fragment.groups.append(NodeGroup(
                title: group.title,
                bounds: GraphRect(
                    x: box.minX - Self.groupPadding, y: box.minY - Self.groupPadding - Self.groupTitleHeight,
                    width: box.size.width + 2 * Self.groupPadding,
                    height: box.size.height + 2 * Self.groupPadding + Self.groupTitleHeight)))
        }
        return Compilation(fragment: fragment, aliases: ids, errors: errors)
    }

    // MARK: Endpoints

    /// Resolves `"alias.port"` to a port address, reporting what is wrong with it if it cannot.
    private func endpoint(
        _ text: String, direction: PortDirection, ids: [String: NodeID], skipped: Set<String>,
        editor: GraphEditor, link: GraphSpec.LinkSpec, fail: (SpecError.Kind, String) -> Void
    ) -> PortAddress? {
        guard let dot = text.firstIndex(of: "."), dot != text.startIndex, text.index(after: dot) != text.endIndex else {
            fail(.malformedEndpoint, "\"\(text)\" is not of the form alias.port (in link \(link.from) -> \(link.to)).")
            return nil
        }
        let alias = String(text[..<dot]), port = PortID(String(text[text.index(after: dot)...]))
        if skipped.contains(alias) { return nil }  // its own error is already reported
        guard let id = ids[alias], let node = editor.graph.nodes[id], let definition = editor.nodes.definition(for: node) else {
            fail(.unknownAlias, "Link \(link.from) -> \(link.to): no node with alias \"\(alias)\".")
            return nil
        }
        guard definition.port(port, direction: direction) != nil else {
            let word = direction == .output ? "output" : "input"
            let valid = definition.ports.filter { $0.direction == direction }.map(\.id.rawValue).joined(separator: ", ")
            var message = "Link \(link.from) -> \(link.to): \(alias) (\(node.typeID.rawValue)) has no \(word) port \"\(port.rawValue)\"."
            message += valid.isEmpty ? " It has no \(word) ports." : " \(word.capitalized) ports: \(valid)."
            if definition.port(port, direction: direction == .output ? .input : .output) != nil {
                message += " \"\(port.rawValue)\" is an \(direction == .output ? "input" : "output"); links go from an output to an input."
            }
            fail(.unknownPort, message)
            return nil
        }
        return PortAddress(node: id, port: port, direction: direction)
    }

    // MARK: Helpers

    private static func isValid(alias: String) -> Bool {
        !alias.isEmpty && !alias.contains(".") && !alias.contains(where: \.isWhitespace)
    }

    /// Models write whole numbers for any number. Accept an int for a double property and a whole
    /// double for an int property, which are the same number.
    static func coerced(_ value: GraphValue, for property: PropertyDefinition) -> GraphValue {
        switch (property.kind, value) {
        case (.double, .int(let number)): return .double(Double(number))
        case (.int, .double(let number)) where number.rounded() == number && abs(number) < 1e15:
            return .int(Int64(number))
        case (.vector, .array(let items)):
            let numbers = items.compactMap(\.numberValue)
            return numbers.count == items.count ? .vector(numbers) : value
        default: return value
        }
    }

    /// Registered types that look like what was asked for, to point a model at the right id.
    private func similar(to name: String) -> String {
        let wanted = name.lowercased()
        let tail = wanted.split(separator: ".").last.map(String.init) ?? wanted
        let matches = nodes.registeredDefinitions.map(\.typeID.rawValue).filter { id in
            let lower = id.lowercased()
            return lower.contains(tail) || (!tail.isEmpty && tail.contains(lower.split(separator: ".").last ?? ""))
        }
        return matches.isEmpty ? "" : " Similar: \(matches.prefix(5).joined(separator: ", "))."
    }

    // MARK: Layout

    static let columnGap = 80.0, rowGap = 40.0, groupPadding = 20.0, groupTitleHeight = 28.0

    /// Left-to-right layers: a node is one column right of the furthest node feeding it. Nodes in a
    /// column keep the spec's order. Links that close a loop stop raising a column after the
    /// node count, so a feedback loop cannot spin.
    private func layout(_ fragmentNodes: [Node], links: [Link]) -> [NodeID: GraphPoint] {
        var column = Dictionary(uniqueKeysWithValues: fragmentNodes.map { ($0.id, 0) })
        for _ in 0..<fragmentNodes.count {
            var changed = false
            for link in links {
                guard let from = column[link.source.node], let to = column[link.target.node],
                      from + 1 > to, from + 1 < fragmentNodes.count else { continue }
                column[link.target.node] = from + 1
                changed = true
            }
            if !changed { break }
        }
        var places: [NodeID: GraphPoint] = [:]
        var x = 0.0
        for index in 0...(column.values.max() ?? 0) {
            var y = 0.0, width = 0.0
            for node in fragmentNodes where column[node.id] == index {
                let size = nodes.frame(of: node).size
                places[node.id] = GraphPoint(x: x, y: y)
                y += size.height + Self.rowGap
                width = max(width, size.width)
            }
            x += width + Self.columnGap
        }
        return places
    }
}

extension GraphSpecCompiler.Compilation {
    /// The command that pastes the compiled graph into the graph `editor` is editing (or one of its
    /// subgraphs, with `scope`), its top-left corner at `origin`. Throws if the editor cannot
    /// create a node type, which cannot happen when the compiler was made from the same registry.
    public func pasteCommand(
        into editor: GraphEditor, at origin: GraphPoint = .zero, in scope: SubgraphID? = nil
    ) throws -> GraphPaste {
        try editor.pasteCommand(fragment, translatedBy: origin, in: scope)
    }
}
