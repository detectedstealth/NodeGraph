import Foundation

/// The result of ``GraphEditor/convertToSubgraphCommand(nodes:name:promoting:in:)``.
public struct SubgraphConversion: Sendable {
    /// Apply this (for example with ``GraphHistory/perform(_:name:coalescing:)``) to do the conversion.
    public var command: GraphCommand
    /// The new definition.
    public var subgraph: SubgraphID
    /// The instance node that replaces the selection.
    public var instance: NodeID
}

/// The result of ``GraphEditor/unpackCommand(instance:in:)``.
public struct SubgraphUnpacking: Sendable {
    /// Apply this to do the unpacking.
    public var command: GraphCommand
    /// The new node for each node of the definition's inner graph, for restoring a selection.
    public var nodes: [NodeID: NodeID]
}

extension GraphEditor {
    /// The graph edited in `scope`: the root graph, or a subgraph's inner graph.
    private func graph(in scope: SubgraphID?) throws -> Graph {
        guard let scope else { return graph }
        guard let definition = subgraphs[scope] else { throw GraphEditError.subgraphNotFound(scope) }
        return definition.graph
    }

    private func scoped(_ command: GraphCommand, _ scope: SubgraphID?) -> GraphCommand {
        scope.map { .inSubgraph(id: $0, command: command) } ?? command
    }

    // MARK: Convert a selection into a subgraph

    /// Builds the command that replaces `selection` with an instance of a new subgraph.
    ///
    /// The selected nodes, and the links among them, move into the new definition unchanged. Each
    /// link that crossed the selection's edge becomes a port of the interface and a link to the
    /// instance:
    /// - links from one outside output into the selection become one input (feeding every port the
    ///   output fed), and
    /// - links from one selected output to the outside become one output (feeding every node the
    ///   output fed).
    ///
    /// Port ids come from the inner ports and are made unique with a numeric suffix. The instance
    /// is placed at the centre of the selection. Applied as one batch, so undo restores the
    /// original nodes, links and positions exactly.
    ///
    /// Because the batch is built from the current graph, apply it before making other edits.
    ///
    /// - Parameters:
    ///   - promoting: Inner node properties to expose on the instance. Each keeps its current value
    ///     as the default, so behaviour is unchanged.
    ///   - scope: The subgraph being edited, or nil for the root graph.
    /// - Throws: ``GraphEditError`` if the selection is empty or names a missing node, a promoted
    ///   property does not exist, or an inner input port that receives a link from outside also
    ///   has other links (a multi-link port), which a single exposed input cannot represent.
    public func convertToSubgraphCommand(
        nodes selection: [NodeID], name: String, promoting: [PropertyTarget] = [], in scope: SubgraphID? = nil
    ) throws -> SubgraphConversion {
        let source = try graph(in: scope)
        guard !selection.isEmpty else { throw GraphEditError.invalidSubgraph(["Select at least one node."]) }
        let selected = Set(selection)
        for id in selected where source.nodes[id] == nil { throw GraphEditError.nodeNotFound(id) }
        let ordered = source.nodes.keys.filter(selected.contains)

        // Split the links into those inside the selection, entering it, and leaving it.
        var inner = Graph()
        for id in ordered { inner.insert(source.nodes[id]!) }
        var entering: [Link] = [], leaving: [Link] = []
        for link in source.links.values {
            let from = selected.contains(link.source.node), to = selected.contains(link.target.node)
            if from && to { inner.insert(link) } else if to { entering.append(link) } else if from { leaving.append(link) }
        }

        func port(_ address: PortAddress) -> PortDefinition? {
            inner.nodes[address.node].flatMap { nodes.definition(for: $0) }?
                .port(address.port, direction: address.direction)
        }
        var usedInputs = Set<String>(), usedOutputs = Set<String>(), usedProperties = Set<String>()
        func unique(_ base: String, _ used: inout Set<String>) -> String {
            var candidate = base, n = 2
            while !used.insert(candidate).inserted { candidate = "\(base)_\(n)"; n += 1 }
            return candidate
        }

        // One exposed input per outside output that feeds the selection.
        var inputs: [SubgraphInput] = []
        var inputLinks: [(from: PortAddress, input: PortID)] = []
        var groups: [PortAddress: [Link]] = [:], groupOrder: [PortAddress] = []
        for link in entering {
            if groups[link.source] == nil { groupOrder.append(link.source) }
            groups[link.source, default: []].append(link)
        }
        for outside in groupOrder {
            let links = groups[outside]!
            for link in links where source.links(into: link.target).count != 1 {
                throw GraphEditError.invalidSubgraph([
                    "Port \"\(link.target.port)\" has several links, so it cannot become a single input of a subgraph."])
            }
            let first = port(links[0].target)
            let id = PortID(unique(links[0].target.port.rawValue, &usedInputs))
            inputs.append(SubgraphInput(
                id: id, displayName: first?.displayName ?? id.rawValue, kind: first?.kind ?? .data,
                type: first?.type ?? .any, defaultValue: first?.defaultValue, targets: links.map(\.target)))
            inputLinks.append((outside, id))
        }

        // One exposed output per selected output that feeds the outside.
        var outputs: [SubgraphOutput] = []
        var outputIDs: [PortAddress: PortID] = [:]
        for link in leaving where outputIDs[link.source] == nil {
            let definition = port(link.source)
            let id = PortID(unique(link.source.port.rawValue, &usedOutputs))
            outputIDs[link.source] = id
            outputs.append(SubgraphOutput(
                id: id, displayName: definition?.displayName ?? id.rawValue, kind: definition?.kind ?? .data,
                type: definition?.type ?? .any, source: link.source))
        }

        // Properties to expose, keeping today's values.
        var properties: [PromotedProperty] = []
        for target in promoting {
            guard let node = inner.nodes[target.node] else { throw GraphEditError.nodeNotFound(target.node) }
            guard let property = nodes.definition(for: node.typeID)?.property(target.property) else {
                throw GraphEditError.unknownProperty(target.property)
            }
            properties.append(PromotedProperty(
                id: PropertyID(unique(target.property.rawValue, &usedProperties)),
                displayName: property.displayName, kind: property.kind,
                defaultValue: node.properties[target.property] ?? property.defaultValue, targets: [target]))
        }

        let definition = SubgraphDefinition(
            interface: SubgraphInterface(name: name, inputs: inputs, outputs: outputs, properties: properties),
            graph: inner)
        let frames = ordered.map { nodes.frame(of: source.nodes[$0]!) }
        let size = definition.nodeDefinition.defaultSize
        let centre = GraphPoint(
            x: (frames.map(\.minX).min()! + frames.map(\.maxX).max()!) / 2,
            y: (frames.map(\.minY).min()! + frames.map(\.maxY).max()!) / 2)
        let instance = Node(
            typeID: definition.typeID,
            position: GraphPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))

        // Remove the nodes first (which removes every link touching them), then place the
        // instance and reconnect the outside world to it.
        var commands: [GraphCommand] = [.addSubgraph(definition: definition)]
        commands += ordered.map { scoped(.removeNode(id: $0), scope) }
        commands.append(scoped(.addNode(node: instance), scope))
        for (outside, input) in inputLinks {
            commands.append(scoped(.addLink(link: Link(
                sourceNode: outside.node, sourcePort: outside.port, targetNode: instance.id, targetPort: input)), scope))
        }
        for link in leaving {
            commands.append(scoped(.addLink(link: Link(
                sourceNode: instance.id, sourcePort: outputIDs[link.source]!,
                targetNode: link.target.node, targetPort: link.target.port)), scope))
        }
        return SubgraphConversion(command: .batch(commands: commands), subgraph: definition.id, instance: instance.id)
    }

    // MARK: Unpack an instance

    /// Builds the command that replaces an instance with a copy of its definition's inner nodes.
    ///
    /// The copies get new ids, so unpacking one definition several times never collides, and are
    /// moved so the inner graph's top-left corner is where the instance was. Inner links are
    /// copied. Links that ran to the instance's inputs are rewired to the inner ports those inputs
    /// fed, and links that ran from its outputs start at the inner ports that fed them. The
    /// instance's property values (or the promoted defaults) are written into the copies, so a
    /// graph runs the same before and after. The definition itself is left in place.
    ///
    /// One difference: an unlinked instance input used its interface default, but unpacked, the
    /// inner port uses its own default.
    ///
    /// - Parameter scope: The subgraph being edited, or nil for the root graph.
    public func unpackCommand(instance id: NodeID, in scope: SubgraphID? = nil) throws -> SubgraphUnpacking {
        let source = try graph(in: scope)
        guard let instance = source.nodes[id] else { throw GraphEditError.nodeNotFound(id) }
        guard let subgraphID = instance.typeID.subgraphID else {
            throw GraphEditError.invalidSubgraph(["Node of type \"\(instance.typeID)\" is not a subgraph instance."])
        }
        guard let definition = subgraphs[subgraphID] else { throw GraphEditError.subgraphNotFound(subgraphID) }
        let inner = definition.graph

        var map: [NodeID: NodeID] = [:]
        for key in inner.nodes.keys { map[key] = NodeID() }

        // Property values the instance would have written into the inner nodes.
        var overrides: [NodeID: [PropertyID: GraphValue]] = [:]
        for property in definition.interface.properties {
            let value = instance.properties[property.id] ?? property.defaultValue
            for target in property.targets { overrides[target.node, default: [:]][target.property] = value }
        }

        // Keep the layout, anchored where the instance was.
        let frames = inner.nodes.values.map { nodes.frame(of: $0) }
        let offset = frames.isEmpty
            ? GraphPoint.zero
            : GraphPoint(x: instance.position.x - frames.map(\.minX).min()!,
                         y: instance.position.y - frames.map(\.minY).min()!)

        var commands: [GraphCommand] = [scoped(.removeNode(id: id), scope)]   // frees the instance's ports
        for node in inner.nodes.values {
            var copy = node
            copy.id = map[node.id]!
            copy.position = GraphPoint(x: node.position.x + offset.x, y: node.position.y + offset.y)
            copy.properties.merge(overrides[node.id] ?? [:]) { _, outer in outer }
            commands.append(scoped(.addNode(node: copy), scope))
        }
        for link in inner.links.values {
            commands.append(scoped(.addLink(link: Link(
                sourceNode: map[link.source.node]!, sourcePort: link.source.port,
                targetNode: map[link.target.node]!, targetPort: link.target.port,
                waypoints: link.waypoints.map { GraphPoint(x: $0.x + offset.x, y: $0.y + offset.y) })), scope))
        }
        for input in definition.interface.inputs {
            let address = PortAddress(node: id, port: input.id, direction: .input)
            for outside in source.links(into: address) {
                for target in input.targets {
                    guard let node = map[target.node] else { continue }
                    commands.append(scoped(.addLink(link: Link(
                        sourceNode: outside.source.node, sourcePort: outside.source.port,
                        targetNode: node, targetPort: target.port)), scope))
                }
            }
        }
        for output in definition.interface.outputs {
            guard let inside = output.source, let node = map[inside.node] else { continue }
            let address = PortAddress(node: id, port: output.id, direction: .output)
            for outside in source.links(from: address) {
                commands.append(scoped(.addLink(link: Link(
                    sourceNode: node, sourcePort: inside.port,
                    targetNode: outside.target.node, targetPort: outside.target.port)), scope))
            }
        }
        return SubgraphUnpacking(command: .batch(commands: commands), nodes: map)
    }
}
